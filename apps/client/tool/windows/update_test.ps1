# In-app update checks on a Windows seat: the manager's apply-update against
# the real profile lock, registry and process model. It installs an older
# release, stages a newer one as the app would (archive and signed manifest
# in <profile>\updates) and checks: the read-only check, tampered and
# foreign-signed downloads, a hand-over while the app keeps running (nothing
# installed or published, the app is started again once it quits), a second
# hand-over at the same time, the app started again by someone else, another
# manager command holding the transaction, a stage left by a killed manager,
# and the update itself (installed after Quit, previous release kept, the
# new release started, download discarded).
#
# -Dist holds, made on the build host:
#   old.zip            the installed release (package.ps1 with a version)
#   new.zip            a newer release trusting the same key
#   new.json           its signed manifest (deploy/release.py publish prints it)
#   new-otherkey.json  the same manifest signed by another key
# The manager refuses elevation and SSH sessions are elevated, so the checks
# run as an Interactive RunLevel Limited task in the console session (-Inner).
# It refuses to run when an installation already exists and removes only what
# it created. -UnusualLocal runs everything with LOCALAPPDATA at a path with
# a space and non-ASCII letters (the installation and the profile follow it).
param(
  [string]$Dist = 'C:\anj\work\update-dist',
  [string]$Evidence = 'C:\anj\evidence\update',
  [switch]$UnusualLocal,
  [switch]$Inner
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Evidence | Out-Null

if (-not $Inner) {
  $out = Join-Path $Evidence 'update-inner.txt'
  Remove-Item $out -ErrorAction SilentlyContinue
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Inner -Dist `"$Dist`" -Evidence `"$Evidence`"$(if ($UnusualLocal) { ' -UnusualLocal' })"
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c powershell $arguments > `"$out`" 2>&1"
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'anj-update-test' -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-update-test'
  $deadline = (Get-Date).AddSeconds(1200)
  Start-Sleep 3
  while ((Get-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-update-test').State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep 3 }
  Get-Content $out -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-update-test' -Confirm:$false -ErrorAction SilentlyContinue
  Get-Process anj_cloud, anj-cloud-manager -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  $s = New-Object -ComObject Schedule.Service; $s.Connect()
  try { $s.GetFolder('\').DeleteFolder('anj', 0) } catch {}
  exit 0
}

$results = New-Object System.Collections.Generic.List[string]
if ($UnusualLocal) {
  # "Local Däta ā" without a non-ASCII byte in this file.
  $env:LOCALAPPDATA = "C:\anj\work\Local D$([char]0xE4)ta $([char]0x101)"
  New-Item -ItemType Directory -Force $env:LOCALAPPDATA | Out-Null
}
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  $line = '{0} {1}{2}' -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { " -- $detail" } else { '' })
  $results.Add($line); Write-Output $line
}
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
// A process as the app starts its manager for the hand-over: DETACHED_PROCESS
// and no handle inheritance, so no console and no standard handles.
public static class Detached {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct SI { public int cb; public string r, d, t; public int x, y, xs, ys, xc, yc, fa, flags; public short sw, cb2; public IntPtr r2, i, o, e; }
  [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr p, t; public int pid, tid; }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref SI si, out PI pi);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  public static string Run(string commandLine, uint waitMs) {
    var si = new SI(); si.cb = Marshal.SizeOf(typeof(SI)); PI pi;
    if (!CreateProcessW(null, new System.Text.StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, 0x8, IntPtr.Zero, null, ref si, out pi)) return "CreateProcess failed " + Marshal.GetLastWin32Error();
    if (WaitForSingleObject(pi.p, waitMs) != 0) return "still running after " + waitMs + " ms";
    uint code; GetExitCodeProcess(pi.p, out code); return "exit code " + code;
  }
}
'@
function Wait-Until([scriptblock]$condition, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) { if (& $condition) { return $true }; Start-Sleep -Milliseconds 300 }
  return [bool](& $condition)
}
function Quoted([string[]]$arguments) { $arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } } }
function Manager([string]$exe, [string[]]$arguments) {
  $outFile = Join-Path $Evidence 'last-out.txt'; $errFile = Join-Path $Evidence 'last-err.txt'
  # Not -Wait: it also waits for descendants, and apply-update starts the app.
  $p = Start-Process $exe -ArgumentList (Quoted $arguments) -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
  $null = $p.Handle
  if (-not $p.WaitForExit(300000)) { $p.Kill(); throw "the manager did not end: $arguments" }
  $p.WaitForExit()
  [pscustomobject]@{ code = $p.ExitCode; out = (Get-Content $outFile -Raw); err = (Get-Content $errFile -Raw) }
}
$base = Join-Path $env:LOCALAPPDATA 'Programs\anj-cloud'
$profile = Join-Path $env:LOCALAPPDATA 'anj-cloud\profile'
$updates = Join-Path $profile 'updates'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\AnJ Cloud.lnk'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AnJ Cloud'
function RunValue { (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).'AnJ Cloud' }
function Active { Get-Content (Join-Path $base 'active.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Window { [W]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'AnJ Cloud') }
function Running { @(Get-Process anj_cloud -ErrorAction SilentlyContinue) }
# The tray's Quit, as a person would choose it.
# True once that very process has ended (a waiting manager may start the
# app again at once).
function Quit-Client {
  $ids = @(Running | ForEach-Object Id)
  [W]::PostMessage((Window), 0x0111, [IntPtr]1003, [IntPtr]::Zero) | Out-Null
  Wait-Until { -not (Get-Process -Id $ids -ErrorAction SilentlyContinue) } 30
}
function Start-Client([string]$exe) {
  Start-Process $exe
  $shown = Wait-Until { (Window) -ne [IntPtr]::Zero } 40
  Start-Sleep 4
  $shown
}

try {
  if ((Test-Path $base) -or (RunValue) -or (Test-Path $uninstallKey) -or (Test-Path (Join-Path $env:LOCALAPPDATA 'anj-cloud'))) {
    throw 'an installation or a profile already exists; not touching it'
  }
  $old = Join-Path $Dist 'old.zip'; $new = Join-Path $Dist 'new.zip'
  $manifest = Get-Content (Join-Path $Dist 'new.json') -Raw | ConvertFrom-Json
  $code = $manifest.version_code
  $unpacked = Join-Path $Dist 'unpacked'
  if (Test-Path $unpacked) { Remove-Item $unpacked -Recurse -Force }
  New-Item -ItemType Directory $unpacked | Out-Null
  tar.exe -xf $old -C $unpacked
  $bootstrap = (Get-ChildItem $unpacked -Recurse -Filter 'anj-cloud-manager.exe' | Select-Object -First 1).FullName

  $r = Manager $bootstrap @('install', $old, '--sha256', (Get-FileHash $old -Algorithm SHA256).Hash.ToLower())
  Check 'install the older release' ($r.code -eq 0) "$($r.err)"
  $first = Active
  $releaseA = Join-Path $base "releases\$($first.release)"
  $clientA = Join-Path $releaseA 'anj_cloud.exe'
  $managerA = Join-Path $releaseA 'anj-cloud-manager.exe'
  $receipt = Get-Content (Join-Path $releaseA 'bundle-receipt.json') -Raw | ConvertFrom-Json
  Check 'the installed receipt carries its version' ($receipt.version_code -ge 1 -and $receipt.version_code -lt $code -and $receipt.version) "$($receipt.version) ($($receipt.version_code))"
  Check 'the installed release carries a release key' (Test-Path (Join-Path $releaseA 'data\flutter_assets\assets\release\household-release-key.pub'))

  # Without anywhere to print, the exit code is still the command's.
  $quote = [char]34
  $silent = [Detached]::Run($quote + $managerA + $quote + ' status', 30000)
  Check 'started detached without standard handles, a command that succeeds exits 0' ($silent -eq 'exit code 0') $silent
  $silent = [Detached]::Run($quote + $managerA + $quote + ' no-such-command', 30000)
  Check 'and a refused one exits 1' ($silent -eq 'exit code 1') $silent

  # The app's download: <profile>\updates\<code>.tar.gz and <code>.json.
  $archive = Join-Path $updates "$code.tar.gz"; $record = Join-Path $updates "$code.json"; $result = Join-Path $updates 'result.json'
  function Stage([string]$manifestFile = 'new.json') {
    New-Item -ItemType Directory -Force $updates | Out-Null
    Remove-Item (Join-Path $updates '*') -Force -ErrorAction SilentlyContinue
    Copy-Item $new $archive
    Copy-Item (Join-Path $Dist $manifestFile) $record
  }
  function Outcome { if (Test-Path $result) { Get-Content $result -Raw | ConvertFrom-Json } }
  # A hand-over as the app starts it: not waited for. Its printed outcome is
  # read afterwards (the restarted app reads and removes result.json at once).
  $handoverOut = Join-Path $Evidence 'handover-out.txt'
  function Hand-Over([int]$appPid = 0) {
    Remove-Item $handoverOut -ErrorAction SilentlyContinue
    if (-not $appPid) { $appPid = (Running)[0].Id }
    $p = Start-Process $managerA -ArgumentList (Quoted ($applyArgs + @('--result', $result, '--app-pid', "$appPid"))) -PassThru -WindowStyle Hidden -RedirectStandardOutput $handoverOut
    $null = $p.Handle
    $p
  }
  function Printed([string]$text) { if ($text) { $text | ConvertFrom-Json } }
  function Releases { @(Get-ChildItem (Join-Path $base 'releases') -Force | ForEach-Object Name) }
  $applyArgs = @('apply-update', $archive, '--manifest', $record)

  Stage
  $r = Manager $managerA ($applyArgs + '--check')
  Check 'check accepts the signed newer release' ($r.code -eq 0 -and $r.out -match "`"version_code`": $code") "$($r.err)"
  Check 'check changes nothing' ((Active).release -eq $first.release -and (Test-Path $archive) -and (Test-Path $record))
  # The app passes its paths with forward slashes after the profile.
  $r = Manager $managerA @('apply-update', "$updates/$code.tar.gz", '--manifest', "$updates/$code.json", '--check')
  Check 'check accepts the paths as the app writes them' ($r.code -eq 0) "$($r.err)"

  Stage 'new-otherkey.json'
  $r = Manager $managerA ($applyArgs + '--check')
  Check 'a manifest signed by another key is refused' ($r.code -eq 1 -and $r.err -match 'anj-cloud-manager: .*(signature does not verify|different key)') "$($r.err)"

  Stage
  Copy-Item $new (Join-Path $Dist 'outside.zip')
  $r = Manager $managerA @('apply-update', (Join-Path $Dist 'outside.zip'), '--manifest', $record, '--check')
  Check 'a download outside the profile is refused' ($r.code -eq 1 -and $r.err -match 'updates folder') "$($r.err)"
  Remove-Item (Join-Path $Dist 'outside.zip')

  # Corrupted after the app's check: the hand-over refuses, answers and starts the app again.
  Stage
  $bytes = [IO.File]::ReadAllBytes($archive); $bytes[100] = $bytes[100] -bxor 1; [IO.File]::WriteAllBytes($archive, $bytes)
  $r = Manager $managerA ($applyArgs + @('--result', $result))
  $outcome = Printed $r.out
  Check 'a corrupted download is not installed' ($r.code -eq 1 -and (Active).release -eq $first.release -and $outcome.ok -eq $false -and $outcome.message -match 'signed size and SHA-256') "$($outcome.message)"
  Check 'the refused download is discarded' (-not (Test-Path $archive) -and -not (Test-Path $record))
  $back = Wait-Until { (Window) -ne [IntPtr]::Zero } 40
  Check 'the release that was running is started again' ($outcome.relaunched -eq $true -and $back -and (Running)[0].Path -eq $clientA) "$((Running | ForEach-Object Path) -join ', ')"
  Start-Sleep 4
  Check 'tray Quit ends it' (Quit-Client)

  # The app keeps running: nothing is installed, or even published, while
  # it holds the profile.
  Check 'the installed client starts' (Start-Client $clientA)
  Stage
  $handover = Hand-Over
  Start-Sleep 6
  Check 'no update while AnJ Cloud runs' ((Active).release -eq $first.release -and -not $handover.HasExited)
  Check 'no release is published while it runs' (@(Releases | Where-Object { $_ -notlike '.*' }).Count -eq 1) "$((Releases) -join ', ')"
  $r = Manager $managerA ($applyArgs + @('--result', $result))
  Check 'a second hand-over at the same time changes nothing' ($r.code -eq 1 -and $r.out -match 'Another update is already being applied' -and (Test-Path $archive) -and -not (Test-Path $result)) "$($r.out) $($r.err)"
  $refused = Wait-Until { Test-Path $result } 150
  $outcome = Outcome
  Check 'after two minutes the hand-over gives up' ($refused -and $outcome.ok -eq $false -and $outcome.message -match 'did not quit in time' -and (Active).release -eq $first.release) "$($outcome.message)"
  Check 'its download is discarded' (-not (Test-Path $archive) -and -not (Test-Path $record))
  Check 'the manager still waits to start the app again' (-not $handover.HasExited)
  Check 'tray Quit ends the app' (Quit-Client)
  $back = Wait-Until { (Window) -ne [IntPtr]::Zero -and $handover.HasExited } 60
  Check 'the app is started again on its own release' ($back -and (Running)[0].Path -eq $clientA)
  Check 'its stage is gone' (-not (Releases | Where-Object { $_ -like '.update-*' })) "$((Releases) -join ', ')"
  Start-Sleep 4

  # Started again by someone else: the process that handed over is gone and
  # another instance holds the profile. Given up at once; that instance's
  # folder is not touched and nothing more is started.
  Stage
  $gone = Start-Process cmd.exe -ArgumentList '/d', '/c', 'exit' -PassThru -WindowStyle Hidden
  $gone.WaitForExit()
  $instance = (Running)[0].Id
  $handover = Hand-Over $gone.Id
  $quick = $handover.WaitForExit(20000)
  $outcome = Printed (Get-Content $handoverOut -Raw -ErrorAction SilentlyContinue)
  Check 'an app started again abandons the update at once' ($quick -and $handover.ExitCode -eq 1 -and $outcome.started_again -eq $true -and (Active).release -eq $first.release) "$($outcome.message)"
  Check 'that instance keeps its download, gets no result and stays the only one' ((Test-Path $archive) -and (Test-Path $record) -and -not (Test-Path $result) -and (Running).Count -eq 1 -and (Running)[0].Id -eq $instance)
  Check 'tray Quit ends it again' (Quit-Client)

  # Another manager command holds the transaction for a while: the update
  # waits for it. A stage a killed manager left behind is swept on the way.
  Stage
  $stale = Join-Path $base 'releases\.update-left-behind'
  New-Item -ItemType Directory -Force (Join-Path $stale 'payload') | Out-Null
  Set-Content (Join-Path $stale 'payload\big.bin') 'x'
  $held = [IO.File]::Open((Join-Path $env:LOCALAPPDATA 'Programs\.anj-cloud-transaction.lock'), 'OpenOrCreate', 'ReadWrite', 'ReadWrite')
  $held.Lock(0, [long]::MaxValue)
  $started = Get-Date
  $handover = Start-Process $managerA -ArgumentList (Quoted ($applyArgs + @('--result', $result))) -PassThru -WindowStyle Hidden -RedirectStandardOutput $handoverOut
  $null = $handover.Handle
  Start-Sleep 5
  Check 'the update waits while another manager command runs' ((Active).release -eq $first.release -and -not $handover.HasExited)
  $held.Unlock(0, [long]::MaxValue); $held.Close()
  $done = $handover.WaitForExit(60000)
  $outcome = Printed (Get-Content $handoverOut -Raw -ErrorAction SilentlyContinue)
  $second = Active
  Check 'and installs once it ends' ($done -and $handover.ExitCode -eq 0 -and $outcome.ok -eq $true -and $second.release -ne $first.release -and ((Get-Date) - $started).TotalSeconds -ge 5) "$($outcome.message)"
  Check 'the stage left behind is swept' (-not (Test-Path $stale) -and -not (Releases | Where-Object { $_ -like '.*' })) "$((Releases) -join ', ')"
  $clientB = Join-Path $base "releases\$($second.release)\anj_cloud.exe"
  $managerB = Join-Path $base "releases\$($second.release)\anj-cloud-manager.exe"
  $back = Wait-Until { (Window) -ne [IntPtr]::Zero } 40
  Check 'the new release is started' ($outcome.relaunched -eq $true -and $back -and (Running)[0].Path -eq $clientB) "$((Running | ForEach-Object Path) -join ', ')"
  Start-Sleep 4
  Check 'tray Quit ends the new release' (Quit-Client)

  # Back to the older release by hand (the manager's own update), for the
  # update as the app does it: handed over while it runs, installed once it
  # has quit.
  $r = Manager $managerB @('update', $old, '--sha256', (Get-FileHash $old -Algorithm SHA256).Hash.ToLower())
  Check 'the manual update still installs any archive by its SHA-256' ($r.code -eq 0 -and (Active).release -eq $first.release) "$($r.err)"
  Check 'the installed client starts again' (Start-Client $clientA)
  Stage
  $handover = Hand-Over
  Start-Sleep 6
  Check 'still the older release while it runs' ((Active).release -eq $first.release)
  Check 'tray Quit ends the app for the update' (Quit-Client)
  $done = $handover.WaitForExit(120000)
  $outcome = Printed (Get-Content $handoverOut -Raw -ErrorAction SilentlyContinue)
  $third = Active
  Check 'the update is installed after Quit' ($done -and $handover.ExitCode -eq 0 -and $outcome.ok -eq $true -and $outcome.version_code -eq $code -and $outcome.relaunched -eq $true -and $third.release -eq $second.release) "$($outcome.message)"
  Check 'the previous release is kept and recorded' ($third.previous -eq $first.release -and (Test-Path $clientA))
  $back = Wait-Until { (Window) -ne [IntPtr]::Zero } 40
  Check 'the new release is started after Quit' ($back -and (Running)[0].Path -eq $clientB) "$((Running | ForEach-Object Path) -join ', ')"
  Check 'the profile is the same one' ($third.profile -eq $profile -and (Test-Path $profile))
  Check 'the download is discarded' (-not (Test-Path $archive) -and -not (Test-Path $record))
  Check 'Run value and shortcut follow the update' ((RunValue) -eq "`"$clientB`" --background" -and (Test-Path $shortcut))
  $newReceipt = Get-Content (Join-Path $base "releases\$($third.release)\bundle-receipt.json") -Raw | ConvertFrom-Json
  Check 'the active receipt is the new version' ($newReceipt.version_code -eq $code) "$($newReceipt.version)"
  Start-Sleep 4
  Check 'tray Quit ends the new release again' (Quit-Client)

  # Replay: the same release again is not newer.
  Stage
  $r = Manager $managerB ($applyArgs + '--check')
  Check 'the installed version is not offered again' ($r.code -eq 1 -and $r.err -match 'not newer') "$($r.err)"
  Copy-Item (Join-Path $base 'active.json') (Join-Path $Evidence 'active-after.json')
  Copy-Item (Join-Path $base 'manager.jsonl') (Join-Path $Evidence 'manager.jsonl')
} catch {
  Check 'update test ran to the end' $false "$_"
} finally {
  Get-Process anj_cloud, anj-cloud-manager -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep 1
  # Test cleanup only: what this run created.
  foreach ($path in $base, $shortcut, (Join-Path $env:LOCALAPPDATA 'anj-cloud')) {
    if (Test-Path $path) { cmd /d /c "attrib -r `"$path\*`" /s /d" 2>$null | Out-Null; Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue }
  }
  Remove-ItemProperty $runKey -Name 'AnJ Cloud' -ErrorAction SilentlyContinue
  if (Test-Path $uninstallKey) { Remove-Item $uninstallKey -Recurse -Force }
  Remove-Item (Join-Path $env:LOCALAPPDATA 'Programs\.anj-cloud-transaction.lock') -ErrorAction SilentlyContinue
  if ($UnusualLocal) { Remove-Item $env:LOCALAPPDATA -Recurse -Force -ErrorAction SilentlyContinue }
  $results | Set-Content (Join-Path $Evidence 'update-results.txt')
  "RESULT passed=$(@($results | Where-Object { $_ -like 'PASS*' }).Count) failed=$(@($results | Where-Object { $_ -like 'FAIL*' }).Count)"
}
