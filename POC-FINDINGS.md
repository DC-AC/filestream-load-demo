# FILESTREAM POC: performance findings

Test setup: Azure SQL Server 2019 VMs, `Mixed` size profile, 8 threads, 4 MB
chunk, `SIMPLE` recovery, 200 GB per run. This report covers ingest only. We
did not measure the read path yet.

---

## Summary

| # | Configuration | Alloc | VM | Container | Files | Elapsed | MB/s | Files/s | P95 | Errors |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | P40 (Premium v1) | 64 KB | A | empty | 161,834 | 32m 38s | 104.4 | 82.7 | - | 2 commit timeouts |
| 2 | Premium v2 | 64 KB | A | empty | 162,051 | 12m 26s | **274.5** | 217.2 | - | 0 |
| 3 | Premium v2, more IOPS | 64 KB | A | empty | 162,143 | **11m 32s** | **296.0** | **234.4** | - | 0 |
| 4 | Premium v1 | 4 KB | B | empty | 161,675 | 25m 20s | 134.7 | 106.4 | 64.8 ms | 0 |
| 5 | **FileTable**, Premium v1 | 4 KB | B | **not empty** | 162,014 | 33m 58s | 100.5 | 79.5 | 228.0 ms | 0 client / **219 lock timeouts** |
| 6 | Premium v2 | 4 KB | B | empty | 162,124 | 19m 46s | 172.4 | 136.7 | **41.7 ms** | 0 |
| 7 | **FileTable**, Premium v2 | 4 KB | B | empty | 161,804 | 28m 26s | 120.0 | 94.8 | 228.9 ms | 0 client / **188 lock timeouts** |
| 8 | **Azure Blob** + SQL catalog | n/a | C | empty | 161,981 | **11m 02s** | **309.2** | **244.5** | **45.4 ms** | 0 |
| - | ~~Premium v1~~ | 64 KB | A | empty | - | 23m 28s | ~~144.9~~ | - | - | **INVALID** |

Runs 5 and 7 use FileTable. Run 8 uses Azure Blob Storage with a SQL Server
catalog. All other runs use `Filestream` (transacted `SqlFileStream`). Run 8
writes no bytes to a local disk, so cluster size does not apply to it.

- **VM A** is `Standard_E8ads_v5`, OS build 20348.5256.
- **VM B** is a rebuild of VM A. It has the same VM size, the same disks and
  the same SQL build.
- **VM C** is a third build. Only run 8 used it.

We traced runs 4 to 6 with Procmon. We do not know if we traced runs 1 to 3.
The kit stored `ProcmonActive` as 0 on every run until we fixed that bug.

