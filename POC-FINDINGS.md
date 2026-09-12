# FILESTREAM POC - performance findings

Azure SQL Server 2019 VMs, `Mixed` size profile, 8 threads, 4 MB chunk,
`SIMPLE` recovery, 200 GB per run. Ingest only; the read path is not yet
measured.

---

## Summary

| # | Configuration | Alloc | VM | Container | Files | Elapsed | MB/s | Files/s | P95 | Errors |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | P40 (Premium v1) | 64 KB | A | empty | 161,834 | 32m 38s | 104.4 | 82.7 | - | 2 commit timeouts |
| 2 | Premium v2 | 64 KB | A | empty | 162,051 | 12m 26s | **274.5** | 217.2 | - | 0 |
| 3 | Premium v2, more IOPS | 64 KB | A | empty | 162,143 | **11m 32s** | **296.0** | **234.4** | - | 0 |
| 4 | Premium v1 | 4 KB | B | empty | 161,675 | 25m 19s | 134.7 | 106.4 | 64.8 ms | 0 |
| 5 | **FileTable**, Premium v1 | 4 KB | B | **not empty** | 162,014 | 33m 58s | 100.5 | 79.5 | 228.0 ms | 0 client / **219 lock timeouts** |
| 6 | Premium v2 | 4 KB | B | empty | 162,124 | 19m 46s | 172.4 | 136.7 | **41.7 ms** | 0 |
| - | ~~Premium v1~~ | 64 KB | A | empty | - | 23m 28s | ~~144.9~~ | - | - | **INVALID** |

All runs are `Filestream` (transacted `SqlFileStream`) except run 5.
**VM A** = `Standard_E8ads_v5`, OS 20348.5256. **VM B** = a rebuild at the same
VM size, on the same disks, same SQL build. Runs 4-6 were traced with Procmon;
whether runs 1-3 were is not recorded, because `ProcmonActive` was stored as 0
on every run until that bug was fixed.

