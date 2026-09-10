# SQL Server FILESTREAM performance POC kit

This kit generates and ingests a few hundred GB into a FILESTREAM database on an
Azure SQL Server VM. It puts wait-stat, Extended Events, Perfmon and Process
Monitor instrumentation around the load. It also runs an A/B baseline against
plain in-table `varbinary(max)`.

---

## Constraints. Read these first

**Run everything on the SQL Server VM. Use Windows PowerShell 5.1.**

The ingest engine writes through `System.Data.SqlTypes.SqlFileStream`. This type
is the managed wrapper over the Win32 FILESTREAM streaming API. It exists in
.NET Framework only. Microsoft never ported it to .NET Core or .NET 5+, and
`Microsoft.Data.SqlClient` does not include it.

Under PowerShell 7 the scripts fail with a type-not-found error. The only
fallback is the T-SQL path, which is the thing you want to measure against.
`Invoke-FilestreamIngest.ps1` checks `$PSVersionTable` and refuses to start.
This stops the kit from measuring the wrong thing.

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\ps\Invoke-PocRun.ps1
```

**You must use Windows authentication.** `PathName()` gives the client a UNC
path into the FILESTREAM share. The client opens that path with `CreateFile`
under its own Windows token. SQL authentication gives you a valid path and then
an access-denied error. The connection strings in the kit use
`Integrated Security=SSPI`.

**Set the FILESTREAM access level to 2 or higher.** Use level 3 if you ever run
the client off the VM. Level 1 is T-SQL only, and the Win32 open fails.

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
  Reset-FilestreamPoc.ps1    Full teardown before a rebuild (dry run by default)
  Invoke-PocAnalysis.ps1     Re-run analysis for a finished load (no re-load)
  Test-FilestreamPath.ps1    Single-file step-by-step SqlFileStream diagnostic
  Get-CrashEvidence.ps1      Bugcheck vs platform reset, filter drivers, AV
  Get-BugcheckAnalysis.ps1   Runs !analyze -v and names the faulting driver
  Invoke-PocRun.ps1          <- entry point
  Invoke-FilestreamIngest.ps1  The ingest/read engine
  Start-PocCapture.ps1       XEvents + Perfmon + windowed Procmon
  Stop-PocCapture.ps1        Teardown + PML->CSV conversion
  Measure-ProcmonLog.ps1     Procmon CSV analysis
  Import-PocTimings.ps1      Bulk-loads per-file timings into FsPocMonitor

tests/
  Test-FsPocKit.ps1          Parse + parameter-binding + execution checks

procmon/README.md            Procmon column/filter setup (one-time, manual)
```

---

## Quick start

1. Copy the whole folder to the VM. Use `C:\FsPoc`, for example.

2. Edit `ps\FsPocConfig.psd1`. Set `SqlInstance` and the four paths. **Put
   `FsPath`, `LogPath` and `ResultsPath` on separate disks.** See the Azure
   notes below.

3. **Check the volume roles.** `DataPath`, `LogPath` and `FsPath` must point at
   the volumes you intend.

   A FILESTREAM container on the log disk measures the wrong device, and nothing
   downstream reports the mistake. Setup cross-checks each path against the
   instance's own `InstanceDefaultDataPath` and `InstanceDefaultLogPath`. SQL
   Server's configured defaults are the authoritative statement of which volume
   holds what. A volume label is free text that can be stale or blank. Setup
   refuses to continue on a mismatch. Use `-IgnoreVolumeRoles` when the layout
   is deliberate.