The invalid row stays in the table on purpose. The machine went down 25 seconds
after that run reported completion. The data was still in the Windows file
cache, so the disk never absorbed it. See
[Do not quote the 144.9 MB/s figure](#do-not-quote-the-1449-mbs-figure).

### What the numbers say

**IOPS limits FILESTREAM ingest. Bandwidth does not.** From run 4 to run 6,
more provisioned IOPS gave 28% more throughput. **Files under 1 MB gave 95% of
the saved time.** Large files became 10% *slower*. Earlier, an 18% faster disk
gave only 8% more throughput. Bandwidth stopped mattering. The cost per
operation still mattered.

**Small files are the workload.** In run 4, files with an average size of
33 KB were 2% of the bytes and **46% of the elapsed time**. Per thread, that is
0.84 MB/s for those files and 77 MB/s for the large buckets. That is a 92x
difference in one run on one disk. The cost is per file and almost flat: a
33 KB file costs the same as a 533 KB file.

**The transaction log is never the constraint.** Every run wrote 1.4 GB of log
for 200 GB of data. `WRITELOG` was less than 3% of wait time, at a 2.6 ms mean.
A different or faster log disk will not help this workload.

**The ceiling is moving off the disk.** `FILESTREAM_WORKITEM_QUEUE` is the
FILESTREAM agent serialising file operations. It is not a disk wait. From run 4
to run 6, its absolute time fell 22%. But its share of all wait time **grew from
40.5% to 42.7%**. Expect a further disk upgrade to give less than this one did.

**Each file written causes four `CreateFile` calls.** The count is the same on
both SKUs. It is structural, and it is the second largest wait.

**Azure Blob was the fastest path we measured. The reason is concurrency, not
speed.** It gave 309.2 MB/s, against 296.0 MB/s for the best FILESTREAM run, on
a different VM. Per *stream*, Blob is the slower path above 8 MB. It stops at
about 60 MB/s per connection, and FILESTREAM reaches 336 MB/s. But Blob holds
that 60 MB/s at every size, so eight streams together move more than
FILESTREAM. Blob also does not touch the container disk. See
[run 8](#run-8-azure-blob-storage-with-a-sql-server-catalog).

**FileTable is 30% slower than FILESTREAM, and small files cause all of the
difference.** The test used the same hardware and an empty container. FileTable
doubled the cost of files under 1 MB. It was slightly *cheaper* for files above
16 MB. Its P95 was 5.5x worse. It also had 188 internal lock timeouts that the
client did not see. See
[run 7](#run-7-filetable-on-premium-v2-the-clean-measurement).

**Client-reported throughput can be higher than what the disk absorbs.** One run
reported 144.9 MB/s for writes that were still in the Windows file cache.
FILESTREAM writes do not go through the SQL Server buffer pool. They go through
that cache. Before you quote a client number, compare it with Perfmon.

### What is not settled

**A 37% gap. The per-bucket data points to bandwidth, not to cluster size.**
Premium v2 gave 274.5 MB/s at a 64 KB allocation unit (run 2). It gave
172.4 MB/s at 4 KB (run 6). Both runs used the same disk and the same VM size.
Cluster size was the first suspect. The per-bucket numbers do not support it.

Effective MB/s per stream, run 2 (64 KB) and run 6 (4 KB):

| Bucket | Run 2, 64 KB | Run 6, 4 KB | Change |
|---|---|---|---|
| Tiny (0.03 MB) | 1.7 | 1.4 | -18% |
| Small (0.53 MB) | 24.7 | 21.5 | -13% |
| Medium (8.5 MB) | 42.2 | 23.0 | -45% |
| Large (135 MB) | 145.7 | **55.6** | **-62%** |
| Huge (~1 GB) | 784.7 | **336.0** | **-57%** |

Median latency per file shows this more clearly:

| Bucket | Run 2, 64 KB | Run 6, 4 KB |
|---|---|---|
| Tiny | 18.0 ms | 21.0 ms |
| Small | 18.0 ms | **15.5 ms** (better) |
| Medium | 25.4 ms | 24.1 ms |
| Large | 716 ms | **2,289 ms** |
| Huge | 990 ms | **2,536 ms** |

**Small-file latency did not change. Large-file latency became three times
higher.**

Cluster size affects performance through metadata: allocation, `$Bitmap`
updates and MFT runlists. Relative to file size, that cost is largest on
*small* files. But small files are where these two runs agree. Small files are
even slightly *faster* at 4 KB. Large and Huge files are sequential writes that
bandwidth limits, and they lost 60%.

That pattern shows a **lower throughput ceiling on the disk**. It does not show
an effect of filesystem geometry. Large and Huge files are 60% of the bytes in
this profile. A 60% loss on those files alone gives the 37% overall gap.

This report describes run 3 as PremiumV2 "with more IOPS and bandwidth" than
run 2. So the provisioning on these disks already changed between runs.
**Before you reformat anything, compare the provisioned MB/s and IOPS of the
current disk with the values for run 2.** If the values are different, they
explain the gap, and the allocation unit is not the cause.

If the values are the same, cluster size is a suspect again. A 64 KB run on the
current VM then gives the answer. The comparison costs nothing, so do it first.

**Not tried:** the read path, `FULL` recovery, `-FileTableFlush`, and multiple
FILESTREAM containers on different disks.

---

## Per-stream throughput by file size

This table shows effective MB/s per stream, measured by the client for each
file. It includes every run and every bucket. It is the most useful view in
this report, and it explains every headline number above.

| Bucket | Avg size | 1<br>P40 64K | 2<br>v2 64K | 3<br>v2+ 64K | 4<br>v1 4K | 6<br>v2 4K | 7<br>FileT | 8<br>Blob |
|---|---|---|---|---|---|---|---|---|
| Tiny | 0.03 MB | 0.7 | 1.7 | 1.8 | 0.8 | 1.4 | 0.7 | **3.0** |
| Small | 0.53 MB | 10.1 | 24.7 | **25.8** | 12.9 | 21.5 | 9.9 | 23.6 |
| Medium | 8.5 MB | 18.9 | 42.2 | **50.6** | 20.7 | 23.0 | 22.0 | 55.5 |
| Large | 135 MB | 33.6 | 145.7 | **175.9** | 61.6 | 55.6 | 60.4 | 60.5 |
| Huge | ~1 GB | 51.1 | **784.7** | 543.8 | 311.1 | 336.0 | 385.6 | 62.5 |

The table shows four things. The sections below give the details.

- **File size has more effect than any other variable.** In each run, the
  spread from Tiny to Huge is 70x to 460x. No disk change, write path or
  configuration setting in this report changes a number by more than about 4x.
- **The small end almost does not respond to any change.** Tiny stays between
  0.7 and 3.0 MB/s across eight runs, four disk configurations and four write
  paths. More money on storage does not fix a small-file workload.
- **Azure Blob is flat. The other paths are not.** From Medium upward, Blob
  stays at 55-63 MB/s. That is a ceiling per connection. FILESTREAM climbs to
  336-785 MB/s. Blob still wins overall, because eight connections add together.
- **The Huge row is noisy.** Each run has only 28 to 36 files in that bucket.
  Runs 2 and 3 show this most clearly: 784.7 MB/s against 543.8 MB/s, although
  the run 3 disk is faster. Do not read that as a regression.

---

## Environment

VM A ran runs 1 to 3. VM B ran runs 4 to 7. VM B is a rebuild of VM A, with the
same size and the same disks. VM C ran run 8. It is a third build, and the blob
path on it never touches a local disk. Only comparisons inside one group are
controlled.

The tables below describe VM A.

| | |
|---|---|
| VM | `Standard_E8ads_v5`, 8 vCPU, 63.9 GB RAM |
| OS | Windows Server 2022 Datacenter, build **20348.5256** |
| SQL Server | 2019, 15.0.4470.1, FILESTREAM effective level 2 |
| `max server memory` | 56,000 MB for runs 1 to 3 |

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

On VM A, every volume uses NTFS with 64 KB allocation units. 8.3 name
generation is off on `H:`. Defender excludes `H:\FilestreamData` and
`sqlservr.exe`. We verified those exclusions. Defender does not affect any
number below.

**Runs 1 and 2 differ in two variables, not one.** The disk SKU changed, and
the host caching changed with it. PremiumV2 does not offer host caching, so you
cannot separate the two changes. `None` is the correct setting for a workload
with many writes. `ReadOnly` never helped writes. Read that step as "new disk
configuration", not as "SKU alone". Runs 2 and 3 use the same SKU, so that step
is clean.

### Measured disk capability

Before runs 2 and 3, a synthetic test wrote through the cache to `H:`:

| Test | Run 2 disk | Run 3 disk |
|---|---|---|
| Sequential, 4 streams, 4 MB blocks | 476.9 MB/s | **561.6 MB/s** |
| Random write IOPS, 8 threads, 8 KB | not measured | **9,342** |

Only the sequential test compares the two disks directly, because nobody
measured IOPS before run 3. An 8-stream version of the test gave 458.4 MB/s,
which is less than the 4-stream result. This is a limit of the test harness:
8 PowerShell job processes compete for 8 vCPUs. The runs had higher peaks than
either test: 585.3 MB/s and 613.4 MB/s.

PremiumV2 sets throughput and IOPS separately from disk size. Both defaults are
low. The throughput default is 125 MB/s. Someone provisioned this disk above
the default for run 2, then increased it again for run 3. A PremiumV2 disk at
the defaults is slower than the P40 it replaced.

---

## The disk progression: runs 1 to 3

This is the most controlled study in the report. It has three runs on one
machine, and only the container disk changed. Each run wrote exactly 200.00 GB
into a new, empty container. All three used 8 threads, a 4 MB chunk, the
`Mixed` profile, `SIMPLE` recovery and a 64 KB allocation unit.

| | Run 1: P40 | Run 2: PremiumV2 | Run 3: PremiumV2 boosted |
|---|---|---|---|
| RunId | `04EAFF19` | `7CDD0CC9` | `C4F97564` |
| Files | 161,834 | 162,051 | 162,143 |
| Elapsed | 32m 38s | 12m 26s | **11m 32s** |
| Throughput | 104.4 MB/s | 274.5 MB/s | **296.0 MB/s** |
| Files per second | 82.7 | 217.2 | **234.4** |
| Errors | 2 commit timeouts | 0 | **0** |
| Gain over previous | - | **2.63x** | **1.08x** |

The kit randomises file sizes per run, so the file counts are different. All
three runs wrote exactly the 200.00 GB target.

**The gains become much smaller after run 2.** The first upgrade gave 2.63
times the throughput. The second gave 1.08 times, although that disk is 18%
faster in a sequential test. At run 2, the disk stopped limiting ingest. See
[Where the bottleneck sits now](#where-the-bottleneck-sits-now).

Later, runs 4 and 6 repeated the step from v1 to v2 on a rebuilt machine with a
4 KB allocation unit. They got **+28%**, not +163%, at a much lower absolute
level: 134.7 to 172.4 MB/s, against 104.4 to 274.5 MB/s.
[The unresolved 37% gap](#what-is-not-settled) is about these two facts
together.

Results are in `C:\FsPocResults\run_20260910_152357_Filestream_Mixed`,
`run_20260910_184032_Filestream_Mixed` and `run_20260910_192014_Filestream_Mixed`.

> **Measurement note on run 1.** The client reported 199.54 GB in 161,832 files.
> The database holds 200.00 GB in 161,834 files. Two commits went past their
> timeout, and the client counted them as failures. Both transactions had
> committed.
>
> A commit timeout is ambiguous. It is not a failure. The client cannot tell if
> the server committed. The client assumes failure, so it reports too few bytes,
> never too many. `IngestTiming` has no row for those two files, so the
> per-bucket tables below do not include them. Runs 2 and 3 had no timeouts.

### Do not quote the 144.9 MB/s figure

An earlier run (RunId `FAF22B6E`) reported 199.21 GB in 1,408s. That is
144.9 MB/s. The number is invalid.

The machine went down 25 seconds after the run reported completion. It went
down while the cache was writing data back to disk. The data was still in the
Windows file cache, so the disk had not absorbed those writes. The run reported
throughput for writes that never reached the disk.

This trap applies to all FILESTREAM benchmarks. FILESTREAM writes go through the
Windows system file cache. They do not go through the SQL Server buffer pool.
Client throughput can be higher than disk throughput until the cache cannot
absorb more. In run 1, the client reported bursts of 425 MB/s, while Perfmon
showed `H:` at a constant 101 MB/s.

---

## Where the crossover is

The per-bucket table is [above](#per-stream-throughput-by-file-size). This
section explains what it means.

Median latency per file, for the three 64 KB runs:

| Bucket | Run 1: P40 | Run 2: PremiumV2 | Run 3: boosted |
|---|---|---|---|
| Tiny | 45.8 ms | 18.0 ms | **17.7 ms** |
| Small | 42.3 ms | 18.0 ms | **16.3 ms** |
| Medium | 242 ms | 25.4 ms | **46.3 ms** |
| Large | 3,187 ms | 716 ms | **559 ms** |
| Huge | 14,948 ms | 990 ms | **1,495 ms** |

Cost per file on run 3, by step:

| Bucket | Open ms | Write ms | Commit ms |
|---|---|---|---|
| Tiny | 4.64 | 6.44 | 7.77 |
| Small | 5.13 | 6.56 | 8.83 |
| Medium | 34.83 | 35.26 | 98.58 |
| Large | 145.77 | 192.02 | 441.87 |
| Huge | 529.91 | 556.68 | 931.02 |

Two findings were true on all three disks. Later, both were also true on a
different machine, a different disk generation and a different allocation unit.

**1. Below about 1 MB, the fixed overhead per file is most of the cost.** On the
P40, a Tiny file takes 49 ms from start to end, and the write is only 14 ms of
that. On run 3 it takes 19 ms, and the write is only 6.4 ms. The proportion
almost does not change across a 2.8x range of disk speed. Run 4 measured the
same cost as a flat 40 ms: a 33 KB file and a 533 KB file cost the same. Run 6
decreased it to 23 ms on faster storage, and the shape did not change. At this
size, the fixed cost per file *is* the cost.

**2. At every size, the commit costs more than the write.** The run 3 breakdown
shows this, and it was true on all three disks. It was still true in run 4,
where commit was **49.8% of all measured work**. Run 4 also showed what that
commit is not: `WRITELOG` was only 9% of it. FILESTREAM finalising files is the
rest.

Two later runs measured alternatives to that commit:

- **FileTable removes the transaction completely** and became *slower*.
  Namespace resolution for each file costs more than the commit it replaced
  ([run 7](#run-7-filetable-on-premium-v2-the-clean-measurement)).
- **Azure Blob replaces the commit with one catalog row insert.** That insert
  costs a flat 3-5 ms at every size, and it is 10% of the work in that run
  ([run 8](#run-8-azure-blob-storage-with-a-sql-server-catalog)).

Nobody has tested batching many files per transaction. It is the one untested
way to change the FILESTREAM path itself.

---

## Where the bottleneck sits now

An earlier version of this report said that effective throughput never
plateaus. It concluded that FILESTREAM overhead is the limit at every size
tested. **Run 2 showed that this is wrong.** On the P40, the disk limited the
large end, not the overhead.

Run 3 shows where the limit went.

| Step | Sequential disk speed | Ingest throughput | Ingest gain |
|---|---|---|---|
| Run 1, P40 | about 250 MB/s | 104.4 MB/s | - |
| Run 2, PremiumV2 | 476.9 MB/s | 274.5 MB/s | 2.63x |
| Run 3, boosted | 561.6 MB/s | 296.0 MB/s | 1.08x |

From run 1 to run 2, disk speed increased about 1.9 times, and ingest increased
2.63 times. From run 2 to run 3, disk speed increased 1.18 times, and ingest
increased 1.08 times. The second upgrade gave a smaller gain than the hardware
change that paid for it.

Perfmon confirms the cause. On run 3, the average write latency of the
container disk was 21.7 ms, and no sample went above 200 ms. The disk has spare
capacity. The ingest does not use it, because the ingest waits on work for each
file.

**The small end never gets a benefit.** Tiny went from 0.7 to 1.7 to
1.8 MB/s. The first upgrade helped it a little. The second did not help it. The
spread from Tiny to Huge is now about 300 times.

**Runs 4 to 6 found where the disk still mattered: IOPS, not bandwidth.** On the
rebuilt machine, the change from Premium v1 to v2 gave 28%. **Files under 1 MB
gave 95% of the saved time**, and Large files became 10% slower.
`PREEMPTIVE_OS_CREATEFILE` improved most, at -31%. That wait is NTFS metadata
work, four calls per file, and IOPS limits metadata work. So the conclusion
above needs one change. At run 2, the disk stopped being a *bandwidth*
constraint. It was still an IOPS constraint.

**Also, the ceiling has now moved off the disk.** `FILESTREAM_WORKITEM_QUEUE` is
the FILESTREAM agent serialising file operations. It is not a disk wait. From
run 4 to run 6, its absolute time fell 22%, but its share of all wait time
**grew from 40.5% to 42.7%**. As storage improves, this wait becomes a larger
part of what is left. Expect a further disk upgrade to give less than the last
one.

> If the workload is small files, faster storage does not fix it. The cost per
> file is the `PathName()` round trip plus the commit. Neither is a throughput
> problem. More money on storage helps the large end. It helps the small end
> very little. When the disk is faster than the workload needs, it stops
> helping anything.

**This table compares the three write paths we measured.** The earlier version
of this section could not do that.

| Path | Throughput | Against FILESTREAM on the same machine |
|---|---|---|
| FILESTREAM (run 6) | 172.4 MB/s | baseline |
| FileTable (run 7) | 120.0 MB/s | **-30%**, all of it small files |
| Azure Blob (run 8) | 309.2 MB/s | **+79%**, on a different VM |

In-table `varbinary(max)` is the one comparison that nobody has run. For files
under 1 MB, most applications face that comparison. See
[Not yet done](#not-yet-done).

---

## Where the server-side time went

These numbers come from `sys.dm_os_wait_stats` deltas over each run. Values are
total wait time in seconds:

| Wait | 1 | 2 | 3 | 4 | 6 | 7 FileT | 8 Blob |
|---|---|---|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 10,063 | 4,110 | 3,733 | 8,069 | 6,334 | - | - |
| `PREEMPTIVE_OS_FILEOPS` | 5,445 | 2,253 | 1,911 | 4,775 | 3,601 | 1,887 | - |
| `PREEMPTIVE_OS_CREATEFILE` | 3,785 | 1,753 | 1,580 | 4,015 | 2,786 | 1,755 | - |
| `PREEMPTIVE_OS_DELETEFILE` | 625 | 464 | 415 | 762 | 483 | 72 | - |
| `FFT_NSO_FCB_FIND` | - | - | - | - | - | **1,532** | - |
| `FFT_NSO_FCB_PARENT` | - | - | - | - | - | **1,414** | - |
| `WRITELOG` | 328 | 197 | 291 | 488 | 428 | 1,188 | **448** |

On runs 1 to 3, the `PREEMPTIVE_OS_*` family is about 43% of wait time. It stays
dominant through runs 4 and 6. Standard "top waits" scripts remove that family
as idle noise. That is why FILESTREAM investigations often find nothing.

Earlier versions of this table did not show `FILESTREAM_WORKITEM_QUEUE`, for a
different reason. The analysis put it in "Other". The pattern `FS[_]%` needs a
literal underscore after `FS`, so no wait name that starts with `FILESTREAM`
matched it. It is the largest wait on every FILESTREAM run.

**The container has many more file operations than the file count suggests.**
This is a property of FILESTREAM, not of the storage. It is true on every disk
configuration and on both allocation units:

| Run | Files | `CREATEFILE` waits | Per file |
|---|---|---|---|
| 1 | 161,832 | 647,336 | 4.00 |
| 2 | 162,051 | 648,204 | 4.00 |
| 3 | 162,143 | 648,572 | 4.00 |
| 4 | 161,675 | 646,700 | 4.00 |
| 6 | 162,124 | 648,520 | 4.00 |
| 7 (FileTable) | 161,804 | 485,526 | 3.00 |

The count is exactly four on five runs, three disk generations and two
allocation units. FileTable uses exactly three. Nobody has explained either
number. The Procmon traces that can explain them exist, but nobody has analysed
them.

**The two paths that do not use FILESTREAM look very different.** In run 7,
FileTable's own namespace resolution waits (`FFT_NSO_FCB_*`) replace the
FILESTREAM waits, at 30.7% of wait time. Run 8 has almost no waits. `WRITELOG`
is **99.35%** of the total, and no other wait reaches 0.3%. In that run, SQL
Server only logs 161,981 catalog rows.

---

## Container disk behaviour (runs 1 to 3)

These are Perfmon numbers for `H:` only. Later runs also collected Perfmon data,
but nobody has extracted these figures from it. So this section covers only the
three-disk study.

| Metric | Run 1: P40 | Run 2: PremiumV2 | Run 3: boosted |
|---|---|---|---|
| Write latency, average | 170.7 ms | 26.8 ms | **21.7 ms** |
| Write latency, maximum | 876.3 ms | 120.1 ms | **119.0 ms** |
| Samples over 200 ms | 128 of 393 | 0 of 152 | **0 of 140** |
| Queue depth, maximum | 29 | 20 | 24 |
| Throughput, average | 95.2 MB/s | 277.4 MB/s | **301.7 MB/s** |
| Throughput, maximum | 275.3 MB/s | 585.3 MB/s | **613.4 MB/s** |

On the P40, the container disk was the bottleneck. One third of all samples
were above 200 ms, and throughput stayed at the SKU limit. From run 2 onward,
no sample goes above 200 ms.

The two commit timeouts in run 1 agree with this. On the P40, the average commit
latency for Huge files was 1,666 ms. The slowest single file took 80.8 seconds
from start to end. Runs 2 and 3 had no timeouts.

---

## Container deletion needs IOPS, not bandwidth

An earlier version of this report listed this as an open question. Run 3 gives
the answer.

Time to drop the previous 200 GB container:

| Disk | Drop time | Deletions per second |
|---|---|---|
| Run 1, P40 | 85s | 1,903 |
| Run 2, PremiumV2 | 555s | 292 |
| Run 3, PremiumV2 boosted | **29s** | **5,591** |

The run 2 disk had enough bandwidth but not enough IOPS. Bulk container removal
is almost all metadata work, so it was 6.5 times slower than on the P40. More
IOPS fixed it. Run 3 deletes about 19 times faster than run 2, and about 3 times
faster than the P40.

The earlier suggested cause was the loss of `ReadOnly` host caching for
directory metadata reads. That cause is wrong. Host caching is `None` on both
run 2 and run 3, and the drop time still fell 19 times.

**This is the clearest IOPS-limited result in the POC.** The same hardware
change gave ingest throughput 8% more and container deletion 1,800% more. The
two workloads need different things from the same disk.

Later, a teardown on VM B measured a worse case. Nobody reset the database
between two runs, so the container held **323,689 files in 400 GB**. The drop
ran past a **900 second timeout**, and nothing blocked it. `DROP DATABASE`
deletes the container synchronously inside the statement. So all of the cost is
in one call that you cannot interrupt, and that call reports no progress.

The fix is a procedure change, not a hardware change:

1. Take the database **offline**. This makes the `DROP` a metadata operation.
2. Drop the database.
3. Remove the directory from the file system. `rd /s /q` is much faster there,
   and you can see its progress.

`Reset-FilestreamPoc.ps1` now does these steps.

---

## Configuration findings

**`max server memory` had no limit before these runs.** On a 64 GB VM, the
buffer pool can take all memory, and the Windows system file cache then gets too
little. This matters more for FILESTREAM than for a normal workload. FILESTREAM
I/O never uses the buffer pool, because the blobs never go through it. No SQL
counter shows this problem. For runs 1 to 3, the value is 56,000 MB.

**The container disk was the weakest disk on the machine. It is not now.** It
was a P40 `Premium_LRS` at about 250 MB/s, and `F:` and `G:` were
`PremiumV2_LRS`. Now all three are `PremiumV2_LRS`, with caching set to `None`.

**A large PremiumV2 disk does not automatically get high throughput or IOPS.**
You set throughput and IOPS separately, and both defaults are low. A 2048 GB
PremiumV2 disk at the default 125 MB/s is slower than the P40 it replaces.
Before you treat a PremiumV2 disk as an upgrade, check its provisioned values.

**Provision IOPS for the maintenance work, not for the ingest.** Above about
475 MB/s of disk speed, the disk no longer limits the ingest. Container
deletion still gets faster above that point. When IOPS is too low, deletion is
the longest step in a clean-run cycle.

**Allocation unit is the largest variable that is not resolved.** Runs 1 to 3
used 64 KB. Runs 4 to 7 used 4 KB. On the same disk and the same VM size,
Premium v2 gave 274.5 MB/s at 64 KB and 172.4 MB/s at 4 KB. The per-bucket data
points to provisioned bandwidth, not cluster size, but nobody has proven either
cause. See [What is not settled](#what-is-not-settled).

**A managed identity needs a data-plane role, and the portal does not tell
you.** For the Azure Blob path, the VM identity needs
`Storage Blob Data Contributor`. `Owner` and `Contributor` are control-plane
roles. They give no blob access. The result is a 403 on every upload, although
the identity looks fully privileged. The kit preflight now sends one container
list request before a run starts. So this problem fails in one second, not
161,000 times.

**These are not factors in these numbers:**

- Defender (excluded).
- 8.3 name generation (off on `H:`).
- Volume roles (verified against the instance default paths).
- ReFS (all volumes use NTFS).

---

## Run 4: Premium v1 4k

RunId `60E942B1-FB12-49DA-B7C0-782F851EA8E9`, 2026-09-11.
Results in `C:\FsPocResults\run_20260911_225442_Filestream_Mixed`.

| | |
|---|---|
| Configuration | **Premium v1 4k** |
| Files | 161,675 |
| Elapsed | 25m 20s |
| Throughput | **134.7 MB/s** |
| Files per second | 106.4 |
| Errors | **0** |
| Procmon | active, 120s window, 851.73 MB trace (unconverted) |

Run 4 used the same 8 threads, 4 MB chunk, `Mixed` profile and `SIMPLE`
recovery as runs 1-3.

> **This run used a rebuilt VM.** Run 4 ran on VM B, and runs 1-3 ran on VM A.
> VM B has the same VM size and the same disks. But it uses a 4 KB allocation
> unit, not 64 KB. So a comparison of 134.7 MB/s with the 104.4 MB/s P40 figure
> changes two variables: the machine and the allocation unit. Use it as a rough
> guide, not as a controlled result. The kit does not record VM size or
> allocation unit.

### Small files use most of the run

Thread time per bucket, from `IngestTiming` (files x mean open+write+commit):

| Bucket | Files | Mean/file | Thread-sec | % of time | GB | % of bytes |
|---|---|---|---|---|---|---|
| Tiny | 122,939 | 39.8 ms | 4,890 | **45.6%** | 4 | 2.0% |
| Small | 30,754 | 41.2 ms | 1,267 | 11.8% | 16 | 8.0% |
| Medium | 7,263 | 407.6 ms | 2,961 | 27.6% | 60 | 30.0% |
| Large | 683 | 2,192 ms | 1,497 | 14.0% | 90 | 45.0% |
| Huge | 36 | 2,743 ms | 99 | 0.9% | 30 | 15.0% |

**Tiny files are 2% of the bytes and 46% of the elapsed time.** All files under
1 MB are 10% of the bytes and 57% of the time. Large and Huge files are 60% of
the bytes and 15% of the time.

Per thread, Tiny files move 0.84 MB/s, and Large and Huge files move
77.1 MB/s. That is a **92x** difference in bytes per unit of time, on the same
hardware in one run. The cost is per file, not per byte, and it is about 40 ms
flat. A 33 KB file and a 533 KB file both cost 40 ms.

The total above is 10,714 thread-seconds. Divided by 8 threads, that is 1,339s,
against 1,520s elapsed. So measured per-file work explains 88% of wall time.
Scheduling and queueing are the rest.

### Commit is half the cost, and the log does not cause it

In every bucket, commit is the largest part of the time per file. Its share
increases with size: Tiny 46%, Small 49%, Medium 52%, Large 56%, Huge 62%. For
all files together, commit is **5,332 thread-seconds, or 49.8% of all measured
work**.

Log flush does not cause that time. `WRITELOG` totals 488s for the whole run, at
a mean of 2.93 ms. That is 9% of commit time. The log wrote 1,374.8 MB for a
200 GB load, at an average of 1.79 ms per write. **The transaction log is not a
bottleneck here, and a different log location will not help.**

The top waits show what the commit pays for:

| Wait | Time | Waits | Per file | Mean |
|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 8,069s | 864,491 | 5.35 | 9.33 ms |
| `PREEMPTIVE_OS_FILEOPS` | 4,775s | 161,896 | 1.00 | 29.5 ms |
| `PREEMPTIVE_OS_CREATEFILE` | 4,015s | 646,700 | **4.00** | 6.21 ms |
| `PREEMPTIVE_OS_DELETEFILE` | 762s | 472,092 | **2.92** | 1.61 ms |
| `PREEMPTIVE_OS_FINDFILE` | 42s | 633,237 | 3.92 | 0.07 ms |
| `WRITELOG` | 488s | 166,710 | 1.03 | 2.93 ms |

`FILESTREAM_WORKITEM_QUEUE` is 40.5% of all wait time. Earlier reports did not
show it. The analysis put it in "Other", because the pattern `FS[_]%` needs a
literal underscore after `FS`. This is now fixed.

Two counts need more investigation:

- **4.00 `CreateFile` calls per file written.** The count is exactly four, not
  about four. The container pays this NTFS metadata work for each file, and it
  is the second largest wait.
- **2.92 `DeleteFile` calls per file.** The run made 472,092 deletions, and the
  load only wrote files. Garbage collection ran during the whole run. It
  collected intermediate files from this run, or tombstones from a previous
  container. The meaning of the number depends on which, and the Procmon trace
  can tell them apart.

The 851 MB trace on disk can answer both questions:

```powershell
.\ps\Invoke-PocAnalysis.ps1 -ConvertProcmon
```

### The measurement path is sound

`sys.dm_io_virtual_file_stats` recorded 1,374.8 MB written to the log and
174.4 MB written to the MDF, for a 200 GB load. That is **0.77% of the data**.
The other 99.2% went through Win32 streaming, and no SQL Server I/O DMV can see
it. This is how the design works. It is also why the client-side timings, not
the DMVs, give the result.

### Latency tail

For the larger buckets, P99 is far from the mean. Large has a P99 of 12.3s and
a median of 1.68s. Medium has a P99 of 4.2s and a maximum of 15.1s.
`PREEMPTIVE_OS_FILEOPS` and `PREEMPTIVE_OS_CREATEFILE` both have peaks at about
13.2s. So stalled Win32 file operations cause the tail, not data transfer. Set
application timeouts from P99, not from the mean.

### A slow minority of calls causes most of the cost

The event session captures only waits of 10 ms or more. So the difference
between the event session and the DMV totals is useful. It shows how much of the
cost of each wait is in its slow tail.

| Wait | DMV total | Waits | XE (>=10ms) | Share of waits | Share of time |
|---|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 8,069s | 864,491 | 7,195s | 17% | **89%** |
| `PREEMPTIVE_OS_CREATEFILE` | 4,015s | 646,700 | 1,907s | 6% | **48%** |
| `PREEMPTIVE_OS_FILEOPS` | 4,775s | 161,896 | 4,380s | 80% | 92% |

`FILESTREAM_WORKITEM_QUEUE` and `CreateFile` behave the same way: a small number
of calls causes most of the cost. Six percent of `CreateFile` waits are half of
its total time. That pattern is queueing, not a uniform price per call. So the
average is the wrong number to design against. The mean `CreateFile` wait is
6.2 ms, but the slow waits have an average of 46.7 ms and a peak of 12.1
seconds.

`PREEMPTIVE_OS_FILEOPS` is different. 80% of its waits are already over 10 ms.
It is expensive on all files, at about 30 ms per file.

`WRITELOG` waits over 10 ms total 160s for the run, with a 194 ms maximum.
`WRITELOG` is not a factor at any percentile.

> **Reading the raw shred output.** Before this run, the shred did not filter
> benign waits. So its first line was `SOS_WORK_DISPATCHER` at 57,201 seconds,
> in a 1,520 second run. Those are idle workers that wait for work. Three more
> idle timers came next. This is now fixed. The shred uses the same
> `dbo.BenignWait` list as the DMV analysis. It also prints the waits it
> excludes, so it does not remove them silently.

### No bugcheck

On the previous VM, two runs crashed the machine with `0x18 REFERENCE_BY_POINTER`
in `Ntfs!NtfsIoPerfPostFileObjectInfo`. Each crash happened on a flush
completion with high latency. This run completed with Procmon active and zero
errors. This agrees with the idea that only high flush latency triggers the
defect. But one clean run does not prove that the defect is gone.

---

## Run 5: FileTable, same disk, same profile

RunId `B9F71085-2BC4-4794-B8CC-CE55B74D0889`. Run 5 ran immediately after run 4,
on the same VM and the same disk. It used the same 8 threads, 4 MB chunk and
`Mixed` profile.

| | Run 4: Filestream | Run 5: FileTable |
|---|---|---|
| Files | 161,675 | 162,014 |
| Elapsed | **25m 20s** | 33m 58s |
| Throughput | **134.7 MB/s** | 100.5 MB/s |
| P95 per file | **64.8 ms** | 228.0 ms |
| Top wait | `FILESTREAM_WORKITEM_QUEUE` | `PREEMPTIVE_OS_FILEOPS` |
| Client-visible errors | 0 | 0 |

**FileTable was 34% slower, and its P95 was 3.5x worse.**

> ### Correction: this run is confounded
>
> Run 5 did **not** write into an empty container. The reset before run 6 found
> 323,689 files in the container. That is exactly 161,675 + 162,014, so the
> output of run 4 stayed in the container for all of run 5. Runs 4 and 6 both
> started empty. Run 5 did not.
>
> This report already shows that a populated container makes per-file
> throughput about 2x worse than an empty one. So the 34% deficit of run 5 mixes
> two causes: the cost of FileTable itself, and directory pressure that run 4
> never had. This data cannot separate the two.
>
> **Use 34% as an upper limit for the FileTable penalty. It is not a
> measurement of the penalty.** The lock timeouts below are not affected. They
> are contention in the row-materialisation path, and the fill level of the
> container has no effect on them. The other finding is also not affected:
> skipping the transaction moves work, and does not remove it. Only the size of
> the gap is not safe to quote.
>
> **Run 7 gave the answer, and the number almost did not change.** A clean
> FileTable run on Premium v2, into an empty container, was 30% slower than
> FILESTREAM. Run 5 was 34% slower. Directory pressure did not cause the result.
> It was correct to raise the caveat, but the caveat did not change the
> conclusion.
>
> The preflight now refuses to start a run on a container that is not empty. We
> added this guard after this run, not before it.

If you ignore the confound, the direction of the result is still the opposite
of what we expected when we added this path. FileTable does no transaction and
no commit flush, so it should be the cheaper path. The kit documentation said
to expect FileTable to win. It also said to read the gap as the price of
transactional consistency. On this hardware, the gap goes in the other
direction, and transactional consistency cost nothing.

Do not generalise this to "FileTable is slow". It is one configuration on one
disk. It does show that the path that looks cheaper is not always faster. You
must measure this question. You cannot answer it by reasoning.

### Why: the work moves, it does not disappear

Skipping the transaction does not remove the work. It moves the work to a
different place. This table compares what SQL Server saw in each run:

| | Filestream | FileTable |
|---|---|---|
| `sql_transaction` events | 648,132 | **1,778** |
| MDF/LDF written | 64.8 MB | **131.0 MB** |
| `WRITELOG` waits >=10ms | 12,150 | **5** |

During the FileTable run, SQL Server is almost idle. It has 365x fewer
transaction events and almost no log pressure. But the run finished slower. The
cost moved to two places that the transactional path does not pay for:

1. **The SMB loopback.** The client writes to
   `\\SQL1\MSSQLSERVER\FsPocDemo\FileStoreFT\...` and not through a streaming
   handle. On the same machine, that path still goes through the SMB redirector
   and the server stack.
2. **Row materialisation.** Each file becomes a row with a `hierarchyid`
   `path_locator`, a name and attributes. The filter driver builds that row
   outside any transaction that the client controls. That is why FileTable
   wrote *twice* as much to the MDF and LDF, with 365x fewer transactions.

### Lock timeouts that the client cannot see

The event session captured **219 `error_reported` events. Every one was
Msg 1222, "Lock request time out period exceeded"**. They came from at least 15
different session ids, over the whole run.

The client reported zero errors and wrote all 200.00 GB. So these are internal
retries, not lost work. They are still a finding. No client-side timing or DMV
wait delta shows them. They are the clearest signal that the FileTable
row-materialisation path contends with itself under concurrent load. The 3.5x
P95 penalty and these timeouts very probably have the same cause.

This is the strongest reason in the report to capture `error_reported` in the
event session. A run that looks clean from the client is not always clean.

### What this changes

For an ingest with many writes at this concurrency, FILESTREAM with
`SqlFileStream` was both **faster and transactional**. This run cannot give the
size of the difference, for the reason above. The direction is certain. The
non-transacted path did not win, although it had no commit to pay for. It had a
much worse tail. It also loses atomicity with the row.

FileTable is still the correct choice when applications must write directly to
a Windows file share. It is not the correct choice for a high-concurrency
ingest pipeline, which is what this profile models.

At the time of this run, these tests were not done:

- FileTable into an **empty** container. This is the run that gives the size of
  the gap. Run 7 later did this test.
- FileTable with `-FileTableFlush`. This forces stable storage for each file,
  the same as a FILESTREAM commit does implicitly.
- The read side.

---

## Run 6: Premium v2 4k

RunId `7839AF0C-31B0-41FD-B639-25E000E554D9`. Run 6 used the same VM, 8 threads,
4 MB chunk, `Mixed` profile and `SIMPLE` recovery. The container was empty, and
Procmon was active. Only the disk SKU changed. We converted the disk in place:
deallocate, change the SKU, start.

| | Premium v1 4k | **Premium v2 4k** | Change |
|---|---|---|---|
| Elapsed | 25m 20s | **19m 46s** | -22% |
| Throughput | 134.7 MB/s | **172.4 MB/s** | **+28%** |
| Files/sec | 106.4 | **136.7** | +28% |
| P95 per file | 64.8 ms | **41.7 ms** | -36% |
| Worst single file | 15,097 ms | 17,511 ms | **+16%** |
| Top wait | `FILESTREAM_WORKITEM_QUEUE` | `FILESTREAM_WORKITEM_QUEUE` | unchanged |
| Container at start | empty | empty | comparable |

### The small files gave all of the gain

Thread time per bucket, both runs, from `IngestTiming`:

| Bucket | v1 thread-sec | v2 thread-sec | Change |
|---|---|---|---|
| Tiny | 4,890 | **2,876** | **-41%** |
| Small | 1,267 | **759** | **-40%** |
| Medium | 2,961 | 2,673 | -10% |
| Large | 1,497 | **1,653** | **+10%** |
| Huge | 99 | 91 | -8% |
| **Total** | **10,714** | **8,053** | **-25%** |

Run 6 saved 2,661 thread-seconds. **Tiny and Small files alone gave 2,522 of
them, or 95%.** Medium files gave the rest. Large files became *slower*: the
rate per stream fell from 61.6 MB/s to 55.6.

That is the pattern of an improvement per operation, not an improvement in
bandwidth. v2 helped where v1 was weakest. It did not help the large sequential
writes, which were already near the streaming limit of the device. The mean cost
for a 33 KB file fell from 39.8 ms to 23.3 ms. For a 135 MB file, it increased
from 2,192 ms to 2,449 ms.

This answers the question from the earlier runs. On the old VM, an 18% faster
disk gave 8% more ingest. From that, we concluded that the disk was no longer
the constraint. In fact, it was no longer a *bandwidth* constraint. Provisioned
IOPS could still help, and it gave 28%.

### The ceiling is moving off the disk

Server-side wait time fell for all waits, but by different amounts:

| Wait | v1 | v2 | Change | v2 mean | Ops/file |
|---|---|---|---|---|---|
| `FILESTREAM_WORKITEM_QUEUE` | 8,069s | 6,334s | -22% | 6.7 ms | 5.81 |
| `PREEMPTIVE_OS_CREATEFILE` | 4,015s | 2,786s | **-31%** | 4.3 ms | **4.00** |
| `PREEMPTIVE_OS_FILEOPS` | 4,775s | 3,601s | -25% | 22.2 ms | 1.00 |
| `WRITELOG` | 488s | 428s | -12% | 2.6 ms | 1.01 |

`CreateFile` improved most. This is expected: it is the NTFS metadata operation,
four per file, and IOPS limits metadata operations.

But the share of total wait time for `FILESTREAM_WORKITEM_QUEUE` **grew from
40.5% to 42.7%**, although its absolute time fell 22%. This wait is the
FILESTREAM agent serialising file operations. It is not a disk wait. As storage
becomes faster, it becomes a larger part of what is left. Expect a third disk
upgrade to give less than this one.

Both SKUs had exactly 4.00 `CreateFile` calls per file written. That number is
structural, not accidental.

### The tail went in a different direction

P95 improved 36%, but the slowest single file became 16% slower. The largest
individual waits increased on every Win32 operation: `CreateFile` from 13.2s to
16.9s, and `FILEOPS` from 13.2s to 16.2s. Typical latency improved, and the
extreme tail did not. Use P95 for capacity planning. Do not promise a maximum
latency.

### Measurement note: the client reported 6 files too few

The client recorded 162,124 files and 199.70 GB. The database holds **162,130
files and 200.00 GB**. That is 6 more files and 0.30 GB more.

This is the same commit-timeout ambiguity as in run 1, at a smaller scale. When
a commit goes past its timeout, the client cannot tell if the server committed.
The client assumes failure, so it reports too little, never too much. Those 6
files were written and committed. They have no row in `IngestTiming`, so the
per-bucket tables above do not include them.

Calculated from the database figure, the throughput is 172.7 MB/s, not 172.4.
The difference is not important. The direction of the error is what matters,
and the error is conservative.

---

## Run 7: FileTable on Premium v2, the clean measurement

RunId `23DBDA08-EC8E-4666-B32A-D8D0AF010E70`. Run 7 used the same VM, the same
Premium v2 disk and the same 4 KB allocation unit. It used the same 8 threads,
4 MB chunk and `Mixed` profile. The container was **empty**, and Procmon was
active. The only difference from run 6 is the write path.

| | Run 6: Filestream | Run 7: FileTable |
|---|---|---|
| Elapsed | **19m 46s** | 28m 26s |
| Throughput | **172.4 MB/s** | 120.0 MB/s |
| Files/sec | **136.7** | 94.8 |
| P95 per file | **41.7 ms** | 228.9 ms |
| Mean commit | 181-1,731 ms | **0.00 ms** |
| Top wait | `FILESTREAM_WORKITEM_QUEUE` | `PREEMPTIVE_OS_FILEOPS` |
| Client errors | 0 | 0 |
| Internal lock timeouts | 0 | **188** |

**FileTable is 30% slower, and its P95 is 5.5x worse.** Its commit cost is
exactly zero. `AvgCommitMs` is 0.00 in every bucket, which is correct, because
there is no transaction.

Run 5 gave 34%, but into a populated container. The clean result is 30%, so
directory pressure did not cause the run 5 result.

### Small files cause all of the penalty

Thread time per bucket, run 6 and run 7:

| Bucket | Filestream | FileTable | Change |
|---|---|---|---|
| Tiny | 2,876s | **6,018s** | **+109%** |
| Small | 759s | **1,585s** | **+109%** |
| Medium | 2,673s | 2,783s | +4% |
| Large | 1,653s | **1,523s** | **-8%** |
| Huge | 91s | **76s** | **-17%** |
| **Total** | **8,053s** | **11,985s** | **+49%** |

FileTable **doubles** the cost of each file under 1 MB. It is **cheaper** for
files over 16 MB. Effective throughput per stream changed as follows: Tiny 1.4
to 0.7 MB/s, Small 21.5 to 9.9, Medium 23.0 to 22.0, Large 55.6 to 60.4, Huge
336 to 386.

The crossover is in the 1-16 MB band. Above it, the non-transacted path wins,
as we first expected. Below it, the non-transacted path loses by a factor of
two.

### Why: namespace resolution for each file

Two waits appear that FILESTREAM runs never show. Together, they are 30.7% of
all wait time:

| Wait | Time | Events | Per file |
|---|---|---|---|
| `FFT_NSO_FCB_FIND` | 1,532s | 337,273 | 2.08 |
| `FFT_NSO_FCB_PARENT` | 1,414s | 314,518 | 1.94 |

`FFT` is FileTable. These waits are lookups of the namespace and of file control
blocks in the FileTable hierarchy. There are about two of each per file. They
find the location of each new file in the `hierarchyid` tree. The cost is per
*file*, not per byte. That is why all of it falls on the small buckets.

There are two more structural differences:

- **`PREEMPTIVE_OS_FILEOPS`: 9.16 per file for FileTable, 1.00 for
  FILESTREAM.** That is nine times as many Win32 operations. But each one is
  17x cheaper (1.27 ms against 22.20 ms), so the total time is about half.
- **`WRITELOG`: 2.03 per file against 1.01, and 1,188s against 428s.** The
  non-transacted path makes *more* log work than the transacted path. Each file
  still becomes a logged row insert with a `hierarchyid`. Skipping the
  transaction does not skip the logging.

`CXPACKET` and `CXROWSET_SYNC` also each have more than a million waits. Some of
the FileTable namespace maintenance runs in parallel. The FILESTREAM path has no
parallel work.

### The lock timeouts are inherent, not accidental

Run 7 had 188 Msg 1222 lock timeouts. Run 5 had 219, on a different disk and a
different container state. The rate is consistent across two runs, and the
client did not see the timeouts either time. Both runs wrote 200.00 GB with zero
client-side errors. This is contention in the FileTable row-materialisation
path with concurrent writers, and it occurs again on each run.

### What to recommend

For a high-concurrency ingest of mostly small files, **FILESTREAM with
`SqlFileStream` is better in both ways**. It gives 30% more throughput and
transactional consistency. You do not trade one for the other.

FileTable is a good choice when files are large, when concurrency is low, or
when applications must write directly to a Windows share. Above about 16 MB per
file, it is measurably faster.

---

## Run 8: Azure Blob Storage with a SQL Server catalog

RunId `BC1905AC-900C-4FC7-9C55-2059550F0720`, on a third VM. The client uploads
each file to `stblobtesteus` through the Storage REST API, with the managed
identity of the VM. Then the client inserts a row in `dbo.BlobUrlStore` with
the URL, size and ETag. The run used the same `Mixed` profile, 8 threads and
4 MB chunk. Procmon was not active.

| | Run 6: Filestream | Run 7: FileTable | Run 8: Azure Blob |
|---|---|---|---|
| Elapsed | 19m 46s | 28m 26s | **11m 02s** |
| Throughput | 172.4 MB/s | 120.0 MB/s | **309.2 MB/s** |
| Files/sec | 136.7 | 94.8 | **244.5** |
| P95 per file | 41.7 ms | 228.9 ms | 45.4 ms |
| Bytes on the container disk | 200 GB | 200 GB | **0** |
| In the database backup | yes | yes | **no** |

> **Different machine.** Run 8 ran on VM C. Runs 6 and 7 ran on VM B. The blob
> path never touches the container disk, so the disk configuration does not
> affect it. But CPU and network do affect it, and we did not keep those
> constant. Use the comparison as a rough guide.

### It stays flat per stream and wins through concurrency

Effective MB/s per stream:

| Bucket | Filestream v2 | FileTable | **Azure Blob** |
|---|---|---|---|
| Tiny (0.03 MB) | 1.4 | 0.7 | **3.0** |
| Small (0.53 MB) | 21.5 | 9.9 | **23.6** |
| Medium (8.5 MB) | 23.0 | 22.0 | **55.5** |
| Large (135 MB) | 55.6 | 60.4 | 60.5 |
| Huge (~1 GB) | **336.0** | 385.6 | 62.5 |

Blob stays at 55-63 MB/s across Medium, Large and Huge. It is **flat**. That is
a ceiling per connection. One HTTPS stream to one storage account moves about
60 MB/s, at any object size. FILESTREAM has no such ceiling. It reaches
336 MB/s per stream on a 1 GB file, because it writes to a local disk.

Blob still wins overall, because the ceiling is *per connection*, and eight
connections add together. The FILESTREAM advantage on large files is not
enough to cancel its cost on small files.

Thread time per bucket shows the trade clearly:

| Bucket | Azure Blob | Filestream v2 | Change |
|---|---|---|---|
| Tiny | **1,332s** | 2,876s | **-54%** |
| Small | 690s | 759s | -9% |
| Medium | **1,106s** | 2,673s | **-59%** |
| Large | 1,524s | 1,653s | -8% |
| Huge | **491s** | 91s | **+438%** |
| **Total** | **5,143s** | 8,053s | **-36%** |

Blob cuts the cost of Tiny and Medium files by more than half. On Huge files it
is **5.4x worse**. A 1 GB upload took 16.4 seconds on average, with a peak of
33.6 seconds. P99 for that bucket is 32.9 seconds, against 4.98 seconds for
FILESTREAM. If objects of several hundred megabytes are most of the workload,
this order is reversed.

Measured per-file work explains 97% of wall-clock time: 5,143 thread-seconds
over 8 threads is 643s, against 663s elapsed. That is the closest match of any
run here.

### SQL Server only writes the log

`WRITELOG` is **99.35% of all wait time**: 448 seconds over 163,335 waits, at a
2.74 ms mean. No other wait reaches 0.3%. All FILESTREAM and FileTable wait
types are absent, because the run does not use those features.

That log work is the catalog insert and nothing else. Measured at the client,
the insert costs 3.1-4.9 ms per file at every size. The total is 527
thread-seconds, or 10% of the work in the run. That is the price of a record of
what was stored. The log wrote 591.7 MB for a 200 GB load.

This is important for capacity planning: **this path puts almost no load on the
database server.** It uses one stream of log writes and 63.5 MB to the MDF. The
same SQL Server could catalogue several ingests like this at the same time.

### Costs that the throughput number does not show

- **No atomicity.** The upload and the row insert happen in two different
  systems. The kit uploads first. So a failure leaves an orphan blob, not a row
  that points to nothing. That is the safer failure, but it still needs a
  reconciliation job.
- **Not in the database backup.** `BACKUP DATABASE` captured 591.7 MB of log and
  a catalog. If you restore it to a point in time, you get rows whose blobs
  changed independently. The other three paths put the files in the database
  backup.
- **A separate security boundary.** The storage account controls access, not
  SQL Server permissions on the row.
- **Billing per operation.** This run used 161,981 PUT operations. At this
  volume the cost is very small. But the cost increases with file *count*, and
  file count is where this workload is heaviest.

### What to recommend

Use this path for an ingest of many small files when the bytes do not need to
be inside the database. It is the fastest path we measured, and it puts almost
no load on SQL Server. For large objects, it is the slowest path per stream, by
a factor of five. Do not use it when a database restore must also restore the
files.

---

## Not yet done

1. **Find if bandwidth or cluster size causes the 37% gap.** See
   [the summary](#what-is-not-settled). One provisioning check is enough. It
   costs nothing, and it decides if a reformat is worth doing.
2. **The A/B test against in-table `varbinary(max)`.** Nobody has run it.
   `Invoke-PocRun.ps1 -Matrix` includes it. We measured FILESTREAM against
   FileTable, but not against bytes stored in the row. For files under 1 MB,
   most applications face that comparison.
3. **A `FULL` recovery run.** Every run used `SIMPLE`. Under `FULL`, the log
   backup chain carries the FILESTREAM data. Backup size, backup duration and
   log management all change a lot.
4. **The read path.** `FilestreamRead` and `BlobRead` have not run. Ingest
   performance gives only half of the answer.
5. **Process Monitor analysis of each operation.** Capture now works. Runs 4, 6
   and 7 produced traces of 852 MB, 1.20 GB and 509 MB. Nobody has converted
   them to CSV or analysed them. So there is still no NTFS-level breakdown of
   the time per file. That analysis would explain two structural counts that
   this report can state but not explain:
   - **4.00 `CreateFile` calls per file written.**
   - **2.92 `DeleteFile` calls per file** in run 4, from garbage collection
     during a load that only inserts.

   Conversion is opt-in on purpose (`Invoke-PocAnalysis.ps1 -ConvertProcmon`).
   It is single-threaded, and it writes a CSV larger than the trace.
6. **A batched-commit test.** In every bucket on every disk, the commit costs
   more than the write. The ingest uses one transaction per file, so nobody has
   measured the gain from batching.

---

## How these numbers were taken

Each run creates 200 GB of synthetic data from an in-memory pool of
cryptographic random bytes. The bytes are written at random offsets. So the
data is incompressible. NTFS compression, host-level dedup and storage-side
compression cannot make throughput look higher. Also, the kit does not stage
data to disk first. So a 200 GB run needs 200 GB of capacity, not 400 GB.

The file sizes are on both sides of the FILESTREAM crossover, on purpose. The
shares are shares of *bytes*, not of file count. That is why the small buckets
have very large file counts:

| Bucket | Size range | Share of bytes | Files per run |
|---|---|---|---|
| Tiny | 4 KB - 64 KB | 2% | ~123,000 |
| Small | 64 KB - 1 MB | 8% | ~31,000 |
| Medium | 1 MB - 16 MB | 30% | ~7,200 |
| Large | 16 MB - 256 MB | 45% | ~680 |
| Huge | 256 MB - 2000 MB | 15% | ~35 |

The **client** captures the `open`, `write` and `commit` timings for each file.
Win32 streaming writes never go through the SQL Server I/O stack. In run 4,
`sys.dm_io_virtual_file_stats` recorded 0.77% of the data volume. No DMV can
see the other 99.2%.

Wait statistics are snapshot deltas from before and after the run. An Extended
Events session captures waits over 10 ms. That session makes the slow-tail
analysis possible. Process Monitor traces a 120-second window at steady state,
not the whole run. Tracing the whole run would change the number that we
measure.

The Huge bucket has 28 to 36 files per run. Use its numbers as a rough guide only.

---

## Reproducing

```powershell
# 1. Inspect the machine first - the config is not portable between VMs
.\ps\Setup-FilestreamPoc.ps1 -ShowLayout

# 2. Clean baseline. The container MUST be empty or directory pressure costs
#    roughly 2x per-file throughput; the preflight now refuses to start if it
#    is not. Reset keeps FsPocMonitor, so previous runs stay comparable.
.\ps\Reset-FilestreamPoc.ps1 -Execute
powershell.exe -ExecutionPolicy Bypass -File .\ps\Setup-FilestreamPoc.ps1 -SkipSmokeTest

# 3. Verify the streaming path with one file before committing to 200 GB
powershell.exe -ExecutionPolicy Bypass -File .\ps\Test-FilestreamPath.ps1

# 4. Run. -Label names the configuration so section 8 of the analysis can
#    tell runs apart.
.\ps\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 200 -Label 'Premium v2 64k'
```

If a step fails *after* the load completes, do not run the load again. At that
point, every input that the analysis needs is already saved:

```powershell
.\ps\Invoke-PocAnalysis.ps1 -List   # which artefacts survive, per run
.\ps\Invoke-PocAnalysis.ps1         # re-run the reporting only
```

The drop takes about 30 seconds on a disk with enough IOPS. On a disk without
enough IOPS, allow 10 minutes.

On every disk, early progress looks stalled. The Tiny and Small buckets have
about 154,000 files but only 20 GB. The progress ETA applies that early rate to
the whole target. Throughput increases sharply when the run reaches Medium. That
phase took about 17 minutes on the P40 and about 6 minutes on PremiumV2.
