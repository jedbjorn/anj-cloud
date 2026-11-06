# Desktop-session checks on the W10C-Testing console session (spec #32 W3,
# Acceptance row 11): elevated launch refused, single instance and
# activation, Close to the tray, tray menu commands, Explorer restart,
# session end, Quit releasing the profile lock. Runs from an elevated SSH
# session; every app launch is a one-shot Interactive, RunLevel Limited task
# in session 1, as the user starts it. The tray menu is driven by posting its
# command ids (desktop_integration.h) to the window, which is what the menu
# itself does. Screenshots are taken from the VM host between steps (-Pause).
param(
  [string]$Bundle = 'C:\anj\work\client\build\windows\x64\runner\Release',
  [string]$Profile = 'C:\anj\work\profile-w3',
  [string]$Evidence = 'C:\anj\evidence\w3',
  [int]$Pause = 0,
  [switch]$Inner
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Evidence | Out-Null

# Windows of the console session are invisible to this SSH session (another
# session and desktop), so the checks run there: as an Interactive task of
# the same user at RunLevel Highest (it registers the unelevated app
# launches and may post to their lower-integrity window).
if (-not $Inner) {
  # This SSH session's token is elevated with no filtered twin (as with UAC
  # off or the built-in Administrator): the refusal says such an account
  # cannot run the client at all.
  $exe = Join-Path $Bundle 'anj_cloud.exe'
  $env:ANJ_ELEVATION_NO_DIALOG = '1'
  $said = & cmd /d /c "`"$exe`" --profile-dir `"$Profile-ssh`" 2>&1"
  $code = $LASTEXITCODE
  Remove-Item Env:ANJ_ELEVATION_NO_DIALOG
  $line = '{0} elevated launch from SSH refused (exit {1}): {2}' -f $(if ($code -eq 77 -and "$said" -match 'normal Windows user') { 'PASS' } else { 'FAIL' }), $code, "$said"
  Write-Output $line
  Set-Content (Join-Path $Evidence 'session-ssh.txt') $line
  $out = Join-Path $Evidence 'session-inner.txt'
  Remove-Item $out -ErrorAction SilentlyContinue
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Inner -Bundle `"$Bundle`" -Profile `"$Profile`" -Evidence `"$Evidence`" -Pause $Pause"
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c powershell $arguments > `"$out`" 2>&1"
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName 'anj-w3-session' -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w3-session'
  $deadline = (Get-Date).AddSeconds(480)
  Start-Sleep 3
  while ((Get-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w3-session').State -eq 'Running' -and (Get-Date) -lt $deadline) {
    Start-Sleep 3
  }
  Get-Content $out -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w3-session' -Confirm:$false -ErrorAction SilentlyContinue
  Get-Process anj_cloud -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Remove-Item "$Profile-ssh" -Recurse -Force -ErrorAction SilentlyContinue
  $s = New-Object -ComObject Schedule.Service; $s.Connect()
  try { $s.GetFolder('\').DeleteFolder('anj', 0) } catch {}
  exit 0
}
$exe = Join-Path $Bundle 'anj_cloud.exe'
$results = New-Object System.Collections.Generic.List[string]
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  $line = '{0} {1}{2}' -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { " -- $detail" } else { '' })
  $results.Add($line); Write-Output $line
}
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
}
'@
function Window { [W]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'AnJ Cloud') }
function Procs { @(Get-Process anj_cloud -ErrorAction SilentlyContinue) }
$n = 0
function Launch([string]$extra = '') {
  $script:n++
  $log = Join-Path $Evidence "launch-$($script:n).txt"
  $cmd = "`"$exe`" --profile-dir `"$Profile`" $extra > `"$log`" 2>&1"
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c `"$cmd`"" -WorkingDirectory $Bundle
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  $name = "anj-w3-launch-$($script:n)"
  Register-ScheduledTask -TaskName $name -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName $name
  return $log
}
function Wait-Until([scriptblock]$condition, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) { if (& $condition) { return $true }; Start-Sleep -Milliseconds 300 }
  return [bool](& $condition)
}
# Winlogon restarts the shell by itself; if it did not, start it in the
# console session (never in this SSH session).
function Restore-Explorer {
  if (Wait-Until { Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 1 } } 15) { return }
  $a = New-ScheduledTaskAction -Execute 'explorer.exe'
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'anj-w3-explorer' -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w3-explorer'
  Start-Sleep 5
}
function Hold { if ($Pause) { Write-Output "HOLD $args"; Start-Sleep $Pause } }

