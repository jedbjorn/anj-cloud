# Builds anj_rootfs.dll and its native tests with the seat's MSVC, then runs
# them (spec #32 W2). SSH sessions are elevated, so only the fixture that an
# unelevated user cannot make (symlinks, an explicit 8.3 name) is created
# here; the tests themselves run unelevated in the console session through a
# one-shot RunLevel Limited task, as the client does (ownership and sharing
# depend on it). With -Dart, the Windows Dart tests run the same way against
# the freshly built library.
param(
  [string]$Source = 'C:\anj\work\client',
  [string]$Out = 'C:\anj\work\w2build',
  [string]$Evidence = 'C:\anj\evidence\w2',
  [switch]$Dart,
  [string[]]$DartTests = @('test/windows_root_fs_test.dart', 'test/native_portability_test.dart', 'test/windows_skeleton_test.dart', 'test/windows_session_native_test.dart', 'test/windows_desktop_session_test.dart', 'test/windows_watch_seat_test.dart', 'test/windows_stat_audit_test.dart'),
  [int]$Timeout = 600
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Out, $Evidence | Out-Null
$fixture = Join-Path $env:LOCALAPPDATA 'Temp\anj-w2'
$taskPath = '\anj\'

function Invoke-Limited([string]$Name, [string]$Command, [int]$Seconds) {
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c `"$Command`"" -WorkingDirectory $Source
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $Name -TaskPath $taskPath -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath $taskPath -TaskName $Name
  $deadline = (Get-Date).AddSeconds($Seconds)
  Start-Sleep 2
  while ((Get-ScheduledTask -TaskPath $taskPath -TaskName $Name).State -eq 'Running') {
    if ((Get-Date) -gt $deadline) {
      Stop-ScheduledTask -TaskPath $taskPath -TaskName $Name
      Write-Output "TIMEOUT $Name after $Seconds s"
      break
    }
    Start-Sleep 2
  }
  $code = (Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $Name).LastTaskResult
  Unregister-ScheduledTask -TaskPath $taskPath -TaskName $Name -Confirm:$false
  return $code
}
# Never Remove-Item -Recurse here: the fixture holds junctions and a mount
# point of C:, which must be removed as links, never traversed.
function Remove-Fixture {
  if (-not (Test-Path $fixture)) { return }
  $exe = Join-Path $Out 'rootfs_win_test.exe'
  if (Test-Path $exe) { & $exe clean $fixture | Out-Null }
  if (Test-Path $fixture) { cmd /d /c "rmdir /s /q `"$fixture`"" | Out-Null }
}
function Remove-TaskFolder {
  $s = New-Object -ComObject Schedule.Service; $s.Connect()
  try { $s.GetFolder('\').DeleteFolder('anj', 0) } catch {}
}

try {
  # anj's own Build Tools instance, selected by path (install.ps1), never
  # another project's Visual Studio.
  $vs = 'C:\anj\toolchains\vs2022-buildtools'
  $vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
  if (-not (Test-Path $vcvars)) { throw "missing ${vcvars} (run install.ps1)" }
  "vs instance $vs" | Tee-Object -FilePath (Join-Path $Evidence 'native-build.txt')
  $native = Join-Path $Source 'native\windows'
  $flags = '/nologo /std:c++17 /W4 /WX /wd4100 /EHsc /O2 /DUNICODE /D_UNICODE /DNOMINMAX'
  $build = "call `"$vcvars`" >nul && cd /d `"$Out`" && " +
    "cl $flags /LD `"$native\rootfs_win.cc`" advapi32.lib /Fe:anj_rootfs_shipped.dll && " +
    "cl $flags /DANJ_TEST_SEAMS /LD `"$native\rootfs_win.cc`" advapi32.lib /Fe:anj_rootfs.dll && " +
    "cl $flags `"$native\test\rootfs_win_test.cc`" advapi32.lib /Fe:rootfs_win_test.exe && " +
    "dumpbin /nologo /exports anj_rootfs.dll"
  cmd /d /c $build 2>&1 | Tee-Object -FilePath (Join-Path $Evidence 'native-build.txt') -Append
  if ($LASTEXITCODE) { throw "native build failed ($LASTEXITCODE)" }
  # The shared ABI (native/posix/exports.txt): the shipped build (as the
  # runner's CMake builds it) exports exactly the listed symbols; the test
  # build adds only the anj_win_* seams (-DANJ_TEST_SEAMS).
  $abi = Join-Path $Source 'native\posix\exports.txt'
  $want = Get-Content $abi | Where-Object { $_ -match '^anj_' }
  foreach ($dll in 'anj_rootfs_shipped.dll', 'anj_rootfs.dll') {
    $have = (cmd /d /c "call `"$vcvars`" >nul && dumpbin /nologo /exports `"$Out\$dll`"") |
      ForEach-Object { if ($_ -match '\s(anj_\w+)\s*$') { $Matches[1] } }
    $missing = $want | Where-Object { $_ -notin $have }
    $extra = $have | Where-Object { $_ -notin $want }
    "ABI ${dll}: $($want.Count) listed, $($have.Count) exported, missing: $($missing -join ' '), extra: $($extra -join ' ')" |
      Tee-Object -FilePath (Join-Path $Evidence 'native-build.txt') -Append
    if ($missing) { throw "$dll lacks listed exports: $($missing -join ' ')" }
    if ($dll -eq 'anj_rootfs_shipped.dll' -and $extra) { throw "$dll exports more than the ABI: $($extra -join ' ')" }
    if ($extra | Where-Object { $_ -notmatch '^anj_win_' }) { throw "$dll exports unlisted symbols: $($extra -join ' ')" }
  }
  Get-FileHash (Join-Path $Out 'anj_rootfs.dll') -Algorithm SHA256 | Format-List | Out-String |
    Tee-Object -FilePath (Join-Path $Evidence 'native-build.txt') -Append

  Remove-Fixture
  & (Join-Path $Out 'rootfs_win_test.exe') fixture $fixture 2>&1 |
    Tee-Object -FilePath (Join-Path $Evidence 'native-fixture.txt')

  $log = Join-Path $Evidence 'native-run.txt'
  $exe = Join-Path $Out 'rootfs_win_test.exe'
  $dll = Join-Path $Out 'anj_rootfs.dll'
  $code = Invoke-Limited 'anj-w2-native' "`"$exe`" run `"$fixture`" `"$dll`" > `"$log`" 2>&1" 300
  Get-Content $log
  "native exit $code"

  if ($Dart) {
    $flutter = 'C:\anj\toolchains\flutter-3.47.9\bin\flutter.bat'
    $dartLog = Join-Path $Evidence 'dart-run.txt'
    $tests = $DartTests -join ' '
    # Plugin symlinks need Developer Mode or elevation (left off on the seat),
    # so pub get runs here, elevated, and the unelevated run skips it.
    Push-Location $Source
    & $flutter --suppress-analytics pub get --enforce-lockfile 2>&1 | Select-Object -Last 3
    Pop-Location
    $cmd = "set ANJ_ROOTFS_LIBRARY=$dll&& set FLUTTER_SUPPRESS_ANALYTICS=true&& " +
      "call `"$flutter`" --suppress-analytics test --no-pub --concurrency=1 $tests > `"$dartLog`" 2>&1"
    $dcode = Invoke-Limited 'anj-w2-dart' $cmd $Timeout
    Get-Content $dartLog -Tail 60
    "dart exit $dcode"
  }
} finally {
  Remove-TaskFolder
  Remove-Fixture
  Get-Process rootfs_win_test, notepad -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
