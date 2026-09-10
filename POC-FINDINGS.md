# FILESTREAM POC - performance findings

Run date: 2026-09-10. Target VM: `SQL1` (Azure, eastus).

Five 200 GB ingest runs took place. Two gave valid results. Each valid run used a
different container disk. This report compares them. It covers ingest performance
only.

The second disk is 2.6 times faster. It also disproves one conclusion from the
earlier version of this report. See
[What the faster disk changed](#what-the-faster-disk-changed).

---

## Environment

| | |
|---|---|
| VM | `Standard_E8ads_v5`, 8 vCPU, 63.9 GB RAM |
| OS | Windows Server 2022 Datacenter, build **20348.5256** |
| SQL Server | 2019, 15.0.4470.1, FILESTREAM effective level 2 |
| `max server memory` | 56,000 MB for both valid runs |

Only the container disk changed between the two runs.

| Volume | Role | Disk | Host caching |
|---|---|---|---|
| `F:` SQLVMDATA1 | MDF, XEvents | 1024 GB `PremiumV2_LRS` | None |
| `G:` SQLVMLOG | LDF (16 GB, presized) | 1024 GB `PremiumV2_LRS` | None |
| `H:` Filestream **(run 1)** | FILESTREAM container | 2048 GB `Premium_LRS` (P40, about 250 MB/s) | ReadOnly |
| `H:` Filestream **(run 2)** | FILESTREAM container | 2048 GB **`PremiumV2_LRS`** | **None** |
| `C:` Windows | Results, traces | 127 GB `Premium_LRS` | ReadWrite |
| `D:` Temporary Storage | tempdb | ephemeral | - |

Every volume uses NTFS with 64 KB allocation units. 8.3 name generation is off on
`H:`. Defender excludes `H:\FilestreamData` and `sqlservr.exe`. We verified those
exclusions. Defender does not affect any number below.

**Two variables changed, not one.** The disk SKU changed. The host caching
changed with it. PremiumV2 does not offer host caching, so you cannot separate
the two. `None` is the correct setting for a write-heavy workload. `ReadOnly`
never helped writes. Read this result as "new disk configuration", not "SKU
alone".

A synthetic test measured the PremiumV2 disk at **476.9 MB/s**. The test used 4
concurrent write-through streams. The run later peaked at 585.3 MB/s. The
provisioned ceiling is therefore higher than the test reached.

PremiumV2 sets throughput independently of disk size. The default is 125 MB/s.
Someone provisioned this disk above that default. A default PremiumV2 disk is
slower than the P40 it replaced.

---

## Headline result

Both runs wrote exactly 200.00 GB. Both used 8 threads, a 4 MB chunk size, the
`Mixed` profile and `SIMPLE` recovery. Both wrote into a new, empty container.

| | Run 1: P40 | Run 2: PremiumV2 | Change |
|---|---|---|---|
| RunId | `04EAFF19` | `7CDD0CC9` | |
| Data written | 200.00 GB / 161,834 files | 200.00 GB / 162,051 files | |
| Elapsed | 32m 38s | **12m 26s** | **2.62x faster** |
| Throughput | 104.4 MB/s | **274.5 MB/s** | **2.63x** |
| Files per second | 82.7 | **217.2** | **2.63x** |
| Errors | 2 commit timeouts | **0** | |

The kit randomises file sizes per run, so the file counts differ. Both runs hit
the 200.00 GB target exactly.

Results are in `C:\FsPocResults\run_20260910_152357_Filestream_Mixed` and
`C:\FsPocResults\run_20260910_184032_Filestream_Mixed`.

> **Measurement note on run 1.** The client reported 199.54 GB in 161,832 files.
> The database holds 200.00 GB in 161,834 files. Two commits passed their
> timeout, and the client counted them as failures. Both transactions had
> committed.
>
> A commit timeout is ambiguous, not failed. The client cannot tell whether the
> server committed. The client assumes failure, so it under-reports bytes instead
> of over-reporting them. `IngestTiming` holds no row for those two files, so the
> per-bucket tables below exclude them. Run 2 had no timeouts.

### Do not quote the 144.9 MB/s figure

An earlier run (RunId `FAF22B6E`) reported 199.21 GB in 1,408s. That is 144.9
MB/s. The number is invalid.

The machine went down 25 seconds after the run reported completion. It went down
during the write-back drain. The data still sat in the Windows file cache, so the
disk had not absorbed those writes. The run reported throughput for writes that
never landed.

This trap applies to FILESTREAM benchmarking in general. FILESTREAM writes go
through the Windows system file cache. They do not go through the SQL Server
buffer pool. Client throughput can outrun the disk until the cache stops
absorbing. In run 1 the client reported bursts of 425 MB/s while Perfmon showed
`H:` sustaining 101 MB/s.

---

## Where the crossover is

The kit measures this on the client, per file, from
`FsPocMonitor.dbo.IngestTiming`.

Run 1, P40:

| Bucket | Files | Avg size | Open ms | Write ms | Commit ms | P50 ms | P95 ms | P99 ms | Effective MB/s |
|---|---|---|---|---|---|---|---|---|---|
| Tiny | 123,237 | 0.03 MB | 12.27 | 14.14 | 22.77 | 45.83 | 74.01 | 91.59 | **0.7** |
| Small | 30,653 | 0.53 MB | 12.75 | 14.32 | 25.81 | 42.28 | 79.72 | 221 | **10.1** |
| Medium | 7,206 | 8.53 MB | 58.45 | 187.59 | 205.86 | 242 | 1,652 | 3,448 | **18.9** |
| Large | 706 | 129.87 MB | 308.08 | 2,335 | 1,222 | 3,187 | 10,112 | 13,114 | **33.6** |
| Huge | 30 | 1,024 MB | 449.86 | 17,905 | 1,666 | 14,948 | 48,080 | 73,432 | **51.1** |

Run 2, PremiumV2:

| Bucket | Files | Avg size | Open ms | Write ms | Commit ms | P50 ms | P95 ms | P99 ms | Effective MB/s |
|---|---|---|---|---|---|---|---|---|---|
| Tiny | 123,229 | 0.03 MB | 4.70 | 6.57 | 7.75 | 17.96 | 26.60 | 33.20 | **1.7** |
| Small | 30,795 | 0.53 MB | 5.27 | 6.58 | 9.60 | 18.03 | 32.82 | 93.48 | **24.7** |
| Medium | 7,323 | 8.39 MB | 56.25 | 30.01 | 112.27 | 25.35 | 920.01 | 1,674 | **42.2** |
| Large | 671 | 137.35 MB | 193.52 | 169.66 | 579.62 | 716.48 | 2,229 | 3,162 | **145.7** |
| Huge | 33 | 930.91 MB | 69.75 | 458.37 | 658.07 | 990.44 | 2,245 | 4,746 | **784.7** |

Two findings hold on both disks.

**1. Per-file overhead dominates below about 1 MB.** On the P40 a Tiny file takes
49 ms end to end. Only 14 ms of that is the write. On PremiumV2 it takes 19 ms,
and only 6.6 ms is the write. The proportion barely moves. The rest is the
`PathName()` round trip and the commit. At this size the fixed cost per file is
the cost.

**2. The commit costs more than the write up to about 8 MB.** This holds on both
disks for Tiny, Small and Medium. `AvgCommitMs` sits at or above `AvgWriteMs`.
The commit is a durability flush. Below Medium you pay more to flush than to
write. Batching more files per transaction is the obvious lever. The ingest does
not support it today, because it uses one transaction per file.

---

## What the faster disk changed

An earlier version of this report said effective throughput never plateaus. It
concluded that FILESTREAM stays overhead-bound at every size tested. **Run 2
disproves that.** The large end was disk-bound, not overhead-bound.

| Bucket | P50, P40 | P50, PremiumV2 | MB/s, P40 | MB/s, PremiumV2 | Speedup |
|---|---|---|---|---|---|
| Tiny | 45.8 ms | 18.0 ms | 0.7 | **1.7** | 2.4x |
| Small | 42.3 ms | 18.0 ms | 10.1 | **24.7** | 2.4x |
| Medium | 242 ms | 25.4 ms | 18.9 | **42.2** | 2.2x |
| Large | 3,187 ms | 716 ms | 33.6 | **145.7** | 4.3x |
| Huge | 14,948 ms | 990 ms | 51.1 | **784.7** | **15.4x** |

The median for a Huge file fell from 14.9 seconds to 0.99 seconds. The P40
throttled large writes. FILESTREAM was never the limit there.

**The important consequence runs the other way.** Faster storage makes the
small-file penalty worse in relative terms. The spread from Tiny to Huge was 73
times on the P40. It is now 462 times. Small files are overhead-bound and gained
only 2.4 times. Large files scale with the hardware and gained 15.4 times.

This sharpens the main finding of the POC. It does not soften it.

> If the workload is small files, faster storage does not rescue it. The per-file
> cost is the `PathName()` round trip plus the commit. Neither is a throughput
> problem. Storage spend helps the large end almost linearly. It helps the small
> end barely at all.

**The A/B against in-table `varbinary(max)` has not run yet.** These numbers
describe the cost curve of FILESTREAM. They do not tell you whether FILESTREAM is
the right choice. This is the most important open item. See
[Not yet done](#not-yet-done).

---

## Where the server-side time went

From `sys.dm_os_wait_stats` deltas over each run:

| Wait | P40 time | PremiumV2 time | P40 avg ms | PremiumV2 avg ms |
|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 10,063s | 4,110s | 12.53 | 4.94 |
| `PREEMPTIVE_OS_FILEOPS` | 5,445s | 2,253s | 33.60 | 13.90 |
| `PREEMPTIVE_OS_CREATEFILE` | 3,785s | 1,753s | 5.85 | 2.70 |
| `PREEMPTIVE_OS_DELETEFILE` | 625s | 464s | 1.32 | 1.08 |
| `WRITELOG` | 328s | 197s | 1.95 | 1.21 |

The `PREEMPTIVE_OS_*` family takes about 43% of wait time on the P40 and about
45% on PremiumV2. Standard "top waits" scripts filter that family out as idle
noise. That is why FILESTREAM investigations so often come back empty-handed.

**Container churn is much higher than the file count suggests.** It is a property
of FILESTREAM, not of the storage. Run 2 stored 162,051 files and issued 648,204
`CREATEFILE` waits. That is about 4 creates per stored file. Run 1 issued 647,336
waits for 161,832 files. The ratio matches across two different disks. Both
containers were new and empty, so this is internal churn and not garbage
collection of earlier runs.

---

## Container disk behaviour

Perfmon, `H:` only, over each run:

| Metric | P40 | PremiumV2 |
|---|---|---|
| Write latency, average | 170.7 ms | **26.8 ms** |
| Write latency, maximum | 876.3 ms | **120.1 ms** |
| Samples over 200 ms | 128 of 393 | **0 of 152** |
| Queue depth, maximum | 29 | 20 |
| Throughput, average | 95.2 MB/s | **277.4 MB/s** |
| Throughput, maximum | 275.3 MB/s | **585.3 MB/s** |

On the P40 the container disk was the bottleneck. A third of all samples sat
above 200 ms, and throughput pinned at the SKU cap. On PremiumV2 no sample
crossed 200 ms. The bottleneck moved off the disk and onto per-file overhead.

The two commit timeouts in run 1 fit this picture. Commit latency on the P40
averaged 1,666 ms for Huge files. The worst single file took 80.8 seconds end to
end. Run 2 had no timeouts, and its worst single file took 5.9 seconds.

---

## Configuration findings

**`max server memory` was unbounded before these runs.** On a 64 GB VM the buffer
pool can take everything, which starves the Windows system file cache. This
matters more for FILESTREAM than for a normal workload. FILESTREAM I/O never uses
the buffer pool, because the blobs never pass through it. No SQL-side counter
shows this. The value is capped at 56,000 MB for both valid runs.

**The container disk was the weakest disk on the box. It no longer is.** It was a
P40 `Premium_LRS` at about 250 MB/s, while `F:` and `G:` were `PremiumV2_LRS`.
All three are now `PremiumV2_LRS` with caching set to `None`.

**Disk size does not imply PremiumV2 provisioning.** Throughput and IOPS are set
independently, and both default low. A 2048 GB PremiumV2 disk left at the default
125 MB/s is slower than the P40 it replaces. Check the provisioned values before
you treat a PremiumV2 disk as an upgrade.

**Ruled out as factors in these numbers:** Defender (excluded), 8.3 name
generation (off on `H:`), volume roles (verified against the instance default
paths), and ReFS (all volumes use NTFS).

---

## Open question: container drop time got worse

The drop of the previous 200 GB container took 555 seconds on PremiumV2. The same
drop took 85 seconds on the P40. The file counts match. That is 292 file
deletions per second against 1,903, which is 6.5 times worse.

This runs against every other measurement here. In-run
`PREEMPTIVE_OS_DELETEFILE` waits got faster on PremiumV2, at 1.08 ms average
against 1.32 ms. Per-file deletes during ingest improved. Bulk container removal
got much worse.

We have no explanation yet. The loss of `ReadOnly` host caching on directory
metadata reads is one candidate. Nobody has tested it. This matters in practice.
A drop sits between every pair of clean runs, and it is now the longest step in
the cycle.

---

## Not yet done

1. **The A/B against in-table `varbinary(max)`.** The POC exists to make this
   comparison, and it has not run. `Invoke-PocRun.ps1 -Matrix` covers it. Without
   it, everything above describes the cost curve of FILESTREAM in isolation.
2. **A `FULL` recovery run.** Every run so far used `SIMPLE`. Under `FULL` the
   log backup chain carries the FILESTREAM data. Backup size, backup duration and
   log management all change a lot.
3. **The read path.** `FilestreamRead` and `BlobRead` have not run. Ingest
   performance alone is half an answer.
4. **Process Monitor per-operation anatomy.** No capture has succeeded. Procmon
   cannot generate a `.pmc` config file headlessly. Procmon 4.1 has `/LoadConfig`
   but no `/SaveConfig`, and it ignores a hand-written `.pmc` without a message.
   The GUI export in `procmon/README.md` is the only route. Until then we have no
   NTFS-level breakdown of the per-file time.
5. **The cause of the drop regression above.**

---

## Reproducing

```powershell
# clean baseline - the container must be empty, or directory pressure
# costs roughly 2x per-file throughput
sqlcmd -S . -E -b -i sql\99-cleanup.sql -v DbName="FsPocDemo" Mode="drop"
.\ps\Setup-FilestreamPoc.ps1
.\ps\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 200
```

Allow about 10 minutes for the drop on PremiumV2.

Early progress looks stalled on both disks. The Tiny and Small buckets hold about
154,000 files that carry only 20 GB. The progress ETA extrapolates that rate
across the whole target. Throughput climbs sharply when the run reaches Medium.
That phase took about 17 minutes on the P40 and about 6 minutes on PremiumV2.
