# Sets the console session's display scaling and reports the effective DPI
# (spec #32 W6), for the layout checks at 100, 125 and 150 %.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File display_scale.ps1 -Percent 150
#
# SSH sessions are not the console session, so the outer call runs itself as
# an Interactive RunLevel Limited task of the same user. The inner call sets
# the per-monitor scale live (SPI_SETLOGICALDPIOVERRIDE, the call Settings
# makes, relative to the recommended scale, 100 % on the seat's 1920x1080
# display) and checks the effective DPI from a per-monitor-aware process.
# Run with -Percent 100 to restore the seat's setting. Prints "scale <n>%".
param(
  [Parameter(Mandatory)][ValidateSet(100, 125, 150)][int]$Percent,
  [switch]$Inner,
  [string]$Out = 'C:\anj\evidence\w6\display-scale.txt'
)
$ErrorActionPreference = 'Stop'

if ($Inner) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AnjDpi {
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, int v, IntPtr p, uint f);
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(long pt, uint flags);
  [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
}
'@
  $steps = @{ 100 = 0; 125 = 1; 150 = 2 }
  if (-not [AnjDpi]::SystemParametersInfo(0x009F, $steps[$Percent], [IntPtr]::Zero, 1)) {
    throw 'SystemParametersInfo(SPI_SETLOGICALDPIOVERRIDE) failed'
  }
  Start-Sleep 2
  # A fresh per-monitor-aware process reads the effective DPI.
  $probe = {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AnjDpiProbe {
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr c);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(long pt, uint flags);
  [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr m, int type, out uint x, out uint y);
}
'@
    [AnjDpiProbe]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $m = [AnjDpiProbe]::MonitorFromPoint(0, 1)
    $x = 0; $y = 0
    [AnjDpiProbe]::GetDpiForMonitor($m, 0, [ref]$x, [ref]$y) | Out-Null
    $x
  }
  $dpi = powershell -NoProfile -Command $probe
  $effective = [math]::Round([int]$dpi * 100 / 96)
  "requested $Percent% effective dpi $dpi = $effective%" | Out-File -Encoding utf8 $Out
  exit ([int]($effective -ne $Percent))
}

New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
Remove-Item $Out -ErrorAction SilentlyContinue
$self = $MyInvocation.MyCommand.Path
$a = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Inner -Percent $Percent -Out `"$Out`""
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'anj-w6-scale' -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
try {
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w6-scale'
  Start-Sleep 2
  $deadline = (Get-Date).AddSeconds(60)
  while ((Get-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w6-scale').State -eq 'Running') {
    if ((Get-Date) -gt $deadline) { throw 'display scale task timed out' }
    Start-Sleep 1
  }
  $result = (Get-ScheduledTaskInfo -TaskPath '\anj\' -TaskName 'anj-w6-scale').LastTaskResult
  Get-Content $Out -ErrorAction SilentlyContinue
  if ($result -ne 0) { throw "display scale not applied (task result $result)" }
  "scale $Percent%"
} finally {
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w6-scale' -Confirm:$false -ErrorAction SilentlyContinue
  $s = New-Object -ComObject Schedule.Service; $s.Connect()
  try { $s.GetFolder('\').DeleteFolder('anj', 0) } catch {}
}