try {
  Procs | Stop-Process -Force -ErrorAction SilentlyContinue
  if (Test-Path $Profile) { Remove-Item $Profile -Recurse -Force }

  # Elevated (this SSH session): refused with the reason, exit code 77.
  $env:ANJ_ELEVATION_NO_DIALOG = '1'
  $out = & cmd /d /c "`"$exe`" --profile-dir `"$Profile`" 2>&1"
  $code = $LASTEXITCODE
  Remove-Item Env:ANJ_ELEVATION_NO_DIALOG
  Check 'elevated launch refused (exit 77, reason given)' ($code -eq 77 -and "$out" -match 'normal Windows user') "exit $code; $out"
  Check 'elevated launch created no profile' (-not (Test-Path (Join-Path $Profile '.instance.lock')))

  # First launch, unelevated: the window appears and the tray icon is added.
  $log1 = Launch
  $up = Wait-Until { (Window) -ne [IntPtr]::Zero -and [W]::IsWindowVisible((Window)) } 40
  Start-Sleep 3
  Check 'first launch shows the window' $up
  Check 'one process' ((Procs).Count -eq 1) "$((Procs).Count)"
  Check 'tray icon added' ((Get-Content $log1 -Raw) -match 'tray icon added') (Get-Content $log1 -Raw)
  Hold 'first window'

  # Close hides to the tray; the process keeps running.
  [W]::PostMessage((Window), 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null  # WM_CLOSE
  $hidden = Wait-Until { -not [W]::IsWindowVisible((Window)) } 10
  Check 'Close hides the window to the tray' ($hidden -and (Procs).Count -eq 1)
  Hold 'hidden'

  # A second launch activates the first and exits.
  $log2 = Launch
  $shown = Wait-Until { [W]::IsWindowVisible((Window)) } 20
  Start-Sleep 2
  $second = Get-Content $log2 -Raw -ErrorAction SilentlyContinue
  Check 'second launch shows the running window' $shown
  Check 'second launch exits, still one process' ((Procs).Count -eq 1 -and $second -match 'already running') "$((Procs).Count); $second"
  Hold 'activated'

  # Tray menu: Pause then Resume, Open after a Close.
  [W]::PostMessage((Window), 0x0111, [IntPtr]1002, [IntPtr]::Zero) | Out-Null  # WM_COMMAND pause
  Start-Sleep 2
  Hold 'paused'
  [W]::PostMessage((Window), 0x0111, [IntPtr]1002, [IntPtr]::Zero) | Out-Null  # resume
  [W]::PostMessage((Window), 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
  Wait-Until { -not [W]::IsWindowVisible((Window)) } 10 | Out-Null
  [W]::PostMessage((Window), 0x0111, [IntPtr]1001, [IntPtr]::Zero) | Out-Null  # Open
  Check 'tray Open shows the window' (Wait-Until { [W]::IsWindowVisible((Window)) } 10)
  Check 'still running after Pause and Resume' ((Procs).Count -eq 1)

  # A shutdown cancelled after the query (WM_ENDSESSION FALSE): the client
  # carries on as before.
  $r = [IntPtr]::Zero
  [W]::SendMessageTimeout((Window), 0x0011, [IntPtr]::Zero, [IntPtr]::Zero, 2, 5000, [ref]$r) | Out-Null  # WM_QUERYENDSESSION
  [W]::SendMessageTimeout((Window), 0x0016, [IntPtr]::Zero, [IntPtr]::Zero, 2, 5000, [ref]$r) | Out-Null  # WM_ENDSESSION FALSE
  Start-Sleep 2
  [W]::PostMessage((Window), 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
  $hiddenAgain = Wait-Until { -not [W]::IsWindowVisible((Window)) } 10
  [W]::PostMessage((Window), 0x0111, [IntPtr]1001, [IntPtr]::Zero) | Out-Null
  $shownAgain = Wait-Until { [W]::IsWindowVisible((Window)) } 10
  Check 'a cancelled shutdown changes nothing (Close and Open still work)' ($hiddenAgain -and $shownAgain -and (Procs).Count -eq 1)

  # Explorer restart: the icon comes back (TaskbarCreated).
  Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq 1 } | Stop-Process -Force
  $readded = Wait-Until { (Get-Content $log1 -Raw) -match 're-added after Explorer restart' } 40
  Check 'tray icon re-added after an Explorer restart' $readded
  Restore-Explorer
  Hold 'after explorer restart'

  # Tray Quit: sync stops, the process exits and the lock is free.
  [W]::PostMessage((Window), 0x0111, [IntPtr]1003, [IntPtr]::Zero) | Out-Null  # Quit
  $gone = Wait-Until { (Procs).Count -eq 0 } 20
  Check 'tray Quit exits' $gone
  $free = $true
  try { [IO.File]::Open((Join-Path $Profile '.instance.lock'), 'Open', 'ReadWrite', 'None').Close() } catch { $free = $false }
  Check 'the profile lock is released after Quit' $free

  # Session end (WM_QUERYENDSESSION, WM_ENDSESSION): Quit's path runs before
  # the handler returns; Windows would then end the process.
  $log3 = Launch '--background'
  Wait-Until { (Window) -ne [IntPtr]::Zero } 40 | Out-Null
  Start-Sleep 6
  Check 'login start (--background) stays hidden with a tray' (-not [W]::IsWindowVisible((Window)) -and (Procs).Count -eq 1)
  # Restart Manager closing the app (ENDSESSION_CLOSEAPP): Quit's path runs
  # before the handler returns, then the client ends itself (Windows does
  # not), releasing the lock.
  $r = [IntPtr]::Zero
  [W]::SendMessageTimeout((Window), 0x0011, [IntPtr]::Zero, [IntPtr]1, 2, 5000, [ref]$r) | Out-Null  # WM_QUERYENDSESSION, ENDSESSION_CLOSEAPP
  $t0 = Get-Date
  [W]::SendMessageTimeout((Window), 0x0016, [IntPtr]1, [IntPtr]1, 2, 20000, [ref]$r) | Out-Null       # WM_ENDSESSION TRUE
  $ms = [int]((Get-Date) - $t0).TotalMilliseconds
  $exited = Wait-Until { (Procs).Count -eq 0 } 15
  $text = Get-Content $log3 -Raw
  Check 'session end stops sync before returning' ($text -match 'session end: sync stopped') "$ms ms"
  Check 'after session end the client exits by itself' $exited
  $free = $true
  try { [IO.File]::Open((Join-Path $Profile '.instance.lock'), 'Open', 'ReadWrite', 'None').Close() } catch { $free = $false }
  Check 'the profile lock is released after session end' $free
} finally {
  Procs | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-ScheduledTask -TaskPath '\anj\' -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -ne 'anj-w3-session' } | Unregister-ScheduledTask -Confirm:$false
  Restore-Explorer
  $results | Set-Content (Join-Path $Evidence 'session-results.txt')
  $fail = @($results | Where-Object { $_ -like 'FAIL*' }).Count
  "RESULT passed=$(@($results | Where-Object { $_ -like 'PASS*' }).Count) failed=$fail"
}
