# Runs test/windows_sync_e2e_test.dart unelevated in the console session for
# deploy/windows_sync_fixture.py: an Interactive RunLevel
# Limited task of the same user, against the anj_rootfs.dll that
# native_test.ps1 built. Prints the test log.
param(
  [string]$Source = 'C:\anj\work\client',
  [string]$Config = 'C:\anj\work\w4\config.json',
  [string]$Dll = 'C:\anj\work\w2build\anj_rootfs.dll',
  [string]$Log = 'C:\anj\evidence\w4\e2e-run.txt',
  [int]$Timeout = 840
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null
if (-not (Test-Path $Dll)) { throw "build anj_rootfs.dll first (native_test.ps1): $Dll" }
$flutter = 'C:\anj\toolchains\flutter-3.47.9\bin\flutter.bat'
$cmd = "set ANJ_W4_CONFIG=$Config&& set ANJ_ROOTFS_LIBRARY=$Dll&& set FLUTTER_SUPPRESS_ANALYTICS=true&& " +
  "call `"$flutter`" --suppress-analytics test --no-pub test/windows_sync_e2e_test.dart > `"$Log`" 2>&1"
$a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c `"$cmd`"" -WorkingDirectory $Source
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'anj-w4-e2e' -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
try {
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w4-e2e'
  $deadline = (Get-Date).AddSeconds($Timeout)
  Start-Sleep 3
  while ((Get-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w4-e2e').State -eq 'Running') {
    if ((Get-Date) -gt $deadline) { Stop-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w4-e2e'; 'TIMEOUT'; break }
    Start-Sleep 3
  }
  Get-Content $Log -ErrorAction SilentlyContinue
} finally {
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w4-e2e' -Confirm:$false -ErrorAction SilentlyContinue
  $s = New-Object -ComObject Schedule.Service; $s.Connect()
  try { $s.GetFolder('\').DeleteFolder('anj', 0) } catch {}
}
