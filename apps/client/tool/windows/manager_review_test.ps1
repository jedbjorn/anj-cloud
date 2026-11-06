# PR #67 review checks on W10C-Testing (spec #32 W5): a pre-W5 Roaming
# profile adopted by install and seen by the installed client; foreign
# registry entries (a Run value of another type, an Uninstall key without
# InstallLocation) left alone and reported; uninstall's failure outcome and
# its tombstone removal. Same pattern as manager_test.ps1: an Interactive
# RunLevel Limited task in the console session (-Inner).
param(
  [string]$Dist = 'C:\anj\work\w5-dist',
  [string]$Evidence = 'C:\anj\evidence\w5',
  [switch]$Inner
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Evidence | Out-Null
if (-not $Inner) {
  $out = Join-Path $Evidence 'review-inner.txt'
  Remove-Item $out -ErrorAction SilentlyContinue
  $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Inner -Dist `"$Dist`" -Evidence `"$Evidence`""
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c powershell $arguments > `"$out`" 2>&1"
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'anj-w5-review' -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w5-review'
  $deadline = (Get-Date).AddSeconds(420)
  Start-Sleep 3
  while ((Get-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w5-review').State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep 3 }
  Get-Content $out -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w5-review' -Confirm:$false -ErrorAction SilentlyContinue
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
  $o = Join-Path $Evidence 'r-out.txt'; $e = Join-Path $Evidence 'r-err.txt'
  $p = Start-Process $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e
  [pscustomobject]@{ code = $p.ExitCode; out = (Get-Content $o -Raw); err = (Get-Content $e -Raw) }
}
function Window { [W]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'AnJ Cloud') }
function Quit-Client {
  [W]::PostMessage((Window), 0x0111, [IntPtr]1003, [IntPtr]::Zero) | Out-Null
  Wait-Until { -not (Get-Process anj_cloud -ErrorAction SilentlyContinue) } 20 | Out-Null
  Get-Process anj_cloud -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
$base = Join-Path $env:LOCALAPPDATA 'Programs\anj-cloud'
$local = Join-Path $env:LOCALAPPDATA 'anj-cloud'
$profile = Join-Path $local 'profile'
$legacyRoot = Join-Path $env:APPDATA 'cloud.anj\anj_cloud'
$legacy = Join-Path $legacyRoot 'anj-cloud\default'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AnJ Cloud'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\AnJ Cloud.lnk'
try {
  $existing = @($base, $local, $legacyRoot, $uninstallKey | Where-Object { Test-Path $_ })
  if ((Get-ItemProperty $runKey -ErrorAction SilentlyContinue).'AnJ Cloud') { $existing += 'Run value' }
  if ($existing) { throw "existing state, not touching it: $($existing -join ', ')" }
  $zip = Get-ChildItem $Dist -Filter 'anj-cloud-*-windows-x86_64.zip' | Select-Object -First 1
  $sha = (Get-FileHash $zip.FullName -Algorithm SHA256).Hash.ToLower()
  $unpacked = Join-Path $Dist 'unpacked'
  if (Test-Path $unpacked) { Remove-Item $unpacked -Recurse -Force }
  New-Item -ItemType Directory $unpacked | Out-Null
  tar.exe -xf $zip.FullName -C $unpacked
  $bootstrap = (Get-ChildItem $unpacked -Recurse -Filter 'anj-cloud-manager.exe' | Select-Object -First 1).FullName
  $oldClient = Join-Path (Split-Path $bootstrap) 'anj_cloud.exe'

  # A pre-W5 profile: the client run on the Roaming default creates it.
  Start-Process $oldClient -ArgumentList @('--profile-dir', "`"$legacy`"")
  Wait-Until { (Window) -ne [IntPtr]::Zero } 40 | Out-Null
  Start-Sleep 6
  Quit-Client
  Set-Content (Join-Path $legacy 'w5-marker.txt') 'paired-before-w5'
  $manifest = Get-ChildItem $legacy -File | Where-Object Name -like 'manifest*' | Select-Object -First 1
  Check 'a pre-W5 Roaming profile exists' ($null -ne $manifest) "$((Get-ChildItem $legacy -Force).Name -join ', ')"
  $born = $manifest.CreationTimeUtc

  # Foreign entries: a Run value of another type, an Uninstall key without InstallLocation.
  New-ItemProperty $runKey -Name 'AnJ Cloud' -PropertyType DWord -Value 1 | Out-Null
  New-Item $uninstallKey -Force | Out-Null
  New-ItemProperty $uninstallKey -Name 'DisplayName' -Value 'Something else' | Out-Null

  $r = Manager $bootstrap @('install', $zip.FullName, '--sha256', $sha)
  Check 'install succeeds and reports the foreign entries' ($r.code -eq 0 -and $r.out -match 'Run value' -and $r.out -match 'Programs and Features') "$($r.err)"
  Check 'the foreign Run value is untouched (still a DWORD)' ((Get-ItemProperty $runKey).'AnJ Cloud' -eq 1)
  Check 'the foreign Uninstall key is untouched' (-not (Get-ItemProperty $uninstallKey).InstallLocation -and (Get-ItemProperty $uninstallKey).DisplayName -eq 'Something else')
  Check 'the Roaming profile moved to LOCALAPPDATA' ((Test-Path (Join-Path $profile 'w5-marker.txt')) -and -not (Test-Path $legacy))

  # The installed client (no arguments, as the shortcut starts it) opens it.
  $state = Get-Content (Join-Path $base 'active.json') -Raw | ConvertFrom-Json
  $client = Join-Path $base "releases\$($state.release)\anj_cloud.exe"
  $managerB = Join-Path $base "releases\$($state.release)\anj-cloud-manager.exe"
  Start-Process $client
  Wait-Until { (Window) -ne [IntPtr]::Zero } 40 | Out-Null
  Start-Sleep 5
  $after = Get-ChildItem $profile -File | Where-Object Name -eq $manifest.Name | Select-Object -First 1
  Check 'the installed client opened the moved profile (same manifest, marker kept)' ($after -and $after.CreationTimeUtc -eq $born -and (Test-Path (Join-Path $profile 'w5-marker.txt'))) "$($after.CreationTimeUtc) vs $born"

  # Uninstall's detached continuation records a failure too (client running).
  $temporary = Join-Path $env:TEMP "anj-cloud-uninstall-review"
  New-Item -ItemType Directory -Force $temporary | Out-Null
  Copy-Item $managerB $temporary; Copy-Item (Join-Path (Split-Path $managerB) 'anj_rootfs.dll') $temporary
  $outcome = Join-Path $local 'logs\uninstall.json'
  $r = Manager (Join-Path $temporary 'anj-cloud-manager.exe') @('uninstall', '--after', '999999')
  $text = Get-Content $outcome -Raw -ErrorAction SilentlyContinue
  Check 'a failed uninstall continuation writes its outcome' ($r.code -eq 1 -and $text -match 'error' -and $text -match 'already running' -and (Test-Path $base)) "$text"
  $r = Manager (Join-Path $temporary 'anj-cloud-manager.exe') @('uninstall', '--after', 'x')
  Check 'a bad --after is refused cleanly' ($r.code -eq 1 -and $r.err -match 'Usage') "$($r.err)"
  Quit-Client

  # Uninstall: foreign entries stay; ours go; the directory goes through a tombstone.
  Remove-Item $outcome -ErrorAction SilentlyContinue
  $r = Manager $managerB @('uninstall')
  $done = Wait-Until { (Test-Path $outcome) -and -not (Test-Path $base) } 40
  $text = Get-Content $outcome -Raw -ErrorAction SilentlyContinue
  Check 'uninstall finishes from its temporary copy' ($r.code -eq 0 -and $done -and $text -notmatch '"error"') "$text"
  $tombstones = @(Get-ChildItem (Split-Path $base) -Directory -Filter 'anj-cloud.removing-*' -ErrorAction SilentlyContinue)
  Check 'no tombstone left' ($tombstones.Count -eq 0) "$($tombstones.Name -join ', ')"
  Check 'uninstall kept the foreign entries' ((Get-ItemProperty $runKey).'AnJ Cloud' -eq 1 -and (Get-ItemProperty $uninstallKey).DisplayName -eq 'Something else')
  Check 'uninstall removed our shortcut and kept the profile' (-not (Test-Path $shortcut) -and (Test-Path (Join-Path $profile 'w5-marker.txt')))
  # The next manager run sweeps an earlier uninstall's copy.
  $r = Manager $bootstrap @('status')
  Check 'a later manager run sweeps the review copy in %TEMP%' (-not (Test-Path $temporary))
} catch {
  Check 'review test ran to the end' $false "$_"
} finally {
  Get-Process anj_cloud -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  foreach ($path in $base, $shortcut, $local, $legacyRoot) {
    if (Test-Path $path) { cmd /d /c "attrib -r `"$path\*`" /s /d" 2>$null | Out-Null; Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue }
  }
  Get-ChildItem (Split-Path $base) -Directory -Filter 'anj-cloud.removing-*' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
  Remove-Item (Join-Path (Split-Path $base) '.anj-cloud-transaction.lock') -ErrorAction SilentlyContinue
  Remove-ItemProperty $runKey -Name 'AnJ Cloud' -ErrorAction SilentlyContinue
  if (Test-Path $uninstallKey) { Remove-Item $uninstallKey -Recurse -Force }
  $results | Set-Content (Join-Path $Evidence 'review-results.txt')
  "RESULT passed=$(@($results | Where-Object { $_ -like 'PASS*' }).Count) failed=$(@($results | Where-Object { $_ -like 'FAIL*' }).Count)"
}
