# FILESTREAM POC — findings

Run date: 2026-09-10. Target VM: `SQL1` (Azure, eastus).

Four 200 GB ingest attempts were made. **One produced a valid result**; the
others are documented here because why they failed is itself a finding.

---

## Environment

| | |
|---|---|
| VM | `Standard_E8ads_v5` — 8 vCPU, 63.9 GB RAM |
| OS | Windows Server 2022 Datacenter, build **20348.5256** (last CU installed 2026-06-07) |
| SQL Server | 2019 — 15.0.4470.1, FILESTREAM effective level 2 |
| `max server memory` | 56,000 MB (was unlimited for the first run — see [Configuration findings](#configuration-findings)) |

Storage layout:

| Volume | Role | Disk | Host caching |
|---|---|---|---|
| `F:` SQLVMDATA1 | MDF, XEvents | 1024 GB `PremiumV2_LRS` | None |
| `G:` SQLVMLOG | LDF (16 GB, presized) | 1024 GB `PremiumV2_LRS` | None |
| `H:` Filestream | **FILESTREAM container** | 2048 GB `Premium_LRS` (P40, ~250 MB/s cap) | **ReadOnly** |
| `C:` Windows | Results, traces | 127 GB `Premium_LRS` | ReadWrite |
| `D:` Temporary Storage | tempdb | ephemeral | — |

All volumes NTFS with 64 KB allocation units. 8.3 name generation disabled on
`H:`. Defender exclusions in place for `H:\FilestreamData` and `sqlservr.exe`
(verified — Defender is **not** implicated in any finding below).

---

## Headline result

**200.00 GB in 161,834 files, 32m 37s, ~104.5 MB/s aggregate (82.7 files/sec)**
across 8 threads at a 4 MB chunk size, `Mixed` profile, `SIMPLE` recovery.

RunId `04EAFF19-8D8E-41E4-B59E-3F75BFBC0770`, results in
`C:\FsPocResults\run_20260910_152357_Filestream_Mixed`.

> The client reported 199.54 GB / 161,832 files and the database holds
> 200.00 GB / 161,834. The two-file gap is real and worth understanding: two
> commits exceeded their timeout, the client recorded them as failures, and
> **both transactions had in fact committed server-side**. A commit timeout is
> an ambiguous outcome, not a failed one — the client cannot tell whether the
> server committed. The ingest currently assumes failure, so it slightly
> *under*-reports bytes rather than over-reporting them. Nothing was lost.

### Do not quote the 144.9 MB/s figure

An earlier attempt (RunId `FAF22B6E`) reported **199.21 GB in 1,408s = 144.9 MB/s**
and that number is invalid. The machine bugchecked **25 seconds after the run
reported completion**, during the write-back drain. It was reporting throughput
for writes the disk had not yet absorbed — the data was still in the Windows
file cache when the box fell over.

The 104.4 MB/s figure is from the run where the writes actually landed and the
machine stayed up. That is the number to use.

This is a general trap for FILESTREAM benchmarking, not a quirk of this kit:
FILESTREAM writes go through the **Windows system file cache**, not the SQL
Server buffer pool. Client-side throughput can outrun the disk indefinitely
until the cache stops absorbing. During the valid run the client reported
bursts of 425 MB/s while Perfmon showed `H:` sustaining 101 MB/s.

---

## The actual question: where is the crossover?

Client-measured, per file, from `FsPocMonitor.dbo.IngestTiming`:

| Bucket | Files | Avg size | Open ms | Write ms | Commit ms | P50 ms | P95 ms | P99 ms | Max ms | Effective MB/s |
|---|---|---|---|---|---|---|---|---|---|---|
| Tiny | 123,237 | 0.03 MB | 12.27 | 14.14 | 22.77 | 45.83 | 74.01 | 91.59 | 1,567 | **0.7** |
| Small | 30,653 | 0.53 MB | 12.75 | 14.32 | 25.81 | 42.28 | 79.72 | 221 | 2,244 | **10.1** |
| Medium | 7,206 | 8.53 MB | 58.45 | 187.59 | 205.86 | 242 | 1,652 | 3,448 | 10,947 | **18.9** |
| Large | 706 | 129.87 MB | 308.08 | 2,335 | 1,222 | 3,187 | 10,112 | 13,114 | 17,369 | **33.6** |
| Huge | 30 | 1,024 MB | 449.86 | 17,905 | 1,666 | 14,948 | 48,080 | 73,432 | 80,773 | **51.1** |

Three things fall out of this:

**1. Per-file overhead dominates below ~1 MB.** A Tiny file averages 49 ms
end-to-end, of which only 14 ms is the actual write — the other 35 ms is the
`PathName()` round trip and the commit. Effective throughput is 0.7 MB/s. At
this size the fixed cost per file *is* the cost.

**2. The commit outweighs the write up to ~8 MB.** For Tiny, Small and Medium,
`AvgCommitMs` is at or above `AvgWriteMs`. The commit is a durability flush;
below Medium you are paying more for flushing than for writing. Batching more
files per transaction is the obvious lever, and the ingest does not currently
support it (one transaction per file).

**3. Effective throughput never plateaus.** 0.7 → 10.1 → 18.9 → 33.6 → 51.1 MB/s
climbing monotonically with size, and even 1 GB files only reach 51.1 MB/s
per stream against a disk that caps at 250 MB/s. FILESTREAM remains
overhead-bound at every size tested here; the 104.4 MB/s aggregate comes from
running 8 streams, not from any single stream getting close to the disk.

**The A/B against in-table `varbinary(max)` has not been run yet.** Without it
these numbers describe FILESTREAM's cost curve but do not answer whether
FILESTREAM is the right choice. That is the single most important outstanding
item — see [Not yet done](#not-yet-done).

### Where the server-side time went

From `sys.dm_os_wait_stats` deltas over the valid run:

| Wait | Time (s) | % | Avg ms | Meaning |
|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 10,063 | 43.9 | 12.53 | FILESTREAM work queue |
| `PREEMPTIVE_OS_FILEOPS` | 5,445 | 23.8 | 33.60 | Win32 file ops on the container |
| `PREEMPTIVE_OS_CREATEFILE` | 3,785 | 16.5 | 5.85 | New container file — NTFS metadata |
| `PREEMPTIVE_OS_DELETEFILE` | 625 | 2.7 | 1.32 | Container file delete |
| `WRITELOG` | 328 | 1.4 | 1.95 | Log flush |

Note that `PREEMPTIVE_OS_*` accounts for ~43% of wait time. Standard "top waits"
scripts filter that family out as idle noise, which is why FILESTREAM
investigations so often come back empty-handed.

**Container churn is much higher than the file count suggests.** For 161,832
files stored, the run issued 647,336 `CREATEFILE` and 473,991 `DELETEFILE`
waits — roughly 4 creates and 3 deletes per stored file. This was measured on a
**freshly created, empty container**, so it is FILESTREAM's own internal
churn, not garbage collection of prior runs. It reproduced within 0.1% across
two independent runs.

---

## Known platform defect: bugcheck 0x18 during FILESTREAM ingest

The machine bugchecked **three times** on 2026-09-09/10, all during or
immediately after FILESTREAM ingest:

| Time | Bugcheck | Dump |
|---|---|---|
| 09-09 23:48:37 | `0x18 REFERENCE_BY_POINTER` | `090926-22562-01.dmp` |
| 09-10 00:12:02 | `0x18 REFERENCE_BY_POINTER` | `091026-20078-01.dmp` |
| 09-10 02:18:59 | `0x18 REFERENCE_BY_POINTER` | `091026-21015-01.dmp` |

Identical parameters all three times (`0, <ptr>, 0x10, 1`). `!analyze -v` on the
newest dump gives `FAILURE_BUCKET_ID: 0x18_disk!DiskFlushDispatch`,
`PROCESS_NAME: sqlservr.exe`, and this stack:

```
nt!KeBugCheckEx
nt!ObfReferenceObject
Ntfs!NtfsIoPerfPostFileObjectInfo        <- faulted while recording
Ntfs!NtfsIoPerfPostFileObjectLatency
Ntfs!FsLibIoPerfNotifyHighLatency        <- NTFS observed a slow I/O
Ntfs!FsLibIoPerfBucketizeImpl
Ntfs!NtfsIoPerfCollectFlushData
Ntfs!NtfsFlushCompletionRoutine
nt!IofCompleteRequest
storport!Raid*
disk!DiskFlushDispatch
  ...
Ntfs!NtfsCommonFlushBuffers              <- the originating flush
```

NTFS observes a high-latency flush, enters its I/O telemetry path to record it,
and references a file object whose count is already zero.

**This is a Windows NTFS defect.** A user-mode program cannot corrupt a kernel
object's reference count; it can only issue I/O that reaches the defective
path. `MODULE_NAME: disk` is a red herring — `!analyze` attributes the fault to
the driver owning the IRP, which on a completion-path fault sits several frames
below the code that faulted. `disk.sys` is an inbox Microsoft driver.

### What triggers it here

The path is entered on **high-latency flushes**, and the container disk reaches
that condition routinely:

| | Crashed run | Valid run |
|---|---|---|
| `H:` write latency, avg | 250–420 ms sustained | 170.7 ms |
| `H:` write latency, max | — | 876.3 ms |
| Samples over 200 ms | — | 128 of 393 |
| Queue depth, max | 14–18 | 29 |

`H:` is a **P40 `Premium_LRS` capped at ~250 MB/s** — the slowest disk on the
box, while the MDF and LDF sit on far more capable `PremiumV2_LRS` disks that
barely need the throughput. It is also set to **`ReadOnly` host caching**,
against the guidance in the kit's own README for a write-heavy workload.

Saturating this disk is deliberate — the POC exists to measure FILESTREAM under
I/O pressure — so the trigger condition cannot be designed away without
changing the experiment.

### Current status: survived, not fixed

After `max server memory` was capped at 56,000 MB (it had been at the
unlimited default of 2147483647 on a 64 GB box), the valid run completed with
**a third of its samples above 200 ms and a peak of 876 ms** — past the
conditions that killed the machine three times — without a bugcheck.

That is meaningful evidence the change helped: FILESTREAM I/O flows through
the Windows system file cache, and an unbounded buffer pool starves the cache
those flushes depend on.

**It is not proof.** The bugcheck is a race in a kernel telemetry path. One
clean run does not close it. Treat this as "not yet reproduced since the
change" rather than "resolved."

### Recommended actions

| Action | Effect |
|---|---|
| **Apply pending Windows CUs** | The box is ~3 months behind (build 20348.5256, last update 2026-06-07). Highest-value action that does not alter the experiment. |
| **Open a Microsoft support case with a dump** | The signature is specific and reproducible across three dumps. This is the only route to an actual fix. |
| Keep `max server memory` capped | Leaves the system file cache room to absorb the flush load. |
| Faster disk tier for the container | Fewer high-latency flushes reach the defective path. **Rejected for now** — saturating the disk is the experiment. |
| Batch files per transaction | Each commit forces a durability flush. Not currently supported by the ingest. |

Neither of the last two is a fix; they reduce how often the path is reached.

---

## Configuration findings

**`max server memory` was unbounded.** On a 64 GB VM the buffer pool was free to
take everything, starving the Windows system file cache. This matters more for
FILESTREAM than for a normal workload because FILESTREAM I/O does not use the
buffer pool at all — the blobs never pass through it. No SQL-side counter shows
this. Now capped at 56,000 MB.

**The container is on the weakest disk.** P40 `Premium_LRS` at ~250 MB/s, while
`F:` and `G:` are `PremiumV2_LRS`. If the goal ever shifts from "measure
FILESTREAM under pressure" to "measure how fast this can go", the container
needs to move.

**`H:` host caching is `ReadOnly`.** Should be `None` for a write-heavy POC.
`F:` and `G:` are correctly `None`.

**Not implicated:** Defender (excluded, and `WdFilter` does not appear on any
crash stack), 8.3 name generation (disabled on `H:`), volume roles (verified
against the instance default paths), ReFS (all volumes NTFS).

---

## Harness defects found and fixed

Seven real defects were found in the kit itself while chasing the above. All are
fixed and verified; none had been caught by `tests\Test-FsPocKit.ps1`, because
all seven are runtime or SQL-compile failures the parse/binding checks cannot see.

| # | File | Defect |
|---|---|---|
| 1 | `ps\Invoke-PocRun.ps1` | Passed `-y 0 -Y 40 -W` to sqlcmd, which rejects that combination as mutually exclusive and exits 1 before running a batch. **The analysis phase had never once run.** |
| 2 | `sql\06-xevent-shred.sql` | `PRINT` with a subquery is a *compile* error, failing the whole batch — so `SELECT … INTO #xe` never ran either. **The XEvent shred had never once run.** |
| 3 | `sql\06-xevent-shred.sql` | `DATEDIFF(second, 0, EventTime)` is ~4×10⁹ for a 2026 timestamp and overflows `int`, killing the final section. |
| 4 | `ps\FsPoc.Common.psm1` | `ProcmonExe` was a hardcoded path; when Procmon was on `PATH` instead, `-Procmon` silently became a no-op while still setting `ProcmonActive`. Now falls back to `PATH`. |
| 5 | `ps\Start-PocCapture.ps1` | A missing `.pmc` was passed to `/LoadConfig` inside a `/Quiet /Minimized` background job, where it surfaced nowhere. Now warns. |
| 6 | `ps\Invoke-FilestreamIngest.ps1` | **Most serious.** `SqlTransaction.Commit()` has no settable timeout; a slow commit under load broke the connection, and every later file on that worker failed instantly at `begin-transaction`. One slow commit manufactured 25 errors, tripped the error threshold, and set `Control.Stop` — which is **global**. A single slow commit stopped all 8 workers and ended a 200 GB run at 145 GB, reported as success. Errors are now classified structural vs transient; transient triggers a reconnect. |
| 7 | `ps\Invoke-PocRun.ps1` | Preflight checked only `DB_ID()`. A plain `CREATE DATABASE FsPocDemo` — no FILESTREAM filegroup, no tables, no procs — passed as "Preflight OK" and failed 141 times on a missing stored procedure. Now checks the FILESTREAM filegroup and both procs. |

Defect 6 was confirmed fixed in the field: the valid run hit **2 commit timeouts
— the identical failure that ended the previous run at 145 GB — recovered via
reconnect both times, and completed the full 200 GB.** Both of those
transactions turned out to have committed server-side anyway, so nothing was
lost at all.

### Known limitation, not yet fixed

The ingest treats a commit timeout as a definite failure. It is actually
*ambiguous* — the server may have committed, and in the valid run both
timed-out commits had. The consequences are mild and in the safe direction:
reported byte totals and file counts are slightly low, and `IngestTiming` has
no row for those files, so the per-bucket latency table excludes them. Resolving
it properly means re-checking whether the row landed before counting the file as
failed.

---

## Not yet done

1. **The A/B against in-table `varbinary(max)`.** This is the comparison the POC
   exists to make, and it has not been run. `Invoke-PocRun.ps1 -Matrix` covers
   it. Without it, everything above describes FILESTREAM's cost curve in
   isolation.
2. **`FULL` recovery run.** All runs so far are `SIMPLE`. Under `FULL`,
   FILESTREAM data enters the log backup chain and backup size, backup duration
   and log management change substantially.
3. **Read path.** `FilestreamRead` / `BlobRead` have not been run. Ingest
   performance alone is half an answer.
4. **Process Monitor per-operation anatomy.** Never successfully captured.
   Procmon's `.pmc` config file cannot be generated headlessly — Procmon 4.1 has
   `/LoadConfig` but no `/SaveConfig`, and a hand-written `.pmc` is silently
   ignored. The GUI export documented in `procmon/README.md` remains the only
   route. Until then there is no NTFS-level breakdown of where per-file time goes.
5. **Windows cumulative updates.** ~3 months behind.

---

## Reproducing

```powershell
# clean baseline — the container must be empty, or directory pressure
# costs roughly 2x per-file throughput
sqlcmd -S . -E -b -i sql\99-cleanup.sql -v DbName="FsPocDemo" Mode="drop"
.\ps\Setup-FilestreamPoc.ps1
.\ps\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 200
```

Expect the first ~17 minutes to look stalled: the Tiny and Small buckets are
153,890 files carrying only 20 GB, and the progress ETA extrapolates that rate
across the whole target. Throughput climbs sharply once the run reaches Medium.
