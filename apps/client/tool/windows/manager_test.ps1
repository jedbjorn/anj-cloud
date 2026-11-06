# Manager checks on W10C-Testing (spec #32 W5, Acceptance row 13): install
# from the zip, wrong SHA-256, update refused while running, update, start
# at login on and off, read-only releases, uninstall of exactly what install
# added. The manager refuses elevation, and SSH sessions are elevated, so the
# checks run as an Interactive RunLevel Limited task of the same user in the
# console session (-Inner). Archives come from tool/windows/package.ps1
# (deflated and stored builds of one release, two archive digests).
param(
  [string]$Dist = 'C:\anj\work\w5-dist',
  [string]$Evidence = 'C:\anj\evidence\w5',
  [switch]$Inner
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Evidence | Out-Null

if (-not $Inner) {
  $out = Join-Path $Evidence 'manager-inner.txt'
  Remove-Item $out -ErrorAction SilentlyContinue
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Inner -Dist `"$Dist`" -Evidence `"$Evidence`""
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c powershell $arguments > `"$out`" 2>&1"
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'anj-w5-manager' -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w5-manager'
  $deadline = (Get-Date).AddSeconds(420)
  Start-Sleep 3
  while ((Get-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w5-manager').State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep 3 }
  Get-Content $out -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w5-manager' -Confirm:$false -ErrorAction SilentlyContinue
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
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\AnJ Cloud.lnk'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AnJ Cloud'
function RunValue { (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).'AnJ Cloud' }
function Active { Get-Content (Join-Path $base 'active.json') -Raw | ConvertFrom-Json }

try {
  if ((Test-Path $base) -or (RunValue) -or (Test-Path $uninstallKey)) { throw 'an installation already exists; not touching it' }
  $zipA = Get-ChildItem $Dist -Filter 'anj-cloud-*-windows-x86_64.zip' | Select-Object -First 1
  $zipB = Get-ChildItem $Dist -Filter 'anj-cloud-*-windows-x86_64-stored.zip' | Select-Object -First 1
  $shaA = (Get-FileHash $zipA.FullName -Algorithm SHA256).Hash.ToLower()
  $shaB = (Get-FileHash $zipB.FullName -Algorithm SHA256).Hash.ToLower()
  $unpacked = Join-Path $Dist 'unpacked'
  if (Test-Path $unpacked) { Remove-Item $unpacked -Recurse -Force }
  New-Item -ItemType Directory $unpacked | Out-Null
  tar.exe -xf $zipA.FullName -C $unpacked
  $bootstrap = (Get-ChildItem $unpacked -Recurse -Filter 'anj-cloud-manager.exe' | Select-Object -First 1).FullName

  $r = Manager $bootstrap @('install', $zipA.FullName, '--sha256', $shaA)
  Check 'install from the zip' ($r.code -eq 0) "$($r.err)"
  $state = Active
  $releaseA = Join-Path $base "releases\$($state.release)"
  $client = Join-Path $releaseA 'anj_cloud.exe'
  $managerA = Join-Path $releaseA 'anj-cloud-manager.exe'
  Check 'active release is the archive' ($state.archive_sha256 -eq $shaA -and (Test-Path $client))
  Check 'release files are read-only' ((Get-Item $client).IsReadOnly)
  Check 'Start menu shortcut' (Test-Path $shortcut)
  $run = RunValue
  Check 'Run value starts the client hidden (--background), under 260 characters' ($run -eq "`"$client`" --background" -and $run.Length -lt 260) "$($run.Length) chars"
  $entry = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue
  Check 'Programs and Features entry' ($entry.InstallLocation -eq $base -and $entry.UninstallString -eq "`"$managerA`" uninstall") "$($entry.DisplayName) $($entry.DisplayVersion)"
  Check 'profile under LOCALAPPDATA' ($state.profile -eq $profile)

  $r = Manager $managerA @('update', $zipB.FullName, '--sha256', ('0' * 64))
  Check 'update with a wrong SHA-256 refused' ($r.code -eq 1 -and $r.err -match 'does not match') "$($r.err)"
  Check 'previous selection intact' ((Active).release -eq $state.release)

  # Start as the shortcut does; the update must refuse while it runs.
  Start-Process $client
  $window = Wait-Until { [W]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'AnJ Cloud') -ne [IntPtr]::Zero } 40
  Start-Sleep 4
  Check 'the installed client starts' $window
  $r = Manager $managerA @('update', $zipB.FullName, '--sha256', $shaB)
  Check 'update refused while AnJ Cloud runs' ($r.code -eq 1 -and $r.err -match 'already running') "$($r.err)"
  Check 'still the previous release' ((Active).release -eq $state.release)
  [W]::PostMessage([W]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'AnJ Cloud'), 0x0111, [IntPtr]1003, [IntPtr]::Zero) | Out-Null
  $quit = Wait-Until { -not (Get-Process anj_cloud -ErrorAction SilentlyContinue) } 20
  Check 'tray Quit ends it' $quit

  $r = Manager $managerA @('update', $zipB.FullName, '--sha256', $shaB)
  $stateB = Active
  Check 'update after Quit' ($r.code -eq 0 -and $stateB.archive_sha256 -eq $shaB) "$($r.err)"
  Check 'previous release kept and recorded' ($stateB.previous -eq $state.release -and (Test-Path $releaseA))
  $managerB = Join-Path $base "releases\$($stateB.release)\anj-cloud-manager.exe"
  Check 'Run value follows the update' ((RunValue) -like "*$($stateB.release)*")

  $r = Manager $managerB @('autostart', 'disable')
  Check 'autostart off removes the Run value' ($r.code -eq 0 -and -not (RunValue))
  $r = Manager $managerB @('autostart', 'status')
  Check 'status reports off' ($r.out -match '"enabled": false')
  $r = Manager $managerB @('autostart', 'enable')
  Check 'autostart on writes it again' ($r.code -eq 0 -and (RunValue) -like "*--background*")
  $r = Manager $managerB @('status')
  Check 'status' ($r.code -eq 0 -and $r.out -match $stateB.release)

  # Profile content the uninstall must keep.
  New-Item -ItemType Directory -Force (Join-Path $env:LOCALAPPDATA 'anj-cloud\secrets') | Out-Null
  Set-Content (Join-Path $env:LOCALAPPDATA 'anj-cloud\secrets\keep.dpapi') 'k'
  $r = Manager $managerB @('uninstall')
  $log = Join-Path $env:LOCALAPPDATA 'anj-cloud\logs\uninstall.json'
  $done = Wait-Until { (Test-Path $log) -and -not (Test-Path $base) } 40
  Check 'uninstall runs from a temporary copy and finishes' ($r.code -eq 0 -and $done) "$($r.out)"
  Check 'uninstall removed the Run value, shortcut and entry' (-not (RunValue) -and -not (Test-Path $shortcut) -and -not (Test-Path $uninstallKey))
  Check 'uninstall kept the profile and secrets' ((Test-Path $profile) -and (Test-Path (Join-Path $env:LOCALAPPDATA 'anj-cloud\secrets\keep.dpapi')))
  if (Test-Path $log) { Copy-Item $log (Join-Path $Evidence 'uninstall.json') }
} catch {
  Check 'manager test ran to the end' $false "$_"
} finally {
  Get-Process anj_cloud -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  # Test cleanup only: what this run created.
  foreach ($path in $base, $shortcut, (Join-Path $env:LOCALAPPDATA 'anj-cloud')) {
    if (Test-Path $path) { cmd /d /c "attrib -r `"$path\*`" /s /d" 2>$null | Out-Null; Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue }
  }
  Remove-ItemProperty $runKey -Name 'AnJ Cloud' -ErrorAction SilentlyContinue
  if (Test-Path $uninstallKey) { Remove-Item $uninstallKey -Recurse -Force }
  $results | Set-Content (Join-Path $Evidence 'manager-results.txt')
  "RESULT passed=$(@($results | Where-Object { $_ -like 'PASS*' }).Count) failed=$(@($results | Where-Object { $_ -like 'FAIL*' }).Count)"
}
