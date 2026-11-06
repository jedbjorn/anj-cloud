# Launches the built client in the seat's console session (spec #32 W0).
#
# SSH sessions are not the desktop: the app is started by a one-shot
# Interactive scheduled task, unelevated (RunLevel Limited), in the auto-logon
# session, with stdout and stderr captured. Capture the screen from the VM host with
# `virsh screenshot` while it runs, then call with -Action stop, which ends
# the process and removes the task and the \anj\ task folder.
param(
  [ValidateSet('start', 'stop')][string]$Action = 'start',
  [string]$Bundle = 'C:\anj\work\client\build\windows\x64\runner\Release',
  [string]$ProfileDir = 'C:\anj\work\profile-w0',
  [string]$Evidence = 'C:\anj\evidence\w0',
  [int]$Wait = 15
)
$ErrorActionPreference = 'Stop'
$task = 'anj-client-launch'
New-Item -ItemType Directory -Force $Evidence | Out-Null

if ($Action -eq 'start') {
  $log = Join-Path $Evidence 'app-output.txt'
  $cmd = "`"$Bundle\anj_cloud.exe`" --profile-dir `"$ProfileDir`" > `"$log`" 2>&1"
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c `"$cmd`"" -WorkingDirectory $Bundle
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $task -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName $task
  Start-Sleep $Wait
  $procs = Get-Process anj_cloud -ErrorAction SilentlyContinue
  if (-not $procs) { Write-Output 'anj_cloud is not running'; Get-Content $log -ErrorAction SilentlyContinue; exit 1 }
  $report = foreach ($proc in $procs) {
    $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)" | Invoke-CimMethod -MethodName GetOwner
    [pscustomobject]@{
      Id = $proc.Id; SessionId = $proc.SessionId; MainWindowTitle = $proc.MainWindowTitle
      Responding = $proc.Responding; StartTime = $proc.StartTime
      Owner = "$($owner.Domain)\$($owner.User)"; WorkingSetMB = [math]::Round($proc.WorkingSet64 / 1MB)
    }
  }
  $report | Format-List | Out-String | Tee-Object -FilePath (Join-Path $Evidence 'app-process.txt')
} else {
  Get-Process anj_cloud -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 1
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  $s = New-Object -ComObject Schedule.Service; $s.Connect()
  try { $s.GetFolder('\').DeleteFolder('anj', 0) } catch {}
  $left = [pscustomobject]@{
    process = [bool](Get-Process anj_cloud -ErrorAction SilentlyContinue)
    task = [bool](Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)
  }
  "process left: $($left.process)"; "task left: $($left.task)"
  if ($left.process -or $left.task) { exit 1 }
}
