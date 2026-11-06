# Replaces C:\anj\work\client's sources with the archive tool/windows_seat.sh
# push sent, keeping build\ and .dart_tool\ so rebuilds stay incremental.
param(
  [string]$Archive = 'C:\anj\downloads\client.tar',
  [string]$Target = 'C:\anj\work\client'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Target | Out-Null
Get-ChildItem $Target -Force | Where-Object { $_.Name -notin 'build', '.dart_tool' } |
  Remove-Item -Recurse -Force
tar -xf $Archive -C $Target
if ($LASTEXITCODE) { exit $LASTEXITCODE }
Remove-Item $Archive
'{0} files in {1}' -f (Get-ChildItem $Target -Recurse -File | Where-Object { $_.FullName -notmatch '\\(build|\.dart_tool)\\' } | Measure-Object).Count, $Target
