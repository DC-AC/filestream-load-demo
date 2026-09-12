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

    # --- Azure Blob Storage (the AzureBlob scenarios) ---------------------
    # A fourth write path, measured for comparison. It is NOT a SQL Server
    # feature: the client PUTs blobs straight to the storage REST endpoint and
    # the database is never in the path. Its numbers are bound by the VM's
    # network and the storage account, not by the container disk, so read them
    # alongside the others rather than against them.
    BlobAccount   = 'stblobtesteus'
    BlobContainer = 'fspoc'
    BlobEndpoint  = 'blob.core.windows.net'   # change for a sovereign cloud
    <#  Authentication: 'ManagedIdentity' or 'Sas'.

        ManagedIdentity is the default and wants nothing stored anywhere. The VM
        asks IMDS for a token scoped to https://storage.azure.com/ and sends it
        as a bearer token; tokens rotate on their own and no credential lands in
        a file that lives in git.

        The identity needs a DATA-plane role on the account or container --
        "Storage Blob Data Contributor" for ingest, "Storage Blob Data Reader"
        for AzureBlobRead. Owner and Contributor are control-plane roles and do
        NOT grant blob data access; that mismatch produces a 403 on every
        upload while the portal shows the identity as having full rights.

            az role assignment create --assignee-object-id <vm-identity-object-id> \
              --assignee-principal-type ServicePrincipal \
              --role "Storage Blob Data Contributor" \
              --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/stblobtesteus

        Role assignments can take a few minutes to take effect.
    #>
    BlobAuth      = 'ManagedIdentity'

    # Only for a USER-assigned identity. Leave blank for the system-assigned one.
    BlobManagedIdentityClientId = ''

    # Only used when BlobAuth = 'Sas'. Without the leading '?'. Prefer the
    # FSPOC_BLOB_SAS environment variable so it never touches disk.
    BlobSasToken  = ''

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
