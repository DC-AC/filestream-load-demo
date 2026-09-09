<#
.SYNOPSIS
    Pre-flight validation for the FILESTREAM POC kit. Run this before copying
    the kit to a SQL Server VM.

.DESCRIPTION
    Runs three levels of check, because the first two are not enough on their
    own and this kit has already been bitten by both gaps:

      1. PARSE      -- every .ps1/.psm1 parses, the .psd1 loads.
      2. BINDING    -- every call site to a module function actually binds.
                       A parse check will happily accept
                           Write-FsPocLog 'message' 'STEP'
                       against a function whose second parameter is named-only,
                       and it fails at runtime on the very first call. The
                       parser has no opinion about parameter binding.
      3. EXECUTION  -- every platform-independent function is actually invoked
                       in the forms the scripts use.

    This runs fine under PowerShell 7 on any OS. It deliberately does NOT test
    the SqlFileStream path, the WMI FILESTREAM enablement or anything else that
    needs Windows + SQL Server -- Setup-FilestreamPoc.ps1 ends with a real
    50 MB smoke test through SqlFileStream, which is the check that matters
    there and can only be done on the VM.

.EXAMPLE
    pwsh -File .\tests\Test-FsPocKit.ps1
#>
[CmdletBinding()]
param(
    [string] $PsRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'ps')
)

$ErrorActionPreference = 'Stop'
$script:Failures = 0
function Assert-Ok {
    param([string] $Name, [scriptblock] $Test)
    try { & $Test; Write-Host "  PASS  $Name" -ForegroundColor Green }
    catch { $script:Failures++; Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 1. PARSE ===' -ForegroundColor Cyan
foreach ($f in Get-ChildItem $PsRoot -Include *.ps1, *.psm1 -Recurse) {
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors.Count) {
        $script:Failures++
        Write-Host "  FAIL  $($f.Name)" -ForegroundColor Red
        $errors | Select-Object -First 5 | ForEach-Object {
            Write-Host "          line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red }
    }
    else { Write-Host "  PASS  $($f.Name)" -ForegroundColor Green }
}
Assert-Ok 'FsPocConfig.psd1 loads' { $null = Import-PowerShellDataFile (Join-Path $PsRoot 'FsPocConfig.psd1') }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 2. BINDING ===' -ForegroundColor Cyan
Import-Module (Join-Path $PsRoot 'FsPoc.Common.psm1') -Force

$meta = @{}
foreach ($cmd in Get-Command -Module FsPoc.Common) {
    $common = [System.Management.Automation.Cmdlet]::CommonParameters
    $params = @($cmd.Parameters.GetEnumerator() | Where-Object { $_.Key -notin $common })
    $explicit = @(); $all = @()
    foreach ($kv in $params) {
        $pos = $kv.Value.Attributes |
               Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] } |
               ForEach-Object { $_.Position } | Where-Object { $_ -ge 0 } | Select-Object -First 1
        $all += [pscustomobject]@{ Name = $kv.Key; IsSwitch = ($kv.Value.ParameterType -eq [switch]) }
        if ($null -ne $pos) { $explicit += $kv.Key }
    }
    # The rule that broke this kit: if ANY parameter declares an explicit
    # Position, every parameter without one becomes named-only.
    $meta[$cmd.Name] = [pscustomobject]@{
        Slots    = if ($explicit.Count) { $explicit.Count } else { @($all | Where-Object { -not $_.IsSwitch }).Count }
        Switches = @($all | Where-Object IsSwitch | ForEach-Object Name)
        Names    = @($all | ForEach-Object Name)
    }
}

