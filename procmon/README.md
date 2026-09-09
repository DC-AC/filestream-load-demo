# Process Monitor configuration for the FILESTREAM POC

Procmon settings live in a binary `.pmc` file that only Procmon can write, so
this is a one-time manual setup. Build it once, save it, and pass it to every
run with `-ProcmonConfig`.

```powershell
.\Invoke-PocRun.ps1 -Scenario Filestream -TargetGB 20 -Procmon `
                    -ProcmonConfig C:\Tools\Procmon\FilestreamPoc.pmc
```

---

## 1. Get Procmon onto the VM

Download Process Monitor from Sysinternals, unzip to `C:\Tools\Procmon`, and
unblock it — files downloaded through a browser carry the mark-of-the-web and
Procmon's driver will refuse to load:

```powershell
Get-ChildItem C:\Tools\Procmon | Unblock-File
```

Set `ProcmonExe` in `ps/FsPocConfig.psd1` to the full path of `Procmon64.exe`.

Procmon needs local administrator rights to load its filter driver.

---

## 2. Enable the Duration column — do this first

**Options → Select Columns**, and tick **Duration** under *Event*.

This is the single most important setting in the whole file and it is **off by
default**. Without it, the CSV has no per-operation latency, and
`Measure-ProcmonLog.ps1` can only report operation counts. Every question worth
asking here — *is the time going into `WriteFile` or into `CreateFile`?* — needs
this column.

While you are in that dialog, make sure these are ticked:

| Column        | Why |
|---------------|-----|
| Time of Day   | Timeline correlation against XEvents and Perfmon |
| Process Name  | Catches non-SQL processes touching the container |
| PID           | Distinguishes instances |
| Operation     | The NTFS call itself |
| Path          | Which container file |
| Result        | Non-`SUCCESS` means retries |
| Detail        | Carries `Length:` and `Offset:` — the actual I/O size |
| **Duration**  | Per-operation latency |

Untick *Sequence*, *Image Path*, *Command Line*, *User* and *Session* — they add
bytes to every event and answer nothing here.

---

## 3. Turn off the event classes you are not measuring

On the toolbar, leave only **Show File System Activity** enabled. Turn off:

- Show Registry Activity
- Show Network Activity
- Show Process and Thread Activity
- Show Profiling Events

Registry and profiling events alone can be the majority of captured events on a
busy server, and none of them tell you anything about FILESTREAM.

---

## 4. Filters

**Filter → Filter…** Remove nothing from the default exclusions; add these.

### Include only what matters

| Column       | Relation   | Value                          | Action  |
|--------------|-----------|--------------------------------|---------|
| Path         | begins with | `G:\FilestreamData`          | Include |

Use your real `FsPath`. This one rule does most of the work: it drops every
event that is not against the FILESTREAM container.

> **Deliberately do NOT filter on Process Name.** One of the things this trace
> is for is catching processes you did not expect in the container — antivirus,
> backup agents, indexing services, monitoring agents. Filtering to
> `sqlservr.exe` in Procmon would hide exactly the finding you most want.
> `Measure-ProcmonLog.ps1` applies the process filter at analysis time instead,
> and reports every process it saw before doing so.

### Cut the noise floor

| Column       | Relation | Value                | Action  |
|--------------|----------|----------------------|---------|
| Operation    | is       | `QueryNameInformationFile` | Exclude |
| Operation    | is       | `QuerySecurityFile`  | Exclude |
| Operation    | is       | `FASTIO_CHECK_IF_POSSIBLE` | Exclude |
| Result       | is       | `FAST IO DISALLOWED` | Exclude |

These are high-frequency, low-information events. Everything else stays.

### If you also want the transaction log volume

Add a second Include rule for the LDF path. Useful when you suspect the log —
not FILESTREAM — is the bottleneck, which for small-file ingest it very often
is.

---

## 5. Drop filtered events

**Filter → Drop Filtered Events** — tick it.

Without this, Procmon captures everything and only *displays* the filtered
subset, so your backing file grows at the full unfiltered rate. With it, the
excluded events are never written. On a 200 GB ingest this is the difference
between a few hundred MB of PML and tens of GB.

The trade-off: dropped events are gone permanently and you cannot widen the
filter afterwards. That is the right trade here — you know what you are looking
for.

---

## 6. Save the configuration

**File → Export Configuration…** → `C:\Tools\Procmon\FilestreamPoc.pmc`

Verify it loads cleanly:

```powershell
C:\Tools\Procmon\Procmon64.exe /AcceptEula /LoadConfig C:\Tools\Procmon\FilestreamPoc.pmc /Quiet /Minimized /Runtime 10 /BackingFile C:\Temp\test.pml
```

---

## 7. Why the kit runs Procmon in a short window, not for the whole ingest

Procmon is a kernel filter driver sitting in the path of every file system
operation on the machine. During a FILESTREAM ingest running at a few hundred
MB/s that is tens of thousands of events per second.

Two consequences:

1. **The backing file grows fast.** Even filtered, a sustained ingest produces
   gigabytes of PML. Put `ResultsPath` on a volume that is *not* the FILESTREAM
   container disk and *not* the log disk — otherwise the trace competes for the
   very IOPS you are measuring.

2. **It changes the number you are measuring.** The driver adds per-operation
   overhead. A throughput figure collected with Procmon running is not the
   throughput figure you would get in production.

So the kit separates the two questions:

| Question | How to answer it |
|----------|------------------|
| How fast is it? | Full run, **no Procmon**. Wait stats + Perfmon + client timings. |
| Why is it that fast? | Short run **with Procmon**, 60–120s window at steady state. |

`Start-PocCapture.ps1 -Procmon` handles this: it waits `-ProcmonDelaySec`
(default 30s) so the trace starts after ramp-up, captures for
`-ProcmonWindowSec` (default 120s), then stops itself with `/Runtime` while the
ingest keeps going.

---

## 8. Reading the results

`Measure-ProcmonLog.ps1` runs automatically after an instrumented run. What to
look for:

**Operations per file.** A FILESTREAM write should look roughly like
`CreateFile` → `SetAllocationInformationFile`/`SetEndOfFileInformationFile` →
*N* × `WriteFile` → `FlushBuffersFile` → `CloseFile`. If you see far more
operations per file than that, something is re-opening or re-probing files.

**Metadata vs data time split.** The script prints this. When metadata
operations cost more wall-clock than the actual data transfer, you are in
small-file territory — the regime where in-table `varbinary(max)` normally beats
FILESTREAM. That single line is often the whole answer to the POC.

**Actual I/O size.** Compare the `WriteFile` `Length:` distribution against your
configured `ChunkSizeKB`. If they differ, something between the client and the
disk is re-blocking the I/O.

**Every process touching the container.** Anything other than `sqlservr.exe`
here is overhead you did not intend to measure. Antivirus is the usual culprit
and is completely invisible from inside SQL Server.

**Non-`SUCCESS` results.** A steady trickle of retries or sharing violations
points at contention with something outside SQL Server.