4. Run the one-time setup from an elevated prompt:

   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File .\ps\Setup-FilestreamPoc.ps1 -RestartSqlService -ApplyNtfsTuning
   ```

   This step enables Windows-level FILESTREAM through WMI. It restarts SQL
   Server, creates the directories and checks the volumes. It runs the SQL
   scripts. It ends with a 50 MB smoke test through the real `SqlFileStream`
   path. If the smoke test fails, nothing else in the kit works. The script
   prints the four usual causes.

5. Set up Procmon once. Follow [`procmon/README.md`](procmon/README.md). The
   Duration column is off by default, and you need it.

6. Run the load:

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

## What the kit generates

The kit builds 200 GB in memory from a 256 MB pool of cryptographic random
bytes. It writes those bytes at random offsets. Nothing goes to disk first, so a
200 GB run needs 200 GB of destination capacity, not 400 GB.

The random-offset scheme keeps the data incompressible. This matters. NTFS
compression, Azure host-level dedup and any storage-side compression inflate
your throughput. An inflated number does not survive production.

Default `Mixed` profile at 200 GB:

| Bucket | Size range      | Share of bytes | Files   |
|--------|-----------------|----------------|---------|
| Tiny   | 4 KB - 64 KB    | 2%             | ~123,000 |
| Small  | 64 KB - 1 MB    | 8%             | ~31,000  |
| Medium | 1 MB - 16 MB    | 30%            | ~7,200   |
| Large  | 16 MB - 256 MB  | 45%            | ~680     |
| Huge   | 256 MB - 2000 MB| 15%            | ~28      |
|        |                 |                | **~162,000** |

The shares are shares of *bytes*, not of file count. This is why the small
buckets produce very high file counts. The kit does this on purpose.

FILESTREAM's cost is per file, not per byte. NTFS directory pressure and
per-file transaction overhead usually decide the answer. A naive test that
writes 200 GB in 200 files misses both.

The ranges cross the crossover point on purpose. The long-standing guidance says
that FILESTREAM tends to win above about 1 MB and to lose below about 256 KB.
Your storage decides the middle, which is the reason to run a POC.
`05-analysis.sql` reports every bucket separately. You get a crossover point for
*your* VM instead of one blended number that hides it.

The `Huge` bucket stops just below 2000 MB on purpose. `varbinary(max)` holds at
most 2 GB per value, and FILESTREAM has no such limit. Both paths can run the
same profile below that ceiling. Write the ceiling into the POC findings: it is
a hard functional difference, not a performance one.

To ingest real files instead, use `-SourcePath D:\RealFiles`.

---

## What the kit measures

**Client-side per-file timings.** The kit records an `open`, `write` and
`commit` split for every file. It writes the split to per-worker CSVs and
bulk-loads it into `FsPocMonitor.dbo.IngestTiming`.

This is the only source of per-operation latency for the streaming path. Those
writes never pass through SQL Server's I/O stack, because the client writes to
NTFS directly. `sys.dm_io_virtual_file_stats` cannot see them, and no other DMV
can see them either.

**Wait statistics.** The kit takes full `sys.dm_os_wait_stats` snapshots on both
sides of the run and deltas them in `vw_WaitDelta`. Section 3 of the analysis
reports FILESTREAM and Win32 waits *unfiltered*. It includes the waits that
people normally dismiss as idle noise:

| Wait | What it means here |
|------|--------------------|
| `FSAGENT` | FILESTREAM agent throttle. Contention on the FS agent |
| `FS_FC_RWLOCK` | Garbage collector / file control lock |
| `FS_HEADER_RWLOCK` | Container metadata contention |
| `FSA_FORCE_OWN_XACT` | Transaction ownership handoff on Win32 open |
| `PREEMPTIVE_OS_WRITEFILE` | Raw NTFS write cost |
| `PREEMPTIVE_OS_CREATEFILE` | New container file. NTFS metadata cost |
| `PREEMPTIVE_OS_FLUSHFILEBUFFERS` | Durability flush |
| `PREEMPTIVE_OS_DELETEFILE` | Garbage collection |

SQL Server's own FILESTREAM work shows up in the `PREEMPTIVE_OS_*` family. Win32
file operations run preemptively: the worker leaves the scheduler, and the time
lands there. Standard "top waits" scripts filter `PREEMPTIVE_*` out as noise.
That is why FILESTREAM investigations so often come back empty-handed. This kit
does not filter them.

**Extended Events** (`FsPoc_Waits`). The session captures `wait_info`,
`wait_info_external`, `file_write_completed`, `file_read_completed`,
`databases_log_flush`, `sql_transaction` and `error_reported`. Aggregate deltas
tell you *which* waits dominated. This tells you *when* and *for how long*, so
you can line the SQL timeline up against the Procmon timeline.

**DMV activity sampler.** A dedicated runspace reads `sys.dm_os_waiting_tasks`
every 5s. This gives you the *shape* of the run over time, not just the totals.

**Perfmon.** The kit collects disk latency and throughput per volume, CPU, and
the Windows system file cache counters (`Memory\Cache Bytes` and
`System Cache Resident Bytes`).

That last group matters more than people expect. FILESTREAM I/O flows through
the Windows file cache, **not** through the SQL Server buffer pool. A
`max server memory` value that is too high starves the cache your FILESTREAM
reads depend on. No SQL-side counter shows you this.

**Process Monitor.** This gives the per-file NTFS anatomy. See
[`procmon/README.md`](procmon/README.md).

---

## Azure VM specifics that otherwise ruin the result

**Use separate disks.** A single Azure managed disk has a hard IOPS and MB/s
cap. If the FILESTREAM container, the transaction log and the Procmon backing
file share one disk, you measure the disk SKU, not FILESTREAM. The minimum
viable split puts the container on its own data disk, the log on a second, and
results and traces on a third. `Setup-FilestreamPoc.ps1` prints the volume
layout so you can check it.

**Set host caching to None.** Use `None` on the disk that holds the container
for a write-heavy POC. `ReadOnly` helps re-read workloads, but it inflates write
numbers in a way that does not survive production.

**Watch the disk throughput ceiling.** If you hit a flat throughput line, check
the disk cap before you blame FILESTREAM. Either scale the disk SKU, or add a
second container on another disk. Set `FsPath2` in the config, and
`02-create-database.sql` adds it to the same filegroup. SQL Server then fills
both containers proportionally.

**Exclude the container from antivirus.** Exclude the container path *and*
`sqlservr.exe`. A real-time scanner sees every FILESTREAM file as a brand-new
file on disk, because it is one. This is the most common cause of a bad
FILESTREAM POC result, and you cannot see it from inside SQL Server. The Procmon
table of every process that touches the container is how you catch it.

**Disable 8.3 name generation.** Every file created in a directory that still
generates short names costs an extra NTFS index insert. That cost grows
super-linearly as the directory fills, which is what a container does over
160,000 files. `Setup-FilestreamPoc.ps1 -ApplyNtfsTuning` disables it for new
files only.

**Turn on Instant File Initialization.** Grant *Perform volume maintenance
tasks* to the service account. This does not affect FILESTREAM containers, but
it stops MDF growth from polluting the run.

---

## Between runs

Read the header of `99-cleanup.sql` before you reuse the database.

A row delete does **not** free disk space. FILESTREAM files are tombstoned. A
background garbage collector removes them, and it only advances past
`CHECKPOINT`. Under `FULL` recovery it also waits for a log backup.

Start a second run straight after a `DELETE` and the collector is still running
in the background. It pollutes the numbers. Either drop and recreate the
database, or use `-v Mode="purge"` and wait for the container to shrink on disk.

`Invoke-PocRun.ps1 -Matrix` inserts a 60s settle between runs for the same
reason. On a few hundred GB that settle is nowhere near enough. Drop and
recreate between large runs.

---

## Recovery model

The kit creates the database in `SIMPLE` recovery with a presized 16 GB log.
This stops log growth from becoming the thing you measure. It is the right
default for a throughput baseline and the wrong default for production.

Do a second run in `FULL` recovery before you draw conclusions. Under `FULL`,
the log backup chain carries the FILESTREAM data. Backup size, backup duration
and log management all change a lot. `WRITELOG` in the section 2 analysis is
where you see it.

---

## Validating changes before you copy the kit to the VM

```
pwsh -File .\tests\Test-FsPocKit.ps1
```

The test runs three levels of check. The first level is not enough on its own,
and this kit has been bitten twice by that.

1. **Parse.** Every script parses, and the config loads.
2. **Binding.** Every call site to a module function binds. A parse check
   accepts `Write-FsPocLog 'msg' 'STEP'` against a function whose second
   parameter is named-only. It then fails on the first call at runtime. The
   parser has no opinion about parameter binding.
3. **Execution.** The test invokes every platform-independent function in the
   forms the scripts use.

The test runs under PowerShell 7 on any OS. It does **not** cover the
`SqlFileStream` path, WMI FILESTREAM enablement, or anything else that needs
Windows and SQL Server. `Setup-FilestreamPoc.ps1` ends with a real 50 MB smoke
test through `SqlFileStream` on the VM. That is the check that matters.

## Changing any path after the first build

Correcting a path in the config is not enough on its own. Run this:

```powershell
.\ps\Reset-FilestreamPoc.ps1            # shows what it would remove
.\ps\Reset-FilestreamPoc.ps1 -Execute   # drops both DBs, removes containers
```

The FILESTREAM container's leaf folder must not exist when `CREATE DATABASE`
runs. A container left over from a previous build is the usual reason the next
`CREATE` fails. Reset reads the real file locations from `sys.master_files`
instead of trusting the config. That matters when the config is the thing you
just changed.

## If something fails after the load finishes

Do not re-run the load. Everything the analysis needs is durable the moment the
ingest returns. The `start` and `end` snapshots are committed to `FsPocMonitor`.
The per-file timings are already written to per-worker CSVs in the run folder.
The Procmon and `.xel` files are on disk.

```powershell
.\ps\Invoke-PocAnalysis.ps1 -List     # every run, and which artefacts survive
.\ps\Invoke-PocAnalysis.ps1           # analyse the newest completed run
.\ps\Invoke-PocAnalysis.ps1 -ConvertProcmon   # also do the expensive PML -> CSV
```

`-List` reports three things per run: how many of the two wait snapshots exist,
how many timing rows are imported, and which files remain in the run folder. A
run that shows 2/2 wait snapshots has everything the SQL analysis needs. What
happened afterwards does not matter.

The PML to CSV conversion is opt-in, because it is single-threaded. It writes a
file that can be larger than the trace itself. Do not trigger it by accident on
a machine that is already unstable under I/O load.

## Known platform issue: bugcheck 0x18 during FILESTREAM ingest

The first target VM ran Windows Server 2022, build 20348.4294, and SQL Server
2019 15.0.4470.1. The machine bugchecked twice during ingest with
`0x18 REFERENCE_BY_POINTER`. `!analyze -v` on the minidumps gave the same
signature both times:

```
disk!DiskFlushDispatch                  flush IRP heading to the disk
storport!Raid*                          completing
nt!IofCompleteRequest
Ntfs!NtfsFlushCompletionRoutine
Ntfs!NtfsIoPerfCollectFlushData
Ntfs!FsLibIoPerfNotifyHighLatency       <- NTFS recorded a slow I/O
Ntfs!NtfsIoPerfPostFileObjectLatency
Ntfs!NtfsIoPerfPostFileObjectInfo       <- and faulted while recording it
nt!ObfReferenceObject                   -> 0x18
```

NTFS observes a high-latency flush. It enters its I/O telemetry path to record
the flush. It then references a file object whose count is already zero.

**This is a Windows NTFS defect. It is not FILESTREAM, not antivirus, and not
this kit.** A user-mode program cannot corrupt a kernel object's reference
count. It can only issue I/O that reaches the defective path. `MODULE_NAME:
disk` is a red herring. `!analyze` attributes the fault to the driver that owns
the IRP. On a completion-path fault, that driver sits several frames below the
code that faulted.

What helps:

| Action | Effect |
|---|---|
| Latest Windows cumulative update | May carry a fix. No public KB matches this signature |
| Microsoft support case with the dump | The signature is specific enough to be actionable |
| Faster disk tier / lower latency | The fault needs *high-latency* flushes, so fewer are reached |
| Fewer commits (batch files per transaction) | Each commit forces a durability flush |

The last two actions are not fixes. They reduce how often the code reaches the
defective path.

`ps\Get-CrashEvidence.ps1` establishes whether a restart was a bugcheck or a
platform reset. `ps\Get-BugcheckAnalysis.ps1` runs `!analyze -v`. It classifies
the result from the whole stack instead of from `MODULE_NAME` alone.

## Known gotchas

- The FILESTREAM container's **leaf folder must not exist** before
  `CREATE DATABASE`. SQL Server creates it. The parent folder must exist. If a
  drop leaves the folder behind, something held a handle. Delete the folder by
  hand.
- FILESTREAM containers do not support `ReFS`. Use NTFS only.
- The PML to CSV conversion in `Stop-PocCapture.ps1` is single-threaded and slow
  on large traces. `-SkipProcmonConvert` defers it.
- Read-back verification counts bytes. It does not hash content. A hash would
  add a round trip inside the interval being timed.
- If `logman create` reports missing counters, check `perfmon-counters.txt` in
  the results folder. Some counter names differ across Windows builds. Named
  instances use `MSSQL$INSTANCE:` instead of `SQLServer:`, and the kit handles
  that case automatically.
