@echo off
REM  00-set-variables.cmd
REM
REM  Sets the sqlcmd scripting variables as ENVIRONMENT variables, so the SQL
REM  scripts in this kit can be run by hand without typing -v for each one.
REM  sqlcmd falls back to the environment for any scripting variable that was
REM  not supplied with -v.
REM
REM  The PowerShell scripts pass -v explicitly and do not need this.
REM
REM  Usage:
REM      sql\00-set-variables.cmd
REM      sqlcmd -S . -E -b -i sql\02-create-database.sql
REM
REM  Edit these to match ps\FsPocConfig.psd1 -- they are not read from it.

set DbName=FsPocDemo
set MonitorDb=FsPocMonitor
set TargetDb=FsPocDemo
set DirectoryName=FsPocDemo

set DataPath=F:\SQLData
set LogPath=H:\SQLLog
set FsPath=G:\FilestreamData
set FsPath2=
set XePath=H:\XEvents

set MonitorDataPath=%DataPath%
set MonitorLogPath=%LogPath%

set SessionName=FsPoc_Waits
set MinWaitMs=10
set TargetGB=200
set TopWaits=25
set RunId=
set Mode=drop

echo FILESTREAM POC sqlcmd variables set for this shell:
echo   DbName=%DbName%  MonitorDb=%MonitorDb%
echo   DataPath=%DataPath%  LogPath=%LogPath%  FsPath=%FsPath%  XePath=%XePath%
