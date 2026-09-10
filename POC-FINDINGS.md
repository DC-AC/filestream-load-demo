# FILESTREAM POC - performance findings

Run date: 2026-09-10. Target VM: `SQL1` (Azure, eastus).

Four 200 GB ingest runs took place. One produced a valid result. This report uses
that run. It covers ingest performance only.

---

## Environment

| | |
|---|---|
| VM | `Standard_E8ads_v5` - 8 vCPU, 63.9 GB RAM |
| OS | Windows Server 2022 Datacenter, build **20348.5256** |
| SQL Server | 2019 - 15.0.4470.1, FILESTREAM effective level 2 |
| `max server memory` | 56,000 MB (unlimited for the first run. See [Configuration findings](#configuration-findings)) |

Storage layout:

| Volume | Role | Disk | Host caching |
|---|---|---|---|
| `F:` SQLVMDATA1 | MDF, XEvents | 1024 GB `PremiumV2_LRS` | None |
| `G:` SQLVMLOG | LDF (16 GB, presized) | 1024 GB `PremiumV2_LRS` | None |
| `H:` Filestream | **FILESTREAM container** | 2048 GB `Premium_LRS` (P40, ~250 MB/s cap) | **ReadOnly** |
| `C:` Windows | Results, traces | 127 GB `Premium_LRS` | ReadWrite |
| `D:` Temporary Storage | tempdb | ephemeral | - |

Every volume is NTFS with 64 KB allocation units. 8.3 name generation is
disabled on `H:`. Defender exclusions are in place for `H:\FilestreamData` and
`sqlservr.exe`. The exclusions are verified, so Defender does not affect any
number below.

---

## Headline result

**200.00 GB in 161,834 files, 32m 37s, ~104.5 MB/s aggregate (82.7 files/sec).**
The run used 8 threads, a 4 MB chunk size, the `Mixed` profile and `SIMPLE`
recovery.

RunId `04EAFF19-8D8E-41E4-B59E-3F75BFBC0770`. Results are in
`C:\FsPocResults\run_20260910_152357_Filestream_Mixed`.

> **Measurement note.** The client reported 199.54 GB in 161,832 files. The
> database holds 200.00 GB in 161,834 files. Two commits exceeded their timeout,
> and the client counted them as failures. Both transactions had in fact
> committed. A commit timeout is an ambiguous outcome, not a failed one: the
> client cannot tell whether the server committed. The client assumes failure,
> so it under-reports bytes rather than over-reports them. `IngestTiming` holds
> no row for those two files, so the per-bucket table below excludes them.

### Do not quote the 144.9 MB/s figure

An earlier run (RunId `FAF22B6E`) reported **199.21 GB in 1,408s = 144.9
MB/s**. That number is invalid. The machine went down 25 seconds after the run
reported completion, during the write-back drain. The data was still in the
Windows file cache, so the disk had not absorbed those writes. The run reported
throughput for writes that never landed.

Use the 104.5 MB/s figure. It comes from the run where the writes landed.

This trap is general to FILESTREAM benchmarking, not specific to this kit.
FILESTREAM writes go through the **Windows system file cache**, not through the
SQL Server buffer pool. Client-side throughput can outrun the disk until the
cache stops absorbing. During the valid run the client reported bursts of 425
MB/s while Perfmon showed `H:` sustaining 101 MB/s.

---

## The actual question: where is the crossover?

The kit measured this on the client, per file, from
`FsPocMonitor.dbo.IngestTiming`:

| Bucket | Files | Avg size | Open ms | Write ms | Commit ms | P50 ms | P95 ms | P99 ms | Max ms | Effective MB/s |
|---|---|---|---|---|---|---|---|---|---|---|
| Tiny | 123,237 | 0.03 MB | 12.27 | 14.14 | 22.77 | 45.83 | 74.01 | 91.59 | 1,567 | **0.7** |
| Small | 30,653 | 0.53 MB | 12.75 | 14.32 | 25.81 | 42.28 | 79.72 | 221 | 2,244 | **10.1** |
| Medium | 7,206 | 8.53 MB | 58.45 | 187.59 | 205.86 | 242 | 1,652 | 3,448 | 10,947 | **18.9** |
| Large | 706 | 129.87 MB | 308.08 | 2,335 | 1,222 | 3,187 | 10,112 | 13,114 | 17,369 | **33.6** |
| Huge | 30 | 1,024 MB | 449.86 | 17,905 | 1,666 | 14,948 | 48,080 | 73,432 | 80,773 | **51.1** |

Three things fall out of this table.

**1. Per-file overhead dominates below about 1 MB.** A Tiny file averages 49 ms
end to end. Only 14 ms of that is the write. The other 35 ms is the `PathName()`
round trip and the commit. Effective throughput is 0.7 MB/s. At this size the
fixed cost per file *is* the cost.

**2. The commit outweighs the write up to about 8 MB.** For Tiny, Small and
Medium, `AvgCommitMs` is at or above `AvgWriteMs`. The commit is a durability
flush. Below Medium you pay more to flush than to write. Batching more files
per transaction is the obvious lever. The ingest does not support it today: it
uses one transaction per file.

**3. Effective throughput never plateaus.** It climbs monotonically with size:
0.7, 10.1, 18.9, 33.6 and 51.1 MB/s. Even 1 GB files reach only 51.1 MB/s per
stream against a disk that caps at 250 MB/s. FILESTREAM stays overhead-bound at
every size tested here. The 104.5 MB/s aggregate comes from running 8 streams.
No single stream gets close to the disk.

**The A/B against in-table `varbinary(max)` has not run yet.** Without it, these
numbers describe FILESTREAM's cost curve but do not tell you whether FILESTREAM
is the right choice. This is the most important outstanding item. See
[Not yet done](#not-yet-done).

---

## Where the server-side time went

From `sys.dm_os_wait_stats` deltas over the valid run:

| Wait | Time (s) | % | Avg ms | Meaning |
|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 10,063 | 43.9 | 12.53 | FILESTREAM work queue |
| `PREEMPTIVE_OS_FILEOPS` | 5,445 | 23.8 | 33.60 | Win32 file ops on the container |
| `PREEMPTIVE_OS_CREATEFILE` | 3,785 | 16.5 | 5.85 | New container file. NTFS metadata |
| `PREEMPTIVE_OS_DELETEFILE` | 625 | 2.7 | 1.32 | Container file delete |
| `WRITELOG` | 328 | 1.4 | 1.95 | Log flush |

The `PREEMPTIVE_OS_*` family accounts for about 43% of wait time. Standard "top
waits" scripts filter that family out as idle noise. That is why FILESTREAM
investigations so often come back empty-handed.

**Container churn is much higher than the file count suggests.** The run stored
161,832 files. It issued 647,336 `CREATEFILE` waits and 473,991 `DELETEFILE`
waits, which is about 4 creates and 3 deletes per stored file. The container was
freshly created and empty, so this is FILESTREAM's own internal churn. It is not
garbage collection of earlier runs. The result reproduced within 0.1% across two
independent runs.

---

## Container disk behaviour during the valid run

`H:` carried the whole write load. Perfmon recorded this:

| Metric | Value |
|---|---|
| Write latency, average | 170.7 ms |
| Write latency, maximum | 876.3 ms |
| Samples over 200 ms | 128 of 393 |
| Queue depth, maximum | 29 |
| Sustained throughput | 101 MB/s |

`H:` is a **P40 `Premium_LRS` disk capped at about 250 MB/s**. It is the slowest
disk on the box. The MDF and LDF sit on far more capable `PremiumV2_LRS` disks
that barely need the throughput.

Saturating this disk is deliberate. The POC exists to measure FILESTREAM under
I/O pressure. Read the latency numbers above as the pressure the measurement ran
under, not as a defect.

---

## Configuration findings

**`max server memory` was unbounded.** On a 64 GB VM the buffer pool could take
everything, which starves the Windows system file cache. This matters more for
FILESTREAM than for a normal workload. FILESTREAM I/O does not use the buffer
pool at all, because the blobs never pass through it. No SQL-side counter shows
this. The value is now capped at 56,000 MB.

**The container is on the weakest disk.** It is a P40 `Premium_LRS` at about 250
MB/s, while `F:` and `G:` are `PremiumV2_LRS`. Move the container if the goal
changes from "measure FILESTREAM under pressure" to "measure how fast this can
go".

**`H:` host caching is `ReadOnly`.** It should be `None` for a write-heavy POC.
`F:` and `G:` are correctly set to `None`.

**Ruled out as factors in these numbers:** Defender (excluded), 8.3 name
generation (disabled on `H:`), volume roles (verified against the instance
default paths), and ReFS (all volumes are NTFS).

---

## Not yet done

1. **The A/B against in-table `varbinary(max)`.** This is the comparison the POC
   exists to make, and it has not run. `Invoke-PocRun.ps1 -Matrix` covers it.
   Without it, everything above describes FILESTREAM's cost curve in isolation.
2. **A `FULL` recovery run.** Every run so far used `SIMPLE`. Under `FULL`, the
   log backup chain carries the FILESTREAM data. Backup size, backup duration
   and log management all change a lot.
3. **The read path.** `FilestreamRead` and `BlobRead` have not run. Ingest
   performance alone is half an answer.
4. **Process Monitor per-operation anatomy.** No capture has succeeded. Procmon
   cannot generate a `.pmc` config file headlessly: Procmon 4.1 has
   `/LoadConfig` but no `/SaveConfig`, and it ignores a hand-written `.pmc`
   without a message. The GUI export in `procmon/README.md` is the only route.
   Until then there is no NTFS-level breakdown of the per-file time.

---

## Reproducing

```powershell
# clean baseline - the container must be empty, or directory pressure
# costs roughly 2x per-file throughput
sqlcmd -S . -E -b -i sql\99-cleanup.sql -v DbName="FsPocDemo" Mode="drop"
.\ps\Setup-FilestreamPoc.ps1
.\ps\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 200
```

Expect the first 17 minutes to look stalled. The Tiny and Small buckets hold
153,890 files that carry only 20 GB. The progress ETA extrapolates that rate
across the whole target. Throughput climbs sharply once the run reaches Medium.
