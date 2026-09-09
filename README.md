# SQL Server FILESTREAM performance POC kit

Generates and ingests a few hundred GB into a FILESTREAM database on an Azure
SQL Server VM, with wait-stat, Extended Events, Perfmon and Process Monitor
instrumentation around it, plus an A/B baseline against plain in-table
`varbinary(max)`.

---

## Constraints — read these first

**Run everything on the SQL Server VM itself, under Windows PowerShell 5.1.**

The ingest engine writes through `System.Data.SqlTypes.SqlFileStream`, the
managed wrapper over the Win32 FILESTREAM streaming API. That type exists in
.NET Framework and was **never ported to .NET Core / .NET 5+** —
`Microsoft.Data.SqlClient` does not include it. Under PowerShell 7 the scripts
fail with a type-not-found error, and the only fallback is the T-SQL path, which
is the thing you are trying to measure *against*. `Invoke-FilestreamIngest.ps1`
checks `$PSVersionTable` and refuses to start rather than silently measuring the
wrong thing.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ps\Invoke-PocRun.ps1
```

**Windows authentication is required.** `PathName()` gives the client a UNC path
into the FILESTREAM share, and the client opens it with `CreateFile` under its
own Windows token. SQL authentication gets you a valid path and then an
access-denied. The connection strings in the kit use `Integrated Security=SSPI`.

**FILESTREAM access level must be 2 or higher** (3 if you ever run the client
off-box). Level 1 is T-SQL only and the Win32 open is refused.

---

## Layout

```
sql/
  01-instance-config.sql     FILESTREAM access level, instance checks
  02-create-database.sql     Demo DB, FILESTREAM filegroup, FileStore + BlobStore, procs
  03-monitor-db.sql          FsPocMonitor: run metadata, snapshots, sampler, analysis views
  04-xevents.sql             FsPoc_Waits event session
  05-analysis.sql            Post-run report
  06-xevent-shred.sql        Shreds the .xel files
  99-cleanup.sql             Drop or purge between runs (read the GC note)

ps/
  FsPocConfig.psd1           <- edit this first
  FsPoc.Common.psm1          Shared helpers, workload planner, random pool
  Setup-FilestreamPoc.ps1    One-time VM prep + smoke test
  Invoke-PocRun.ps1          <- entry point
  Invoke-FilestreamIngest.ps1  The ingest/read engine
  Start-PocCapture.ps1       XEvents + Perfmon + windowed Procmon
  Stop-PocCapture.ps1        Teardown + PML->CSV conversion
  Measure-ProcmonLog.ps1     Procmon CSV analysis
  Import-PocTimings.ps1      Bulk-loads per-file timings into FsPocMonitor

procmon/README.md            Procmon column/filter setup (one-time, manual)
```

---

## Quick start

1. Copy the whole folder to the VM, e.g. `C:\FsPoc`.

2. Edit `ps\FsPocConfig.psd1`. At minimum set `SqlInstance` and the four paths.
   **Put `FsPath`, `LogPath` and `ResultsPath` on separate disks** — see the
   Azure notes below.

3. One-time setup, elevated:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\ps\Setup-FilestreamPoc.ps1 -RestartSqlService -ApplyNtfsTuning
   ```

   This enables Windows-level FILESTREAM via WMI, restarts SQL Server, creates
   the directories, checks the volumes, runs the SQL scripts, and finishes with
   a 50 MB smoke test through the real `SqlFileStream` path. If the smoke test
   fails, nothing else in the kit will work — it prints the four usual causes.

4. Set up Procmon once, following [`procmon/README.md`](procmon/README.md).
   The Duration column is off by default and you need it.

