@{
    # --- Connection -------------------------------------------------------
    SqlInstance   = '.'                       # e.g. '.', 'SQLVM01', 'SQLVM01\INST2'
    DemoDb        = 'FsPocDemo'
    MonitorDb     = 'FsPocMonitor'

    # --- Paths on the VM --------------------------------------------------
    # Put these on SEPARATE Azure data disks if you want the numbers to mean
    # anything. The FILESTREAM container and the transaction log competing for
    # one disk's IOPS budget is the single most common way to get a misleading
    # FILESTREAM POC result.
    DataPath      = 'F:\SQLData'              # MDF
    LogPath       = 'H:\SQLLog'               # LDF
    FsPath        = 'G:\FilestreamData'       # FILESTREAM container (parent must exist)
    FsPath2       = ''                        # optional 2nd container on another disk
    XePath        = 'H:\XEvents'              # Extended Events .xel target
    ResultsPath   = 'C:\FsPocResults'         # CSVs, Procmon logs, reports

    # --- Tools ------------------------------------------------------------
    # Download Process Monitor from Sysinternals and unblock the exe.
    ProcmonExe    = 'C:\Tools\Procmon\Procmon64.exe'

    # --- Workload defaults ------------------------------------------------
    TargetGB      = 200
    Threads       = 8                         # concurrent ingest streams
    ChunkSizeKB   = 4096                      # Win32 write buffer per call
    SizeProfile   = 'Mixed'                   # Tiny|Small|Medium|Large|Huge|Mixed
    RandomPoolMB  = 256                       # in-memory incompressible source pool

    # --- Capture defaults -------------------------------------------------
    SamplerIntervalSec = 5                    # DMV activity sampler tick
    ProcmonWindowSec   = 120                  # Procmon runs for a WINDOW, not the whole run
    PerfmonIntervalSec = 5
}
