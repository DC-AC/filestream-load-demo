# FILESTREAM POC - performance findings

Run date: 2026-09-10. Target VM: `SQL1` (Azure, eastus).

Six 200 GB ingest runs took place. Three gave valid results. Each valid run used
a different container disk configuration. This report compares them. It covers
ingest performance only.

Two results matter most. The disk stops being the bottleneck after the first
upgrade, so the second upgrade buys almost nothing for ingest. Container deletion
behaves in the opposite way, and it needs IOPS more than it needs bandwidth.

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
