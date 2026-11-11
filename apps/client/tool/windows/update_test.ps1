# In-app update checks on a Windows seat: the manager's apply-update against
# the real profile lock, registry and process model. It installs an older
# release, stages a newer one as the app would (archive and signed manifest
# in <profile>\updates) and checks: the read-only check, tampered and
# foreign-signed downloads, a hand-over while the app keeps running (not
# installed, the app is started again once it quits), a second hand-over at
# the same time, and the update itself (installed after Quit, previous
# release kept, the new release started, download discarded).
#
# -Dist holds, made on the build host:
#   old.zip            the installed release (package.ps1 with a version)
#   new.zip            a newer release trusting the same key
#   new.json           its signed manifest (deploy/release.py publish prints it)
#   new-otherkey.json  the same manifest signed by another key
# The manager refuses elevation and SSH sessions are elevated, so the checks
# run as an Interactive RunLevel Limited task in the console session (-Inner).
# It refuses to run when an installation already exists and removes only what
# it created.
param(
  [string]$Dist = 'C:\anj\work\update-dist',
  [string]$Evidence = 'C:\anj\evidence\update',
  [switch]$Inner
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Evidence | Out-Null

if (-not $Inner) {
  $out = Join-Path $Evidence 'update-inner.txt'
  Remove-Item $out -ErrorAction SilentlyContinue
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Inner -Dist `"$Dist`" -Evidence `"$Evidence`""
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c powershell $arguments > `"$out`" 2>&1"
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'anj-update-test' -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-update-test'
  $deadline = (Get-Date).AddSeconds(900)
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
'@
function Wait-Until([scriptblock]$condition, [int]$seconds) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) { if (& $condition) { return $true }; Start-Sleep -Milliseconds 300 }
  return [bool](& $condition)
}
function Manager([string]$exe, [string[]]$arguments) {
  $outFile = Join-Path $Evidence 'last-out.txt'; $errFile = Join-Path $Evidence 'last-err.txt'
  $p = Start-Process $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
  [pscustomobject]@{ code = $p.ExitCode; out = (Get-Content $outFile -Raw); err = (Get-Content $errFile -Raw) }
}
$base = Join-Path $env:LOCALAPPDATA 'Programs\anj-cloud'
$profile = Join-Path $env:LOCALAPPDATA 'anj-cloud\profile'
$updates = Join-Path $profile 'updates'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\AnJ Cloud.lnk'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AnJ Cloud'
function RunValue { (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).'AnJ Cloud' }
function Active { Get-Content (Join-Path $base 'active.json') -Raw | ConvertFrom-Json }
function Window { [W]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'AnJ Cloud') }
function Running { @(Get-Process anj_cloud -ErrorAction SilentlyContinue) }
# The tray's Quit, as a person would choose it.
function Quit-Client {
  [W]::PostMessage((Window), 0x0111, [IntPtr]1003, [IntPtr]::Zero) | Out-Null
  Wait-Until { -not (Running) } 30
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

  # The app's download: <profile>\updates\<code>.tar.gz and <code>.json.
  $archive = Join-Path $updates "$code.tar.gz"; $record = Join-Path $updates "$code.json"; $result = Join-Path $updates 'result.json'
  function Stage([string]$manifestFile = 'new.json') {
    New-Item -ItemType Directory -Force $updates | Out-Null
    Remove-Item (Join-Path $updates '*') -Force -ErrorAction SilentlyContinue
    Copy-Item $new $archive
    Copy-Item (Join-Path $Dist $manifestFile) $record
  }
  function Outcome { if (Test-Path $result) { Get-Content $result -Raw | ConvertFrom-Json } }
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
  $outcome = Outcome
  Check 'a corrupted download is not installed' ($r.code -eq 1 -and (Active).release -eq $first.release -and $outcome.ok -eq $false -and $outcome.message -match 'signed size and SHA-256') "$($outcome.message)"
  Check 'the refused download is discarded' (-not (Test-Path $archive) -and -not (Test-Path $record))
  $back = Wait-Until { (Window) -ne [IntPtr]::Zero } 40
  Check 'the release that was running is started again' ($back -and (Running)[0].Path -eq $clientA) "$((Running | ForEach-Object Path) -join ', ')"
  Start-Sleep 4
  Check 'tray Quit ends it' (Quit-Client)

  # The app keeps running: nothing is installed while it holds the profile.
  Stage
  Check 'the installed client starts' (Start-Client $clientA)
  $handover = Start-Process $managerA -ArgumentList ($applyArgs + @('--result', $result)) -PassThru -WindowStyle Hidden
  Start-Sleep 6
  Check 'no update while AnJ Cloud runs' ((Active).release -eq $first.release -and -not $handover.HasExited)
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
  Start-Sleep 4
  Check 'tray Quit ends it again' (Quit-Client)

  # The update: handed over while the app runs, installed once it has quit.
  Stage
  Check 'the installed client starts again' (Start-Client $clientA)
  $handover = Start-Process $managerA -ArgumentList ($applyArgs + @('--result', $result)) -PassThru -WindowStyle Hidden
  Start-Sleep 6
  Check 'still the older release while it runs' ((Active).release -eq $first.release)
  Check 'tray Quit ends the app for the update' (Quit-Client)
  $done = Wait-Until { (Test-Path $result) -and $handover.HasExited } 120
  $outcome = Outcome
  $second = Active
  Check 'the update is installed after Quit' ($done -and $outcome.ok -eq $true -and $outcome.version_code -eq $code -and $second.release -ne $first.release) "$($outcome.message)"
  Check 'the previous release is kept and recorded' ($second.previous -eq $first.release -and (Test-Path $clientA))
  $clientB = Join-Path $base "releases\$($second.release)\anj_cloud.exe"
  $back = Wait-Until { (Window) -ne [IntPtr]::Zero } 40
  Check 'the new release is started' ($back -and (Running)[0].Path -eq $clientB) "$((Running | ForEach-Object Path) -join ', ')"
  Check 'the profile is the same one' ($second.profile -eq $profile -and (Test-Path $profile))
  Check 'the download is discarded' (-not (Test-Path $archive) -and -not (Test-Path $record))
  Check 'Run value and shortcut follow the update' ((RunValue) -eq "`"$clientB`" --background" -and (Test-Path $shortcut))
  $newReceipt = Get-Content (Join-Path $base "releases\$($second.release)\bundle-receipt.json") -Raw | ConvertFrom-Json
  Check 'the active receipt is the new version' ($newReceipt.version_code -eq $code) "$($newReceipt.version)"
  Start-Sleep 4
  Check 'tray Quit ends the new release' (Quit-Client)

  # Replay: the same release again is not newer.
  Stage
  $managerB = Join-Path $base "releases\$($second.release)\anj-cloud-manager.exe"
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
  $results | Set-Content (Join-Path $Evidence 'update-results.txt')
  "RESULT passed=$(@($results | Where-Object { $_ -like 'PASS*' }).Count) failed=$(@($results | Where-Object { $_ -like 'FAIL*' }).Count)"
}
