# Runs integration_test/windows_admin_test.dart in the real Windows app,
# unelevated in the console session, for deploy/windows_admin_fixture.py
# an Interactive RunLevel Limited task of the same user. The
# app builds with the seat's toolchain (build.ps1) on first use. Prints the
# test log, then "W6 TASK RESULT <n>" (the task's own exit code). The log is
# removed first, so a task that never runs leaves no earlier run's PASS; the
# script exits 1 unless the task ran to completion with result 0.
param(
  [string]$Source = 'C:\anj\work\client',
  [string]$Config = 'C:\anj\work\w6\config.json',
  [string]$Log = 'C:\anj\evidence\w6\admin-run.txt',
  [int]$Timeout = 1500
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null
# Never an earlier run's log: only this run's task may write it.
Remove-Item $Log -Force -ErrorAction SilentlyContinue
if (Test-Path $Log) { throw "cannot clear the previous log $Log" }
$flutter = 'C:\anj\toolchains\flutter-3.47.9\bin\flutter.bat'
# Plugin symlinks (windows\flutter\ephemeral\.plugin_symlinks) need
# elevation or Developer Mode on Windows: this SSH session is elevated, so
# pub get makes them here; the unelevated build below only reads them.
$env:PUB_CACHE = 'C:\anj\pub-cache'
Push-Location $Source
try {
  & $flutter --suppress-analytics pub get --enforce-lockfile 2>&1 | Out-File -Encoding utf8 (Join-Path (Split-Path $Log) 'pub-get.txt')
  if ($LASTEXITCODE -ne 0) { Get-Content (Join-Path (Split-Path $Log) 'pub-get.txt') -Tail 20; throw 'pub get failed' }
} finally { Pop-Location }
$cmd = "set ANJ_W6_CONFIG=$Config&& set PUB_CACHE=C:\anj\pub-cache&& set FLUTTER_SUPPRESS_ANALYTICS=true&& " +
  "call `"$flutter`" --suppress-analytics test --no-pub -d windows integration_test/windows_admin_test.dart > `"$Log`" 2>&1"
$a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c `"$cmd`"" -WorkingDirectory $Source
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($Timeout + 60))
Register-ScheduledTask -TaskName 'anj-w6-admin' -TaskPath '\anj\' -Action $a -Principal $p -Settings $s -Force | Out-Null
$timedOut = $false
try {
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w6-admin'
  $deadline = (Get-Date).AddSeconds($Timeout)
  Start-Sleep 3
  # Queued counts as not yet finished: the loop ends only once it ran.
  while ((Get-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w6-admin').State -in 'Running', 'Queued') {
    if ((Get-Date) -gt $deadline) { Stop-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w6-admin'; 'TIMEOUT'; $timedOut = $true; break }
    Start-Sleep 3
  }
  # 267011 (SCHED_S_TASK_HAS_NOT_RUN) and 267009 (still running) are not 0.
  $result = (Get-ScheduledTaskInfo -TaskPath '\anj\' -TaskName 'anj-w6-admin').LastTaskResult
  if (Test-Path $Log) { Get-Content $Log } else { 'W6 NO LOG: the task wrote nothing' }
  "W6 TASK RESULT $result"
} finally {
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w6-admin' -Confirm:$false -ErrorAction SilentlyContinue
  Get-Process anj_cloud -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  $sched = New-Object -ComObject Schedule.Service; $sched.Connect()
  try { $sched.GetFolder('\').DeleteFolder('anj', 0) } catch {}
}
if ($timedOut -or $result -ne 0 -or -not (Test-Path $Log)) { exit 1 }