$checked = 0; $bindFails = 0
foreach ($file in Get-ChildItem $PsRoot -Include *.ps1, *.psm1 -Recurse) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
    foreach ($call in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $call.GetCommandName()
        if (-not $name -or -not $meta.ContainsKey($name)) { continue }
        $checked++
        $els = @($call.CommandElements); $positional = 0
        for ($i = 1; $i -lt $els.Count; $i++) {
            $e = $els[$i]
            if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                $resolved = $meta[$name].Names | Where-Object { $_ -like "$($e.ParameterName)*" } | Select-Object -First 1
                $isSwitch = $resolved -and ($meta[$name].Switches -contains $resolved)
                if (-not $isSwitch -and $null -eq $e.Argument -and ($i + 1) -lt $els.Count -and
                    -not ($els[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst])) { $i++ }
            }
            else { $positional++ }
        }
        if ($positional -gt $meta[$name].Slots) {
            $script:Failures++; $bindFails++
            Write-Host ("  FAIL  {0}:{1} -> {2} takes {3} positional arg(s), called with {4}" -f `
                $file.Name, $call.Extent.StartLineNumber, $name, $meta[$name].Slots, $positional) -ForegroundColor Red
        }
    }
}
if ($bindFails -eq 0) { Write-Host "  PASS  all $checked call sites bind" -ForegroundColor Green }

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 3. EXECUTION ===' -ForegroundColor Cyan
Assert-Ok 'Write-FsPocLog, positional, every level' {
    foreach ($l in 'INFO','WARN','ERROR','STEP','OK') { Write-FsPocLog 'test' $l | Out-Null } }
Assert-Ok 'Write-FsPocLog, message only'   { Write-FsPocLog 'test' | Out-Null }
Assert-Ok 'Write-FsPocLog rejects bad level' {
    $threw = $false
    try { Write-FsPocLog 'test' 'NOT_A_LEVEL' | Out-Null } catch { $threw = $true }
    if (-not $threw) { throw 'ValidateSet not enforced' } }
Assert-Ok 'Format-FsPocBytes across magnitudes' {
    $r = @(0, 512, 4KB, 1MB, 1.5GB, 2TB | ForEach-Object { Format-FsPocBytes $_ })
    if ($r.Count -ne 6) { throw "expected 6 results, got $($r.Count)" } }
Assert-Ok 'Get-FsPocConfig resolves its own path' {
    $c = Get-FsPocConfig; if (-not $c.SqlInstance) { throw 'config empty' } }
Assert-Ok 'Get-FsPocConfig applies overrides' {
    if ((Get-FsPocConfig -Override @{ TargetGB = 20 }).TargetGB -ne 20) { throw 'override ignored' } }
Assert-Ok 'Get-FsPocConfig ignores blank overrides' {
    if ((Get-FsPocConfig -Override @{ TargetGB = $null; Threads = '' }).TargetGB -ne 200) {
        throw 'a blank override clobbered the configured default' } }
Assert-Ok 'Connection string uses integrated auth' {
    if ((Get-FsPocConnectionString -Instance '.' -Database 'X') -notmatch 'SSPI') {
        throw 'SqlFileStream requires a Windows token; SSPI missing' } }
Assert-Ok 'Work plan builds for every profile' {
    foreach ($p in 'Tiny','Small','Medium','Large','Huge','Mixed') {
        if (-not (Get-FsPocWorkPlan -TargetGB 200 -Profile $p -Threads 8)) { throw $p } } }
Assert-Ok 'Mixed profile sums to the target' {
    $sum = (Get-FsPocWorkPlan -TargetGB 200 -Profile Mixed -Threads 8 | Measure-Object TargetBytes -Sum).Sum
    if ([math]::Abs($sum - 200GB) -gt 1MB) { throw "sums to $($sum / 1GB) GB, expected 200" } }
Assert-Ok 'Single profile takes the whole target' {
    $p = Get-FsPocWorkPlan -TargetGB 10 -Profile Large -Threads 4
    if ([math]::Abs($p[0].TargetBytes - 10GB) -gt 1) { throw "got $($p[0].TargetBytes)" } }
Assert-Ok 'Huge bucket stays under the varbinary(max) ceiling' {
    $h = (Get-FsPocSizeProfile -Profile Huge)[0]
    if ($h.MaxBytes -ge 2147483647) { throw "MaxBytes $($h.MaxBytes) exceeds the 2 GB LOB limit, so the same profile cannot run down the Blob path" } }
Assert-Ok 'Write-FsPocWorkPlan renders' {
    Write-FsPocWorkPlan -Plan (Get-FsPocWorkPlan -TargetGB 5 -Profile Mixed -Threads 2) | Out-Null }
Assert-Ok 'Random pool is the right size and actually random' {
    $pool = New-FsPocRandomPool -SizeMB 8
    if ($pool.Length -ne 8MB) { throw "size $($pool.Length)" }
    $distinct = @($pool[0..4095] | Select-Object -Unique).Count
    if ($distinct -lt 200) { throw "only $distinct distinct byte values in the first 4 KB - not incompressible" } }

# ---------------------------------------------------------------------------
Write-Host ''
if ($script:Failures -eq 0) {
    Write-Host 'ALL CHECKS PASS' -ForegroundColor Green
    Write-Host 'Note: the SqlFileStream path is not covered here. Setup-FilestreamPoc.ps1' -ForegroundColor DarkGray
    Write-Host 'ends with a real 50 MB smoke test on the VM -- that is the one that matters.' -ForegroundColor DarkGray
    exit 0
}
Write-Host "$script:Failures CHECK(S) FAILED" -ForegroundColor Red
exit 1
