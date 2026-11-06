# Idle CPU of the sync worker with the ReadDirectoryChangesW watcher against
# the per-pass stat scan (spec #32 File Watching), on the seat. One test file
# per mode (test/windows_idle_watcher_test.dart, test/windows_idle_scan_test.dart),
# run at once by one flutter test (--concurrency=2: one process per file, so
# each process's CPU is its mode's alone), unelevated in the console session.
# Needs the DLL from native_test.ps1 and its pub get.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File idle_cpu.ps1 -Seconds 600
param(
  [string]$Source = 'C:\anj\work\client',
  [string]$Dll = 'C:\anj\work\w2build\anj_rootfs_shipped.dll',
  [string]$Evidence = 'C:\anj\evidence\ww',
  [int]$Seconds = 600,
  # Test-only: after the calm pass, record every local scan as this long
  # (decision #146's cap on the seat without a huge root); 0 = measured.
  [int]$ScanMs = 0
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Evidence | Out-Null
if (-not (Test-Path $Dll)) { throw "missing $Dll (run native_test.ps1 first)" }
$flutter = 'C:\anj\toolchains\flutter-3.47.9\bin\flutter.bat'
$log = Join-Path $Evidence 'idle-run.txt'
Remove-Item $log -ErrorAction SilentlyContinue
$taskPath = '\anj\'
$name = 'anj-ww-idle'
$cmd = "set ANJ_ROOTFS_LIBRARY=$Dll&& set ANJ_WW_IDLE_SECONDS=$Seconds&& set ANJ_WW_IDLE_SCAN_MS=$ScanMs&& set FLUTTER_SUPPRESS_ANALYTICS=true&& " +
  "call `"$flutter`" --suppress-analytics test --no-pub --concurrency=2 " +
  "test/windows_idle_watcher_test.dart test/windows_idle_scan_test.dart > `"$log`" 2>&1"
$a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c `"$cmd`"" -WorkingDirectory $Source
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds ($Seconds + 900))
Register-ScheduledTask -TaskName $name -TaskPath $taskPath -Action $a -Principal $p -Settings $s -Force | Out-Null
try {
  Start-ScheduledTask -TaskPath $taskPath -TaskName $name
  $deadline = (Get-Date).AddSeconds($Seconds + 840)
  Start-Sleep 5
  while ((Get-ScheduledTask -TaskPath $taskPath -TaskName $name).State -in 'Running', 'Queued') {
    if ((Get-Date) -gt $deadline) { Stop-ScheduledTask -TaskPath $taskPath -TaskName $name; 'TIMEOUT'; break }
    Start-Sleep 10
  }
  $result = (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $name).LastTaskResult
  if (Test-Path $log) { Get-Content $log | Select-String -Pattern 'WW idle|WW pass|\[E\]|All tests passed|Some tests failed|Expected|Actual' }
  "idle task result $result"
  if ($result -ne 0) { exit 1 }
} finally {
  Unregister-ScheduledTask -TaskPath $taskPath -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
  Get-Process flutter_tester -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  $sched = New-Object -ComObject Schedule.Service; $sched.Connect()
  try { $sched.GetFolder('\').DeleteFolder('anj', 0) } catch {}
}
