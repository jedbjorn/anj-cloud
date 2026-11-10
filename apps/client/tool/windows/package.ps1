# Builds the Windows release archive (spec #32 W5, Packaging and Updates):
# anj-cloud-<source12>-windows-x86_64.zip holding one directory,
# anj-cloud-windows-x86_64-<source12>\, with the Flutter release bundle
# (anj_cloud.exe, flutter_windows.dll, anj_rootfs.dll, plugin DLLs, data\),
# the MSVC runtime DLLs app-local (no redistributable install), the manager
# anj-cloud-manager.exe compiled from tool/windows_manager with the pinned
# SDK, and bundle-receipt.json with every file's SHA-256. The archive's own
# SHA-256 is printed and written beside it: the trusted handoff for install
# and update. Run after `flutter build windows --release`.
#
# -VersionCode and -Version stamp the release version into the receipt.
# Take both from the build host, as the other packagers do:
# `python3 deploy/client_version.py <commit>` prints them (the committed
# apps/client/release-version.json and the commit's UTC date). Only a release stamped with them updates itself in the app and
# can be published with deploy/release.py; without them the package installs
# and updates by hand only.
param(
  [Parameter(Mandatory)][string]$SourceHead,
  [int]$VersionCode = 0,
  [string]$Version = '',
  [string]$Source = 'C:\anj\work\client',
  [string]$Out = 'C:\anj\work\w5-dist',
  [string]$Vs = 'C:\anj\toolchains\vs2022-buildtools',
  [string]$Flutter = 'C:\anj\toolchains\flutter-3.47.9',
  [switch]$Stored
)
$ErrorActionPreference = 'Stop'
if ($SourceHead -notmatch '^[0-9a-f]{40}$') { throw 'SourceHead must be a 40-hex commit id' }
if ($VersionCode -or $Version) {
  if ($VersionCode -lt 1 -or $VersionCode -gt 2100000000 -or $Version -cnotmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$') {
    throw '-VersionCode and -Version must both be given and valid'
  }
}
$short = $SourceHead.Substring(0, 12)
$top = "anj-cloud-windows-x86_64-$short"
$bundle = Join-Path $Source 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $bundle 'anj_cloud.exe'))) { throw "no release build at $bundle" }
New-Item -ItemType Directory -Force $Out | Out-Null
$stage = Join-Path $Out $top
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Copy-Item $bundle $stage -Recurse

# The manager, from the same source and SDK.
Push-Location $Source
& "$Flutter\bin\dart.bat" compile exe tool\windows_manager\main.dart -o (Join-Path $stage 'anj-cloud-manager.exe')
if ($LASTEXITCODE) { throw 'dart compile exe failed' }
Pop-Location

# The MSVC runtime, app-local (the redistributable shipped with the build tools).
$crt = Get-ChildItem "$Vs\VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT" -Directory | Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw "no MSVC runtime redistributable under $Vs" }
foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
  Copy-Item (Join-Path $crt.FullName $dll) $stage
}

$files = [ordered]@{}
Get-ChildItem $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
  $relative = $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
  $files[$relative] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
}
$receipt = [ordered]@{
  platform = 'Windows x86_64'
  source_head = $SourceHead
  toolchain = 'Flutter 3.47.9, MSVC ' + (Split-Path (Split-Path (Split-Path $crt.FullName)) -Leaf)
  files_sha256 = $files
}
if ($VersionCode) {
  $receipt.version_code = $VersionCode
  $receipt.version = $Version
}
[IO.File]::WriteAllText((Join-Path $stage 'bundle-receipt.json'), ($receipt | ConvertTo-Json -Depth 4))

$zip = Join-Path $Out "anj-cloud-$short-windows-x86_64$(if ($Stored) { '-stored' }).zip"
if (Test-Path $zip) { Remove-Item $zip }
# bsdtar writes forward-slash member names (PowerShell 5's Compress-Archive
# writes backslashes).
if ($Stored) {
  & tar.exe --format zip --options zip:compression=store -cf $zip -C $Out $top
} else {
  & tar.exe --format zip -cf $zip -C $Out $top
}
if ($LASTEXITCODE) { throw 'zip failed' }
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Set-Content "$zip.sha256" "$sha  $(Split-Path $zip -Leaf)"
"archive $zip"
"sha256 $sha"
"files $($files.Count)"
if ($VersionCode) { "version $Version (version_code $VersionCode)" } else { 'version none: no in-app update, not publishable' }
