# Windows build recipe for the client (spec #32 W0), run on the seat over SSH.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 `
#     -Source C:\anj\work\client -Evidence C:\anj\evidence\w0
#
# -Source holds apps/client as pushed by tool/windows_seat.sh. The pinned SDK
# and the pub cache stay under C:\anj (decision #102, decision #117). Steps:
# toolchain report, pub get, analyze, the Windows-only tests, release build.
# Every step's output is written as UTF-8 under -Evidence; the script stops at
# the first failing step and exits with its code.
param(
  [string]$Source = 'C:\anj\work\client',
  [string]$Evidence = 'C:\anj\evidence\w0',
  [string[]]$Tests = @('test/windows_skeleton_test.dart')
)
$ErrorActionPreference = 'Continue'
$env:PATH = 'C:\anj\toolchains\flutter-3.47.9\bin;' + $env:PATH
$env:PUB_CACHE = 'C:\anj\pub-cache'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'
New-Item -ItemType Directory -Force $Evidence | Out-Null
Set-Location $Source

function Step($name, [scriptblock]$body) {
  $out = Join-Path $Evidence "$name.txt"
  $started = Get-Date
  & $body 2>&1 | ForEach-Object { "$_" } | Out-File -Encoding utf8 $out
  $code = $LASTEXITCODE
  $line = '{0} exit {1} in {2:n0}s' -f $name, $code, ((Get-Date) - $started).TotalSeconds
  Add-Content -Encoding utf8 (Join-Path $Evidence 'steps.txt') $line
  Write-Output $line
  if ($code -ne 0) { Get-Content $out -Tail 40; exit $code }
}

Remove-Item (Join-Path $Evidence 'steps.txt') -ErrorAction SilentlyContinue
flutter --disable-analytics 2>&1 | Out-Null
Step 'flutter-version' { flutter --version }
Step 'flutter-doctor' { flutter doctor -v }
Step 'vs-components' {
  # anj's own instance (tool/windows/install.ps1), not whichever comes first.
  $vsPath = 'C:\anj\toolchains\vs2022-buildtools'
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  foreach ($c in 'Microsoft.VisualStudio.Workload.VCTools', 'Microsoft.VisualStudio.Component.VC.ATL') {
    $at = & $vswhere -all -products * -requires $c -property installationPath | Where-Object { $_.TrimEnd('\') -ieq $vsPath }
    if (-not $at) { Write-Output "MISSING $c at $vsPath"; cmd /c exit 1; return }
    Write-Output "present $c at $at"
  }
  $atl = Get-ChildItem "$vsPath\VC\Tools\MSVC\*\atlmfc\include\atlbase.h" -ErrorAction SilentlyContinue
  if (-not $atl) { Write-Output 'MISSING atlbase.h'; cmd /c exit 1; return }
  $atl | ForEach-Object { "header $($_.FullName)" }
  # Other instances are reported, never used or changed.
  & $vswhere -all -products * -property installationPath | Where-Object { $_.TrimEnd('\') -ine $vsPath } | ForEach-Object { "other instance (ignored) $_" }
  cmd /c exit 0
}
Step 'pub-get' { flutter pub get --enforce-lockfile }
Step 'analyze' { flutter analyze }
Step 'test' { flutter test --concurrency=1 @Tests }
Step 'build' {
  # anj-defines.env (the deployment profile's origin) is sent by
  # `windows_seat.sh push --profile` when the profile is real.
  if (Test-Path 'anj-defines.env') { flutter build windows --release --dart-define-from-file=anj-defines.env }
  else { flutter build windows --release }
}
Step 'bundle' {
  $release = Join-Path $Source 'build\windows\x64\runner\Release'
  Get-ChildItem $release -Recurse -File | ForEach-Object {
    '{0}  {1,10}  {2}' -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower(), $_.Length, $_.FullName.Substring($release.Length + 1)
  }
  cmd /c exit 0
}
