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
    # VERIFY THESE AGAINST THE ACTUAL VOLUMES BEFORE THE FIRST RUN.
    # Setup-FilestreamPoc.ps1 prints each volume's label and cross-checks it
    # against the role assigned here, because putting the container on the log
    # disk produces numbers that measure the wrong thing entirely.
    DataPath      = 'F:\SQLData'              # MDF          -> data volume
    LogPath       = 'G:\SQLLog'               # LDF          -> log volume
    FsPath        = 'H:\FilestreamData'       # FILESTREAM container (parent must exist)
    FsPath2       = ''                        # optional 2nd container on another disk
    XePath        = 'F:\XEvents'              # .xel target -- keep OFF the container and log volumes
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