5. Run:

   ```powershell
   # The headline number: 200 GB, clean, no tracing overhead
   .\ps\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 200 -Threads 8

   # Short instrumented run for per-operation anatomy
   .\ps\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 20 -Procmon `
                          -ProcmonConfig C:\Tools\Procmon\FilestreamPoc.pmc

   # The comparison that answers the actual question
   .\ps\Invoke-PocRun.ps1 -Matrix -TargetGB 20
   ```

---

## What gets generated

200 GB is synthesised in memory from a 256 MB pool of cryptographic random
bytes, written at random offsets. Nothing is staged to disk first, so a 200 GB
run needs 200 GB of destination capacity, not 400 GB. The random-offset scheme
keeps the data incompressible, which matters: NTFS compression, Azure host-level
dedup and any storage-side compression would otherwise inflate your throughput
into a number that will not survive production.

Default `Mixed` profile at 200 GB:

| Bucket | Size range      | Share of bytes | Files   |
|--------|-----------------|----------------|---------|
| Tiny   | 4 KB – 64 KB    | 2%             | ~123,000 |
| Small  | 64 KB – 1 MB    | 8%             | ~31,000  |
| Medium | 1 MB – 16 MB    | 30%            | ~7,200   |
| Large  | 16 MB – 256 MB  | 45%            | ~680     |
| Huge   | 256 MB – 2000 MB| 15%            | ~28      |
|        |                 |                | **~162,000** |

Shares are of *bytes*, not file count, which is why the small buckets produce
enormous file counts. That is deliberate. FILESTREAM's cost is per-file, not
per-byte: NTFS directory pressure and per-file transaction overhead are the two
things a naive "write 200 GB in 200 files" test misses entirely, and they are
usually what decides the answer.

Ranges straddle the crossover on purpose. The long-standing guidance is that
FILESTREAM tends to win above ~1 MB and lose below ~256 KB, with the middle
depending entirely on your storage — which is the reason to run a POC at all.
`05-analysis.sql` reports every bucket separately so you get a crossover point
for *your* VM rather than a single blended number that hides it.

The `Huge` bucket stops just under 2000 MB deliberately. `varbinary(max)` caps
at 2 GB per value; FILESTREAM has no such limit. Keeping both under the ceiling
lets the identical profile run down both paths — and that ceiling is itself
worth writing into the POC findings, because it is a hard functional difference
rather than a performance one.

To ingest real files instead: `-SourcePath D:\RealFiles`.

---

## What gets measured

**Client-side per-file timings** — `open` / `write` / `commit` split for every
single file, written to per-worker CSVs and bulk-loaded into
`FsPocMonitor.dbo.IngestTiming`. This is the only source of per-operation
latency for the streaming path, because those writes never pass through SQL
Server's I/O stack at all: the client writes to NTFS directly. `sys.dm_io_virtual_file_stats`
cannot see them, and neither can any DMV.

**Wait statistics** — full `sys.dm_os_wait_stats` snapshots either side of the
run, delta'd in `vw_WaitDelta`. Section 3 of the analysis reports FILESTREAM and
Win32 waits *unfiltered*, including ones normally dismissed as idle noise:

| Wait | What it means here |
|------|--------------------|
| `FSAGENT` | FILESTREAM agent throttle — contention on the FS agent |
| `FS_FC_RWLOCK` | Garbage collector / file control lock |
| `FS_HEADER_RWLOCK` | Container metadata contention |
| `FSA_FORCE_OWN_XACT` | Transaction ownership handoff on Win32 open |
| `PREEMPTIVE_OS_WRITEFILE` | Raw NTFS write cost |
| `PREEMPTIVE_OS_CREATEFILE` | New container file — NTFS metadata cost |
| `PREEMPTIVE_OS_FLUSHFILEBUFFERS` | Durability flush |
| `PREEMPTIVE_OS_DELETEFILE` | Garbage collection |

The `PREEMPTIVE_OS_*` family is where SQL Server's own FILESTREAM work shows up,
because Win32 file operations run preemptively — the worker leaves the scheduler
and the time lands there. Standard "top waits" scripts filter `PREEMPTIVE_*` out
as noise, which is precisely why FILESTREAM investigations so often come back
empty-handed. This kit does not filter them.

**Extended Events** (`FsPoc_Waits`) — `wait_info`, `wait_info_external`,
`file_write_completed`, `file_read_completed`, `databases_log_flush`,
`sql_transaction`, `error_reported`. Aggregate deltas tell you *which* waits
dominated; this tells you *when* and *for how long*, which is what lets you line
the SQL timeline up against the Procmon timeline.

**DMV activity sampler** — `sys.dm_os_waiting_tasks` every 5s from a dedicated
runspace, giving the *shape* of the run over time rather than just totals.

**Perfmon** — disk latency and throughput per volume, CPU, and the Windows
system file cache counters (`Memory\Cache Bytes`, `System Cache Resident
Bytes`). That last group matters more than people expect: FILESTREAM I/O flows
through the Windows file cache, **not** the SQL Server buffer pool. An
over-generous `max server memory` starves the cache your FILESTREAM reads depend
on, and no SQL-side counter will show you that.

**Process Monitor** — the per-file NTFS anatomy. See
[`procmon/README.md`](procmon/README.md).

---

## Azure VM specifics that will otherwise ruin the result

**Separate disks.** A single Azure managed disk has a hard IOPS and MB/s cap.
If the FILESTREAM container, the transaction log and the Procmon backing file
share one disk, you are measuring the disk SKU, not FILESTREAM. Minimum viable
split: container on its own data disk, log on another, results/traces on a
third. `Setup-FilestreamPoc.ps1` prints the volume layout so you can check.

**Host caching.** Set caching to **None** on the disk holding the container for
a write-heavy POC. `ReadOnly` helps re-read workloads but inflates write numbers
in a way that will not survive production.

**Disk throughput ceiling.** If you hit a flat throughput line, check the disk
cap before blaming FILESTREAM. Either scale the disk SKU or add a second
container on another disk — set `FsPath2` in the config and
`02-create-database.sql` adds it to the same filegroup, which SQL Server fills
proportionally across both.

**Antivirus.** Exclude the container path *and* `sqlservr.exe`. A real-time
scanner sees every FILESTREAM file as a brand-new file on disk, because it is
one. This is the most common cause of a bad FILESTREAM POC result, and it is
invisible from inside SQL Server — the Procmon "every process touching the
container" table is how you catch it.

**8.3 name generation.** Every file created in a directory that still generates
short names costs an extra NTFS index insert, and the cost grows
super-linearly as the directory fills — which is exactly what a container does
over 160,000 files. `Setup-FilestreamPoc.ps1 -ApplyNtfsTuning` disables it
(new files only).

**Instant File Initialization.** Grant *Perform volume maintenance tasks* to the
service account. It does not affect FILESTREAM containers, but it stops MDF
growth from contaminating the run.

---

## Between runs

Read the header of `99-cleanup.sql` before reusing the database.

Deleting rows does **not** free disk. FILESTREAM files are tombstoned and
removed by a background garbage collector that only advances past `CHECKPOINT`
(and, under `FULL` recovery, past a log backup). Start a second run straight
after a `DELETE` and the GC is still churning in the background — it will
pollute the numbers. Either drop and recreate the database, or use
`-v Mode="purge"` and wait for the container to actually shrink on disk.

`Invoke-PocRun.ps1 -Matrix` inserts a 60s settle between runs for the same
reason. On a few hundred GB that is nowhere near enough — drop and recreate
between large runs.

---

## Recovery model

The kit creates the database in `SIMPLE` recovery with a presized 16 GB log, so
that log growth is not what you end up measuring. That is the right default for
a throughput baseline and the wrong default for production.

Do a second run in `FULL` recovery before you draw conclusions. Under `FULL`,
FILESTREAM data is carried in the log backup chain, and backup size, backup
duration and log management change substantially. `WRITELOG` in the section 2
analysis is where that will show up.

---

## Known gotchas

- The FILESTREAM container's **leaf folder must not exist** before
  `CREATE DATABASE` — SQL Server creates it. The parent must exist. If a drop
  leaves the folder behind (something held a handle), delete it by hand.
- `ReFS` is not supported for FILESTREAM containers. NTFS only.
- The PML→CSV conversion in `Stop-PocCapture.ps1` is single-threaded and slow on
  large traces. `-SkipProcmonConvert` defers it.
- Read-back verification is by byte count, not content hash. Hashing would add a
  round trip inside the interval being timed.
- If `logman create` reports missing counters, check
  `perfmon-counters.txt` in the results folder — some counter names differ
  across Windows builds, and named instances use `MSSQL$INSTANCE:` rather than
  `SQLServer:` (the kit handles the named-instance case automatically).
