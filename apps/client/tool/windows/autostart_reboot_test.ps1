# Start-at-login and SmartScreen checks on W10C-Testing (spec #32 W5,
# Acceptance row 13), in phases around a guest reboot (auto-logon):
#   -Phase install      install the deflated archive, autostart on (default)
#   (VM host: windows_seat.sh ssh "shutdown /r /t 0", wait for SSH)
#   -Phase check        after login: the client runs, hidden, in session 1
#   -Phase smartscreen  a copy of the manager marked as downloaded from the
#                       Internet (Zone.Identifier ZoneId=3) is started; the VM host
#                       takes the screenshot
#   -Phase clean        uninstall and remove the test copies
# Each phase runs as an Interactive RunLevel Limited task (the manager
# refuses elevation; SSH sessions are elevated).
param(
  [Parameter(Mandatory)][ValidateSet('install', 'check', 'smartscreen', 'clean')][string]$Phase,
  [string]$Dist = 'C:\anj\work\w5-dist',
  [string]$Evidence = 'C:\anj\evidence\w5',
  [switch]$Inner
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Evidence | Out-Null
if (-not $Inner) {
  $out = Join-Path $Evidence "reboot-$Phase.txt"
  Remove-Item $out -ErrorAction SilentlyContinue
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Inner -Phase $Phase -Dist `"$Dist`" -Evidence `"$Evidence`""
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c powershell $arguments > `"$out`" 2>&1"
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName "anj-w5-$Phase" -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName "anj-w5-$Phase"
  $deadline = (Get-Date).AddSeconds(240)
  Start-Sleep 3
  while ((Get-ScheduledTask -TaskPath '\anj\' -TaskName "anj-w5-$Phase").State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep 2 }
  Get-Content $out -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName "anj-w5-$Phase" -Confirm:$false -ErrorAction SilentlyContinue
  $s = New-Object -ComObject Schedule.Service; $s.Connect()
  try { $s.GetFolder('\').DeleteFolder('anj', 0) } catch {}
  exit 0
}
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
}
'@
function Say([string]$name, [bool]$ok, [string]$detail = '') {
  '{0} {1}{2}' -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { " -- $detail" } else { '' })
}
$base = Join-Path $env:LOCALAPPDATA 'Programs\anj-cloud'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
switch ($Phase) {
  'install' {
    if (Test-Path $base) { throw 'an installation already exists' }
    $zip = Get-ChildItem $Dist -Filter 'anj-cloud-*-windows-x86_64.zip' | Select-Object -First 1
    $sha = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLower()
    $unpacked = Join-Path $Dist 'unpacked'
    if (Test-Path $unpacked) { Remove-Item $unpacked -Recurse -Force }
    New-Item -ItemType Directory $unpacked | Out-Null
    tar.exe -xf $zip.FullName -C $unpacked
    $manager = (Get-ChildItem $unpacked -Recurse -Filter 'anj-cloud-manager.exe' | Select-Object -First 1).FullName
    $p = Start-Process $manager -ArgumentList @('install', $zip.FullName, '--sha256', $sha) -Wait -PassThru -NoNewWindow
    $run = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).'AnJ Cloud'
    Say 'installed with autostart on' ($p.ExitCode -eq 0 -and $run -like '*--background*') "$run"
  }
  'check' {
    $up = $false
    for ($i = 0; $i -lt 60 -and -not $up; $i++) { $up = [bool](Get-Process anj_cloud -ErrorAction SilentlyContinue); if (-not $up) { Start-Sleep 2 } }
    Start-Sleep 5
    $proc = Get-Process anj_cloud -ErrorAction SilentlyContinue
    $window = [W]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'AnJ Cloud')
    Say 'after reboot the client started at login' ($up -and $proc.SessionId -eq 1) "session $($proc.SessionId)"
    Say 'it started hidden (in the tray)' ($window -ne [IntPtr]::Zero -and -not [W]::IsWindowVisible($window))
  }
  'smartscreen' {
    $copy = Join-Path $Dist 'downloaded\anj-cloud-manager.exe'
    New-Item -ItemType Directory -Force (Split-Path $copy) | Out-Null
    Copy-Item (Get-ChildItem (Join-Path $Dist 'unpacked') -Recurse -Filter 'anj-cloud-manager.exe' | Select-Object -First 1).FullName $copy -Force
    Set-Content -Path $copy -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
    $installed = Get-ChildItem $base -Recurse -Filter 'anj_cloud.exe' | Select-Object -First 1
    $motw = Get-Item $installed.FullName -Stream Zone.Identifier -ErrorAction SilentlyContinue
    Say 'files the manager installed carry no Mark of the Web' (-not $motw)
    Start-Process explorer.exe $copy
    Start-Sleep 8
    Say 'a Mark-of-the-Web copy was started for the SmartScreen capture' $true
  }
  'clean' {
    Get-Process anj_cloud -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
    $manager = Get-ChildItem $base -Recurse -Filter 'anj-cloud-manager.exe' | Select-Object -First 1
    if ($manager) { Start-Process $manager.FullName -ArgumentList 'uninstall' -Wait -NoNewWindow }
    for ($i = 0; $i -lt 30 -and (Test-Path $base); $i++) { Start-Sleep 1 }
    Say 'uninstalled' (-not (Test-Path $base) -and -not (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).'AnJ Cloud')
    Get-Process smartscreen -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($path in (Join-Path $env:LOCALAPPDATA 'anj-cloud'), (Join-Path $Dist 'downloaded')) {
      if (Test-Path $path) { Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
}
