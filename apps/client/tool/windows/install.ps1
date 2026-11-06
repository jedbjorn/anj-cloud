# Installs the Windows client toolchain on the W10C-Testing seat (spec #32 W0).
# Idempotent: a complete install is detected and left alone, so this is the
# recovery step after another project resets the VM to its snapshot (which
# wipes C:\anj). Everything lands under C:\anj except what the Visual Studio
# installer itself puts in Program Files and ProgramData.
#
#   Flutter 3.47.9 (decision #102), verified by the release's SHA-256.
#   Visual Studio Build Tools 2022: the C++ desktop workload (VCTools with
#   recommended components, which bring the Windows SDK) plus C++ ATL, which
#   flutter_secure_storage_windows needs (its README).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

$root = 'C:\anj'
foreach ($d in 'toolchains', 'downloads', 'evidence', 'work', 'tools') {
  New-Item -ItemType Directory -Force (Join-Path $root $d) | Out-Null
}
$log = "$root\evidence\install.log"
function L($m) { $l = (Get-Date -Format o) + ' ' + $m; Add-Content $log $l; Write-Output $l }

# Flutter 3.47.9 (decision #102).
$flutter = "$root\toolchains\flutter-3.47.9"
$fz = "$root\downloads\flutter_windows_3.47.9-stable.zip"
$want = 'd8e2b5977e09082c6440f89dc1aa887b94c8fbcc3b39222797046295a3f68a9e'
if (-not (Test-Path "$flutter\bin\flutter.bat")) {
  if (-not (Test-Path $fz) -or (Get-FileHash $fz -Algorithm SHA256).Hash.ToLower() -ne $want) {
    L 'downloading flutter'
    Invoke-WebRequest 'https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.47.9-stable.zip' -OutFile $fz -UseBasicParsing
  }
  $h = (Get-FileHash $fz -Algorithm SHA256).Hash.ToLower(); L "flutter sha256 $h"
  if ($h -ne $want) { throw 'flutter hash mismatch' }
  L 'extracting flutter'
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $tmp = "$root\toolchains\_x"; if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  [IO.Compression.ZipFile]::ExtractToDirectory($fz, $tmp)
  Move-Item "$tmp\flutter" $flutter; Remove-Item $tmp -Recurse -Force
  L 'flutter extracted'
}

# Visual Studio Build Tools 2022.
$vsPath = "$root\toolchains\vs2022-buildtools"
$components = @('Microsoft.VisualStudio.Workload.VCTools', 'Microsoft.VisualStudio.Component.VC.ATL')
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
# Only anj's own instance at $vsPath counts and is ever changed: another
# project's Visual Studio on the shared seat is left alone (decision #117).
function Has($component) {
  if (-not (Test-Path $vswhere)) { return $false }
  $paths = & $vswhere -all -products * -requires $component -property installationPath
  [bool]($paths | Where-Object { $_.TrimEnd('\') -ieq $vsPath })
}
$vsb = "$root\downloads\vs_BuildTools.exe"
function Bootstrapper {
  if (-not (Test-Path $vsb)) {
    L 'downloading vs_BuildTools'
    Invoke-WebRequest 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $vsb -UseBasicParsing
  }
  $sig = Get-AuthenticodeSignature $vsb
  L ("vs_BuildTools signature: " + $sig.Status + ' ' + $sig.SignerCertificate.Subject)
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    throw 'vs_BuildTools signature is not a valid Microsoft signature'
  }
}
# anj's instance is missing: install it at $vsPath even if another exists.
if (-not (Has 'Microsoft.VisualStudio.Workload.VCTools')) {
  Bootstrapper
  L 'installing build tools'
  $vsArgs = @('--quiet', '--wait', '--norestart', '--nocache', '--installPath', $vsPath)
  foreach ($c in $components) { $vsArgs += @('--add', $c) }
  $vsArgs += '--includeRecommended'
  $p = Start-Process $vsb -ArgumentList $vsArgs -Wait -PassThru
  L ("vs_BuildTools install exit " + $p.ExitCode)
} elseif (-not (Has 'Microsoft.VisualStudio.Component.VC.ATL')) {
  Bootstrapper
  L "adding C++ ATL to $vsPath"
  $p = Start-Process $vsb -ArgumentList @('modify', '--installPath', $vsPath, '--add', 'Microsoft.VisualStudio.Component.VC.ATL', '--quiet', '--wait', '--norestart', '--nocache') -Wait -PassThru
  L ("vs_BuildTools modify exit " + $p.ExitCode)
}
foreach ($c in $components) {
  if (-not (Has $c)) { throw "missing Visual Studio component $c at $vsPath" }
  L "present at ${vsPath}: $c"
}
L 'install done'