The invalid row is kept deliberately: the machine went down 25 seconds after
that run "completed" and the data was still in the Windows file cache, so the
disk never absorbed it. See
[Do not quote the 144.9 MB/s figure](#do-not-quote-the-1449-mbs-figure).

### What the numbers say

**FILESTREAM ingest is IOPS-bound, not bandwidth-bound.** Run 4 to 6 gave +28%
from provisioned IOPS, and **95% of the saved time came from files under 1 MB**.
Large files got 10% *slower*. Earlier, an 18% faster disk bought only 8% more
throughput. Bandwidth stopped mattering; per-operation cost did not.

**Small files are the workload.** In run 4, files averaging 33 KB were 2% of the
bytes and **46% of the elapsed time**. Per thread that is 0.84 MB/s against
77 MB/s for the large buckets -- a 92x difference inside one run on one disk.
The cost is per file and roughly flat: a 33 KB file and a 533 KB file cost the
same.

**The transaction log is never the constraint.** 1.4 GB of log for 200 GB of
data, `WRITELOG` under 3% of wait time at a 2.6 ms mean, in every run. Moving or
upgrading the log disk will not help this workload.

**The ceiling is moving off the disk.** `FILESTREAM_WORKITEM_QUEUE` -- the
FILESTREAM agent serialising file operations, not a disk wait -- fell 22% in
absolute terms from run 4 to run 6 but **grew from 40.5% to 42.7% of all wait
time**. Expect a further disk upgrade to return less than this one did.

**Four `CreateFile` calls per file written**, identical on both SKUs. Structural,
and the second largest wait.

**Client-reported throughput can outrun the disk.** One run reported 144.9 MB/s
for writes still sitting in the Windows file cache. FILESTREAM writes bypass the
SQL Server buffer pool and go through that cache, so client numbers need a
Perfmon cross-check before anyone quotes them.

### What is not settled

**A 37% gap that nothing in this report explains.** Premium v2 returned
274.5 MB/s at a 64 KB allocation unit (run 2) and 172.4 MB/s at 4 KB (run 6).
The disk and the VM size were the same. That leaves allocation unit as the
leading candidate for a 37% difference -- larger than the v1-to-v2 upgrade this
report spent three runs measuring.

It is not yet safe to credit, for two reasons:

1. **The v1 pair points the other way.** Run 1 (64 KB) managed 104.4 MB/s while
   run 4 (4 KB) managed 134.7 MB/s -- 4 KB *faster* by 29%. Run 1 also used
   `ReadOnly` host caching, which this report elsewhere finds never helps
   writes, so that comparison is not clean either. But two allocation-unit
   comparisons disagreeing in direction means neither is a measurement.
2. **Run 6 ran with Procmon active; whether runs 2 and 3 did is not recorded.**
   `ProcmonActive` was silently stored as 0 on every run until the bug was
   fixed, so the flag cannot answer this retrospectively. Tracing is windowed
   to 120s of a ~1,200s run, so it should account for a few percent at most --
   nowhere near 37% -- but it is a known uncontrolled difference.

A 64 KB run on the current VM settles it, and it is one reformat plus one run.
Given the size of the gap that is the highest-value remaining measurement in
this report -- ahead of the FileTable work, because a 37% configuration lever
matters more than sizing FileTable's deficit.

**FileTable has no clean measurement.** Run 5 went into a container already
holding 200 GB, and a populated container costs roughly 2x per-file throughput.
Its 34% deficit is an upper bound, not a result. The lock timeouts stand
regardless.

**Not attempted:** the read path, `FULL` recovery, `-FileTableFlush`, and
multiple FILESTREAM containers across disks.

---

## Environment

| | |
|---|---|
| VM | `Standard_E8ads_v5`, 8 vCPU, 63.9 GB RAM |
| OS | Windows Server 2022 Datacenter, build **20348.5256** |
| SQL Server | 2019, 15.0.4470.1, FILESTREAM effective level 2 |
| `max server memory` | 56,000 MB for all three valid runs |

Only the container disk changed between runs.

| Volume | Role | Disk | Host caching |
|---|---|---|---|
| `F:` SQLVMDATA1 | MDF, XEvents | 1024 GB `PremiumV2_LRS` | None |
| `G:` SQLVMLOG | LDF (16 GB, presized) | 1024 GB `PremiumV2_LRS` | None |
| `H:` **run 1** | FILESTREAM container | 2048 GB `Premium_LRS` (P40, about 250 MB/s) | ReadOnly |
| `H:` **run 2** | FILESTREAM container | 2048 GB `PremiumV2_LRS` | None |
| `H:` **run 3** | FILESTREAM container | 2048 GB `PremiumV2_LRS`, **more IOPS and bandwidth** | None |
| `C:` Windows | Results, traces | 127 GB `Premium_LRS` | ReadWrite |
| `D:` Temporary Storage | tempdb | ephemeral | - |

Every volume uses NTFS with 64 KB allocation units. 8.3 name generation is off on
`H:`. Defender excludes `H:\FilestreamData` and `sqlservr.exe`. We verified those
exclusions. Defender does not affect any number below.

**Runs 1 and 2 differ by two variables, not one.** The disk SKU changed. The host
caching changed with it. PremiumV2 does not offer host caching, so you cannot
separate the two. `None` is the correct setting for a write-heavy workload.
`ReadOnly` never helped writes. Read that step as "new disk configuration", not
"SKU alone". Runs 2 and 3 use the same SKU, so that step is clean.

### Measured disk capability

A synthetic test wrote through the cache to `H:` before runs 2 and 3:

| Test | Run 2 disk | Run 3 disk |
|---|---|---|
| Sequential, 4 streams, 4 MB blocks | 476.9 MB/s | **561.6 MB/s** |
| Random write IOPS, 8 threads, 8 KB | not measured | **9,342** |

The sequential test is the only like-for-like comparison, because nobody
measured IOPS before run 3. An 8-stream variant returned 458.4 MB/s, below the
4-stream result. Treat that as a limit of the test harness: 8 PowerShell job
processes compete for 8 vCPUs. The runs themselves peaked higher than either
test, at 585.3 MB/s and 613.4 MB/s.

PremiumV2 sets throughput and IOPS independently of disk size. Both default low,
at 125 MB/s. Someone provisioned this disk above that default for run 2, then
raised it again for run 3. A default PremiumV2 disk is slower than the P40 it
replaced.

---

## Headline result

All three runs wrote exactly 200.00 GB. All used 8 threads, a 4 MB chunk size,
the `Mixed` profile and `SIMPLE` recovery. All wrote into a new, empty container.

| | Run 1: P40 | Run 2: PremiumV2 | Run 3: PremiumV2 boosted |
|---|---|---|---|
| RunId | `04EAFF19` | `7CDD0CC9` | `C4F97564` |
| Files | 161,834 | 162,051 | 162,143 |
| Elapsed | 32m 38s | 12m 26s | **11m 32s** |
| Throughput | 104.4 MB/s | 274.5 MB/s | **296.0 MB/s** |
| Files per second | 82.7 | 217.2 | **234.4** |
| Errors | 2 commit timeouts | 0 | **0** |
| Gain over previous | - | **2.63x** | **1.08x** |

The kit randomises file sizes per run, so the file counts differ. All three runs
hit the 200.00 GB target exactly.

**The returns collapse after run 2.** The first upgrade gave 2.63 times the
throughput. The second gave 1.08 times, for a disk that measures 18% faster in a
sequential test. The disk stopped limiting ingest at run 2. See
[Where the bottleneck sits now](#where-the-bottleneck-sits-now).

Results are in `C:\FsPocResults\run_20260910_152357_Filestream_Mixed`,
`run_20260910_184032_Filestream_Mixed` and `run_20260910_192014_Filestream_Mixed`.

> **Measurement note on run 1.** The client reported 199.54 GB in 161,832 files.
> The database holds 200.00 GB in 161,834 files. Two commits passed their
> timeout, and the client counted them as failures. Both transactions had
> committed.
>
> A commit timeout is ambiguous, not failed. The client cannot tell whether the
> server committed. The client assumes failure, so it under-reports bytes instead
> of over-reporting them. `IngestTiming` holds no row for those two files, so the
> per-bucket tables below exclude them. Runs 2 and 3 had no timeouts.

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
`FsPocMonitor.dbo.IngestTiming`. Effective MB/s per bucket:

| Bucket | Avg size | Run 1: P40 | Run 2: PremiumV2 | Run 3: boosted |
|---|---|---|---|---|
| Tiny | 0.03 MB | 0.7 | 1.7 | **1.8** |
| Small | 0.53 MB | 10.1 | 24.7 | **25.8** |
| Medium | about 8.5 MB | 18.9 | 42.2 | **50.6** |
| Large | about 135 MB | 33.6 | 145.7 | **175.9** |
| Huge | about 1,000 MB | 51.1 | 784.7 | **543.8** |

Median latency per file:

| Bucket | Run 1: P40 | Run 2: PremiumV2 | Run 3: boosted |
|---|---|---|---|
| Tiny | 45.8 ms | 18.0 ms | **17.7 ms** |
| Small | 42.3 ms | 18.0 ms | **16.3 ms** |
| Medium | 242 ms | 25.4 ms | **46.3 ms** |
| Large | 3,187 ms | 716 ms | **559 ms** |
| Huge | 14,948 ms | 990 ms | **1,495 ms** |

The Huge bucket holds 28 to 33 files per run. Its numbers move a lot between runs
for that reason. Do not read the run 2 to run 3 change in that row as a
regression. The sample is too small.

The per-file cost breakdown on run 3:

| Bucket | Open ms | Write ms | Commit ms |
|---|---|---|---|
| Tiny | 4.64 | 6.44 | 7.77 |
| Small | 5.13 | 6.56 | 8.83 |
| Medium | 34.83 | 35.26 | 98.58 |
| Large | 145.77 | 192.02 | 441.87 |
| Huge | 529.91 | 556.68 | 931.02 |

Two findings hold on all three disks.

**1. Per-file overhead dominates below about 1 MB.** On the P40 a Tiny file takes
49 ms end to end, and only 14 ms of that is the write. On run 3 it takes 19 ms,
and only 6.4 ms is the write. The proportion barely moves across a 2.8x range of
disk speed. The rest is the `PathName()` round trip and the commit. At this size
the fixed cost per file is the cost.

**2. The commit costs more than the write at every size.** On run 3 `AvgCommitMs`
sits above `AvgWriteMs` in all five buckets. The commit is a durability flush.
Batching more files per transaction is the obvious lever. The ingest does not
support it today, because it uses one transaction per file.

---

## Where the bottleneck sits now

An earlier version of this report said effective throughput never plateaus. It
concluded that FILESTREAM stays overhead-bound at every size tested. **Run 2
disproved that.** The large end was disk-bound on the P40, not overhead-bound.

Run 3 shows where the limit moved to.

| Step | Sequential disk speed | Ingest throughput | Ingest gain |
|---|---|---|---|
| Run 1, P40 | about 250 MB/s | 104.4 MB/s | - |
| Run 2, PremiumV2 | 476.9 MB/s | 274.5 MB/s | 2.63x |
| Run 3, boosted | 561.6 MB/s | 296.0 MB/s | 1.08x |

Run 1 to run 2 raised the disk by about 1.9 times and the ingest by 2.63 times.
Run 2 to run 3 raised the disk by 1.18 times and the ingest by 1.08 times. The
second upgrade returned less than the hardware change that bought it.

Perfmon confirms the cause. On run 3 the container disk averaged 21.7 ms write
latency, and no sample crossed 200 ms. The disk has headroom. The ingest does not
use it, because it waits on per-file work instead.

**The small end never benefits.** Tiny went 0.7, then 1.7, then 1.8 MB/s. The
first upgrade helped it a little. The second did not help it at all. The spread
from Tiny to Huge is now about 300 times.

> If the workload is small files, faster storage does not rescue it. The per-file
> cost is the `PathName()` round trip plus the commit. Neither is a throughput
> problem. Storage spend helps the large end. It helps the small end barely at
> all, and it stops helping anything once the disk clears the workload.

**The A/B against in-table `varbinary(max)` has not run yet.** These numbers
describe the cost curve of FILESTREAM. They do not tell you whether FILESTREAM is
the right choice. This is the most important open item. See
[Not yet done](#not-yet-done).

---

## Where the server-side time went

From `sys.dm_os_wait_stats` deltas over each run. Total wait time in seconds:

| Wait | Run 1 | Run 2 | Run 3 | Run 3 avg ms |
|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 10,063 | 4,110 | 3,733 | 4.46 |
| `PREEMPTIVE_OS_FILEOPS` | 5,445 | 2,253 | 1,911 | 11.77 |
| `PREEMPTIVE_OS_CREATEFILE` | 3,785 | 1,753 | 1,580 | 2.44 |
| `PREEMPTIVE_OS_DELETEFILE` | 625 | 464 | 415 | 0.86 |
| `WRITELOG` | 328 | 197 | 291 | 1.77 |

The `PREEMPTIVE_OS_*` family takes about 43% of wait time on all three runs.
Standard "top waits" scripts filter that family out as idle noise. That is why
FILESTREAM investigations so often come back empty-handed.

**Container churn is much higher than the file count suggests.** It is a property
of FILESTREAM, not of the storage. Run 3 stored 162,143 files and issued 648,572
`CREATEFILE` waits. That is about 4 creates per stored file. Run 1 issued 647,336
waits for 161,832 files, and run 2 issued 648,204 for 162,051. The ratio holds
across three disk configurations.

---

## Container disk behaviour

Perfmon, `H:` only, over each run:

| Metric | Run 1: P40 | Run 2: PremiumV2 | Run 3: boosted |
|---|---|---|---|
| Write latency, average | 170.7 ms | 26.8 ms | **21.7 ms** |
| Write latency, maximum | 876.3 ms | 120.1 ms | **119.0 ms** |
| Samples over 200 ms | 128 of 393 | 0 of 152 | **0 of 140** |
| Queue depth, maximum | 29 | 20 | 24 |
| Throughput, average | 95.2 MB/s | 277.4 MB/s | **301.7 MB/s** |
| Throughput, maximum | 275.3 MB/s | 585.3 MB/s | **613.4 MB/s** |

On the P40 the container disk was the bottleneck. A third of all samples sat
above 200 ms, and throughput pinned at the SKU cap. From run 2 onward no sample
crosses 200 ms.

The two commit timeouts in run 1 fit this picture. Commit latency on the P40
averaged 1,666 ms for Huge files, and the worst single file took 80.8 seconds end
to end. Runs 2 and 3 had no timeouts.

---

## Container deletion needs IOPS, not bandwidth

An earlier version of this report carried this as an open question. Run 3 answers
it.

Dropping the previous 200 GB container takes:

| Disk | Drop time | Deletions per second |
|---|---|---|
| Run 1, P40 | 85s | 1,903 |
| Run 2, PremiumV2 | 555s | 292 |
| Run 3, PremiumV2 boosted | **29s** | **5,591** |

The run 2 disk had enough bandwidth and not enough IOPS. Bulk container removal
is almost pure metadata work, so it ran 6.5 times slower than on the P40. Raising
the IOPS fixed it. Run 3 deletes about 19 times faster than run 2 and about 3
times faster than the P40.

The earlier candidate explanation was the loss of `ReadOnly` host caching on
directory metadata reads. That explanation is wrong. Host caching is `None` on
both run 2 and run 3, and the drop time still fell by 19 times.

**This is the clearest IOPS-bound result in the POC.** Ingest throughput gained
8% from the same hardware change, and container deletion gained 1,800%. The two
workloads need different things from the same disk.

---

## Configuration findings

**`max server memory` was unbounded before these runs.** On a 64 GB VM the buffer
pool can take everything, which starves the Windows system file cache. This
matters more for FILESTREAM than for a normal workload. FILESTREAM I/O never uses
the buffer pool, because the blobs never pass through it. No SQL-side counter
shows this. The value is capped at 56,000 MB for all three valid runs.

**The container disk was the weakest disk on the box. It no longer is.** It was a
P40 `Premium_LRS` at about 250 MB/s, while `F:` and `G:` were `PremiumV2_LRS`.
All three are now `PremiumV2_LRS` with caching set to `None`.

**Disk size does not imply PremiumV2 provisioning.** Throughput and IOPS are set
independently, and both default low. A 2048 GB PremiumV2 disk left at the default
125 MB/s is slower than the P40 it replaces. Check the provisioned values before
you treat a PremiumV2 disk as an upgrade.

**Provision IOPS for the maintenance work, not for the ingest.** The ingest stops
caring about the disk once it clears about 475 MB/s. Container deletion keeps
caring well past that point, and it is the longest step in a clean-run cycle when
IOPS run short.

**Ruled out as factors in these numbers:** Defender (excluded), 8.3 name
generation (off on `H:`), volume roles (verified against the instance default
paths), and ReFS (all volumes use NTFS).

---

## Run 4: Premium v1 4k

RunId `60E942B1-FB12-49DA-B7C0-782F851EA8E9`, 2026-09-11.
Results in `C:\FsPocResults\run_20260911_225442_Filestream_Mixed`.

| | |
|---|---|
| Configuration | **Premium v1 4k** |
| Files | 161,675 |
| Elapsed | 25m 19s |
| Throughput | **134.8 MB/s** |
| Files per second | 106.4 |
| Errors | **0** |
| Procmon | active, 120s window, 851.73 MB trace (unconverted) |

Same 8 threads, 4 MB chunk, `Mixed` profile and `SIMPLE` recovery as runs 1-3.

> **This ran on a rebuilt VM.** Treat the comparison against runs 1-3 as
> indicative, not controlled: the disk SKU is the labelled variable but the
> machine underneath it was replaced, and nothing in the kit records VM size or
> allocation unit. Confirm both before quoting 134.8 MB/s against the 104.4 MB/s
> P40 figure.

### Small files consume the run

Thread-time per bucket, from `IngestTiming` (files x mean open+write+commit):

| Bucket | Files | Mean/file | Thread-sec | % of time | GB | % of bytes |
|---|---|---|---|---|---|---|
| Tiny | 122,939 | 39.8 ms | 4,890 | **45.6%** | 4 | 2.0% |
| Small | 30,754 | 41.2 ms | 1,267 | 11.8% | 16 | 8.0% |
| Medium | 7,263 | 407.6 ms | 2,961 | 27.6% | 60 | 30.0% |
| Large | 683 | 2,192 ms | 1,497 | 14.0% | 90 | 45.0% |
| Huge | 36 | 2,743 ms | 99 | 0.9% | 30 | 15.0% |

**Tiny files are 2% of the bytes and 46% of the elapsed time.** Files under
1 MB together are 10% of the bytes and 57% of the time. Large and Huge together
are 60% of the bytes and 15% of the time.

Per thread that is 0.84 MB/s for Tiny against 77.1 MB/s for Large+Huge -- a
**92x** difference in bytes moved per unit of time, on identical hardware in a
single run. The cost is per file, not per byte, and it is roughly 40 ms flat:
a 33 KB file and a 533 KB file cost the same 40 ms.

The 10,714 thread-seconds above divided by 8 threads is 1,339s against 1,520s
elapsed, so 88% of wall time is accounted for by measured per-file work. The
remainder is scheduling and queueing.

### Commit is half the cost, and it is not the log

Commit as a share of per-file time rises with size and is the largest component
in every bucket: Tiny 46%, Small 49%, Medium 52%, Large 56%, Huge 62%. Summed
across all files, commit is **5,332 thread-seconds -- 49.8% of all measured
work**.

That time is not log flush. `WRITELOG` totals 488s across the whole run, 9% of
commit time, at a mean of 2.93 ms. The log wrote 1,374.8 MB for a 200 GB load
and averaged 1.79 ms per write. **The transaction log is not a bottleneck here
and moving it will not help.**

What commit actually pays for shows up in the top wait:

| Wait | Time | Waits | Per file | Mean |
|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 8,069s | 864,491 | 5.35 | 9.33 ms |
| `PREEMPTIVE_OS_FILEOPS` | 4,775s | 161,896 | 1.00 | 29.5 ms |
| `PREEMPTIVE_OS_CREATEFILE` | 4,015s | 646,700 | **4.00** | 6.21 ms |
| `PREEMPTIVE_OS_DELETEFILE` | 762s | 472,092 | **2.92** | 1.61 ms |
| `PREEMPTIVE_OS_FINDFILE` | 42s | 633,237 | 3.92 | 0.07 ms |
| `WRITELOG` | 488s | 166,710 | 1.03 | 2.93 ms |

`FILESTREAM_WORKITEM_QUEUE` is 40.5% of all wait time and was not visible in
earlier reports: the analysis classified it as "Other" because the pattern
`FS[_]%` requires a literal underscore after `FS`. Fixed.

Two counts are worth pursuing:

- **4.00 `CreateFile` per file written.** Exactly four, not approximately four.
  That is NTFS metadata work the container pays per file and it is the second
  largest wait.
- **2.92 `DeleteFile` per file**, 472,092 deletions during a load that only
  wrote files. Garbage collection ran throughout. Whether it was collecting this
  run's intermediates or a previous container's tombstones changes what the
  number means, and the Procmon trace can tell them apart.

Both are answerable from the 851 MB trace already on disk:

```powershell
.\ps\Invoke-PocAnalysis.ps1 -ConvertProcmon
```

### The measurement path is sound

`sys.dm_io_virtual_file_stats` recorded 1,374.8 MB written to the log and
174.4 MB to the MDF for a 200 GB load -- **0.77% of the data**. The other 99.2%
went through Win32 streaming, invisible to every SQL Server I/O DMV. That is the
design working as intended, and it is why the client-side timings rather than
the DMVs carry the result.

### Latency tail

P99 is far from the mean for the larger buckets: Large P99 12.3s against a
1.68s median, Medium P99 4.2s with a 15.1s maximum. `PREEMPTIVE_OS_FILEOPS` and
`PREEMPTIVE_OS_CREATEFILE` both peak at ~13.2s, so the tail is Win32 file
operations stalling rather than data transfer. Size the application's timeouts
against P99, not the mean.

### The cost is concentrated in a slow minority

The event session captures only waits of 10 ms or more, which makes the gap
between it and the DMV totals informative: it says how much of each wait's cost
sits in its slow tail.

| Wait | DMV total | Waits | XE (>=10ms) | Share of waits | Share of time |
|---|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 8,069s | 864,491 | 7,195s | 17% | **89%** |
| `PREEMPTIVE_OS_CREATEFILE` | 4,015s | 646,700 | 1,907s | 6% | **48%** |
| `PREEMPTIVE_OS_FILEOPS` | 4,775s | 161,896 | 4,380s | 80% | 92% |

`FILESTREAM_WORKITEM_QUEUE` and `CreateFile` behave the same way: a small
minority of calls carries most of the cost. Six percent of `CreateFile` waits
account for half its total time. That is queueing, not a uniform per-call
price, and it means the average is the wrong number to design against -- the
mean `CreateFile` wait is 6.2 ms while the slow ones average 46.7 ms and peak
at 12.1 seconds.

`PREEMPTIVE_OS_FILEOPS` is different: 80% of its waits are already over 10 ms.
That one is uniformly expensive at ~30 ms per file.

`WRITELOG` over 10 ms totals 160s across the run at a 194 ms maximum. It is not
a factor at any percentile.

> **Reading the raw shred output.** Before this run the shred applied no benign
> filter, so it led with `SOS_WORK_DISPATCHER` at 57,201 seconds against a
> 1,520 second run -- idle workers parked waiting for work. Three more idle
> timers followed. Fixed: the shred now applies the same `dbo.BenignWait` list
> as the DMV analysis and prints what it excluded rather than dropping it
> silently.

### No bugcheck

Runs on the previous VM took it down twice with `0x18 REFERENCE_BY_POINTER` in
`Ntfs!NtfsIoPerfPostFileObjectInfo` on a high-latency flush completion. This run
completed with Procmon active and zero errors. That is consistent with the
defect being reached only under high flush latency, but one clean run is not
evidence it is gone.

---

## Run 5: FileTable, same disk, same profile

RunId `B9F71085-2BC4-4794-B8CC-CE55B74D0889`, immediately after Run 4 on the
same VM, same disk, same 8 threads / 4 MB chunk / `Mixed` profile.

| | Run 4: Filestream | Run 5: FileTable |
|---|---|---|
| Files | 161,675 | 162,014 |
| Elapsed | **25m 20s** | 33m 58s |
| Throughput | **134.7 MB/s** | 100.5 MB/s |
| P95 per file | **64.8 ms** | 228.0 ms |
| Top wait | `FILESTREAM_WORKITEM_QUEUE` | `PREEMPTIVE_OS_FILEOPS` |
| Client-visible errors | 0 | 0 |

**FileTable was 34% slower with a P95 3.5x worse.**

> ### Correction: this run is confounded
>
> Run 5 was **not** written into an empty container. The Reset before Run 6
> reported the container holding 323,689 files -- exactly 161,675 + 162,014, so
> Run 4's output was still present for the whole of Run 5. Run 4 and Run 6 both
> started empty; Run 5 did not.
>
> This report already establishes that a populated container costs roughly 2x
> the per-file throughput of an empty one. Run 5's 34% deficit therefore mixes
> FileTable's own cost with directory pressure that Run 4 never paid, and the
> two cannot be separated from this data.
>
> **Treat 34% as an upper bound on FileTable's penalty, not a measurement of
> it.** The lock timeouts below are unaffected -- those are contention in the
> row-materialisation path and have nothing to do with how full the container
> is -- and so is the observation that skipping the transaction relocates work
> rather than removing it. What is not safe to quote is the size of the gap.
>
> A FileTable run into an empty container is needed to settle it. The preflight
> now refuses to start a run against a non-empty container for exactly this
> reason, which is a guard added after this run rather than before it.

Setting the confound aside, the direction of the result still contradicts the
expectation the path was added under. FileTable performs no
transaction and no commit flush, so it should have been the cheaper of the two;
the kit's own documentation said to expect it to win and to read the gap as the
price of transactional consistency. On this hardware the gap runs the other way,
and transactional consistency came free.

Do not generalise this to "FileTable is slow". It is one configuration on one
disk. What it does establish is that the cheaper-looking path is not
automatically the faster one, and that the question has to be measured rather
than reasoned about.

### Why: the work moves, it does not disappear

Skipping the transaction does not remove the work, it relocates it. Comparing
what SQL Server saw in each run:

| | Filestream | FileTable |
|---|---|---|
| `sql_transaction` events | 648,132 | **1,778** |
| MDF/LDF written | 64.8 MB | **131.0 MB** |
| `WRITELOG` waits >=10ms | 12,150 | **5** |

SQL Server is almost idle during the FileTable run -- 365x fewer transaction
events, essentially no log pressure. Yet it finished slower. The cost moved into
two places the transactional path does not pay:

1. **The SMB loopback.** The client writes to
   `\\SQL1\MSSQLSERVER\FsPocDemo\FileStoreFT\...` rather than through a
   streaming handle. Even on the same machine that traverses the SMB redirector
   and the server stack.
2. **Row materialisation.** Every file becomes a row carrying a `hierarchyid`
   `path_locator`, name, and attributes, built by the filter driver outside any
   transaction the client controls. That is why FileTable wrote *twice* as much
   to the MDF and LDF while running 365x fewer transactions.

### Lock timeouts, invisible to the client

The event session captured **219 `error_reported` events, every one Msg 1222,
"Lock request time out period exceeded"**, spread across at least 15 distinct
session ids over the whole run.

The client reported zero errors and wrote all 200.00 GB, so these are internal
retries, not lost work. They are still a finding: nothing in the client-side
timings or the DMV wait deltas shows them, and they are the clearest signal
available that the FileTable row-materialisation path is contending with itself
under concurrent load. The 3.5x P95 penalty and these timeouts are very likely
the same phenomenon.

This is the strongest argument in the report for capturing `error_reported` in
the event session. A run that looks clean from the client is not necessarily
clean.

### What this changes

For a write-heavy ingest at this concurrency, FILESTREAM with `SqlFileStream`
was both **faster and transactional** -- by an amount this run cannot pin down,
for the reason given above. The direction is solid: the non-transacted path did
not win despite having no commit to pay for, it carried a materially worse tail,
and it gives up atomicity with the row.

FileTable remains the right answer when the requirement is a Windows file share
that applications write to directly. It is not the right answer for a
high-concurrency ingest pipeline, which is what this profile models.

Still unmeasured: FileTable into an **empty** container -- the run that actually
sizes the gap -- FileTable with `-FileTableFlush` (forcing stable storage per
file, matching what a FILESTREAM commit does implicitly), and the read side.

---

## Run 6: Premium v2 4k

RunId `7839AF0C-31B0-41FD-B639-25E000E554D9`. Same VM, same 8 threads, 4 MB
chunk, `Mixed` profile, `SIMPLE` recovery, empty container, Procmon active.
Only the disk SKU changed, converted in place: deallocate, change SKU, start.

| | Premium v1 4k | **Premium v2 4k** | Change |
|---|---|---|---|
| Elapsed | 25m 20s | **19m 46s** | -22% |
| Throughput | 134.7 MB/s | **172.4 MB/s** | **+28%** |
| Files/sec | 106.4 | **136.7** | +28% |
| P95 per file | 64.8 ms | **41.7 ms** | -36% |
| Worst single file | 15,097 ms | 17,511 ms | **+16%** |
| Top wait | `FILESTREAM_WORKITEM_QUEUE` | `FILESTREAM_WORKITEM_QUEUE` | unchanged |
| Container at start | empty | empty | comparable |

### The entire gain came from small files

Thread-time per bucket, both runs, from `IngestTiming`:

| Bucket | v1 thread-sec | v2 thread-sec | Change |
|---|---|---|---|
| Tiny | 4,890 | **2,876** | **-41%** |
| Small | 1,267 | **759** | **-40%** |
| Medium | 2,961 | 2,673 | -10% |
| Large | 1,497 | **1,653** | **+10%** |
| Huge | 99 | 91 | -8% |
| **Total** | **10,714** | **8,053** | **-25%** |

Of the 2,661 thread-seconds saved, **2,522 -- 95% -- came from Tiny and Small
alone.** Medium contributed the rest. Large got *slower*: 61.6 MB/s per stream
down to 55.6.

That is the shape a per-operation improvement makes, not a bandwidth one. v2
helped precisely where v1 was weakest, and did nothing for the large sequential
writes that were already close to the device's streaming limit. Per-file mean
cost for a 33 KB file fell from 39.8 ms to 23.3 ms; for a 135 MB file it rose
from 2,192 ms to 2,449 ms.

This settles the question the earlier runs raised. On the old VM, an 18% faster
disk bought 8% more ingest, and the conclusion drawn was that the disk had
stopped being the constraint. It had stopped being a *bandwidth* constraint.
Provisioned IOPS was still on the table, and it was worth 28%.

### The ceiling is moving off the disk

Server-side wait time fell across the board, but not evenly:

| Wait | v1 | v2 | Change | v2 mean | Ops/file |
|---|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 8,069s | 6,334s | -22% | 6.7 ms | 5.81 |
| `PREEMPTIVE_OS_CREATEFILE` | 4,015s | 2,786s | **-31%** | 4.3 ms | **4.00** |
| `PREEMPTIVE_OS_FILEOPS` | 4,775s | 3,601s | -25% | 22.2 ms | 1.00 |
| `WRITELOG` | 488s | 428s | -12% | 2.6 ms | 1.01 |

`CreateFile` improved most, which is consistent: it is the NTFS metadata
operation, four per file, and metadata operations are IOPS-bound.

But `FILESTREAM_WORKITEM_QUEUE` **grew as a share of total wait time, from 40.5%
to 42.7%**, despite falling 22% in absolute terms. It is the FILESTREAM agent
serialising file operations, and it is not a disk wait. As the storage gets
faster it becomes a larger fraction of what remains. A third disk upgrade should
be expected to return less than this one did.

Exactly 4.00 `CreateFile` calls per file written, on both SKUs. That number is
structural, not incidental.

### Tail behaviour diverged

P95 improved 36% while the worst single file got 16% worse, and the largest
individual waits rose on every Win32 operation (`CreateFile` 13.2s to 16.9s,
`FILEOPS` 13.2s to 16.2s). Typical latency improved and the extreme tail did
not. Quote P95 for capacity planning; do not promise anything about the
maximum.

### Measurement note: the client under-reported by 6 files

The client recorded 162,124 files and 199.70 GB. The database holds **162,130
files and 200.00 GB** -- 6 more files, 0.30 GB more.

This is the commit-timeout ambiguity documented for run 1, at a smaller scale. A
commit that outruns its timeout leaves the client unable to tell whether the
server committed; it assumes failure, so it under-reports rather than
over-reports. Those 6 files were written and committed, and have no row in
`IngestTiming`, so the per-bucket tables above exclude them.

Computed on the database's own figure the throughput is 172.7 MB/s rather than
172.4. The difference is immaterial; the direction of the error is what matters,
and it is conservative.

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
5. **A batched-commit test.** The commit costs more than the write in every
   bucket on every disk. The ingest uses one transaction per file, so nobody has
   measured what batching would return.

---

## Reproducing

```powershell
# clean baseline - the container must be empty, or directory pressure
# costs roughly 2x per-file throughput
sqlcmd -S . -E -b -i sql\99-cleanup.sql -v DbName="FsPocDemo" Mode="drop"
.\ps\Setup-FilestreamPoc.ps1
.\ps\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 200
```

The drop takes about 30 seconds on a disk with enough IOPS. Allow 10 minutes on
one without.

Early progress looks stalled on every disk. The Tiny and Small buckets hold about
154,000 files that carry only 20 GB. The progress ETA extrapolates that rate
across the whole target. Throughput climbs sharply when the run reaches Medium.
That phase took about 17 minutes on the P40 and about 6 minutes on PremiumV2.
