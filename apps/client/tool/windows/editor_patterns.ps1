# Records how the seat's editors save (spec #32 W4, Files in Other Apps):
# Notepad (.txt), WordPad (.rtf) and Paint (.png) each open a file, change
# it through the keyboard and save; a FileSystemWatcher logs every create,
# change, rename and delete in the folder meanwhile, and the file's NTFS id
# before and after tells an in-place write from a replace. Runs in the
# console session as an Interactive task (-Inner); writes patterns.json.
param([string]$Evidence = 'C:\anj\evidence\w4', [switch]$Inner)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $Evidence | Out-Null
if (-not $Inner) {
  $out = Join-Path $Evidence 'editor-inner.txt'
  $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/d /c powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Inner -Evidence `"$Evidence`" > `"$out`" 2>&1"
  $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $p = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName 'anj-w4-editors' -TaskPath '\anj\' -Action $a -Principal $p -Force | Out-Null
  Start-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w4-editors'
  $deadline = (Get-Date).AddSeconds(180); Start-Sleep 3
  while ((Get-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w4-editors').State -eq 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep 2 }
  Get-Content $out -ErrorAction SilentlyContinue
  Get-Content (Join-Path $Evidence 'patterns.json') -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskPath '\anj\' -TaskName 'anj-w4-editors' -Confirm:$false -ErrorAction SilentlyContinue
  Get-Process notepad, wordpad, mspaint -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  $s = New-Object -ComObject Schedule.Service; $s.Connect()
  try { $s.GetFolder('\').DeleteFolder('anj', 0) } catch {}
  exit 0
}
Add-Type @'
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class Ids {
  [StructLayout(LayoutKind.Sequential)] public struct Info { public uint a; public long c, w, l; public uint vol, hi, links, idHi, idLo; }
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(SafeFileHandle h, out Info i);
  public static string Of(string path) {
    using (var f = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
      Info i; GetFileInformationByHandle(f.SafeFileHandle, out i); return i.idHi.ToString("x8") + i.idLo.ToString("x8");
    }
  }
}
'@
$folder = Join-Path $env:LOCALAPPDATA 'Temp\anj-w4-editors'
if (Test-Path $folder) { Remove-Item $folder -Recurse -Force }
New-Item -ItemType Directory $folder | Out-Null
Set-Content (Join-Path $folder 'note.txt') 'first line'
Set-Content (Join-Path $folder 'doc.rtf') '{\rtf1\ansi first line\par}'
Add-Type -AssemblyName System.Drawing
$bitmap = New-Object System.Drawing.Bitmap 64, 64
$bitmap.Save((Join-Path $folder 'pic.png'), [System.Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
$shell = New-Object -ComObject WScript.Shell
$events = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$watcher = New-Object IO.FileSystemWatcher $folder
$watcher.IncludeSubdirectories = $false
$watcher.NotifyFilter = 'FileName, LastWrite, Size, CreationTime'
foreach ($kind in 'Created', 'Changed', 'Deleted', 'Renamed') {
  Register-ObjectEvent $watcher $kind -MessageData $events -Action {
    $text = if ($Event.SourceEventArgs.OldName) { "$($Event.SourceEventArgs.ChangeType) $($Event.SourceEventArgs.OldName) -> $($Event.SourceEventArgs.Name)" } else { "$($Event.SourceEventArgs.ChangeType) $($Event.SourceEventArgs.Name)" }
    $Event.MessageData.Enqueue($text)
  } | Out-Null
}
$watcher.EnableRaisingEvents = $true
$results = [ordered]@{}
foreach ($case in @(
    @{ app = 'notepad.exe'; file = 'note.txt'; keys = '^{END}{ENTER}added by Notepad^s'; process = 'notepad' },
    @{ app = 'write.exe'; file = 'doc.rtf'; keys = '^{END}{ENTER}added by WordPad^s'; process = 'wordpad' },
    @{ app = 'mspaint.exe'; file = 'pic.png'; keys = '^a{DELETE}^s'; process = 'mspaint' })) {
  $path = Join-Path $folder $case.file
  $before = [Ids]::Of($path)
  $drop = $null; while ($events.TryDequeue([ref]$drop)) { }
  $process = Start-Process $case.app -ArgumentList "`"$path`"" -PassThru
  Start-Sleep 4
  $null = $shell.AppActivate($process.Id)
  Start-Sleep 1
  $shell.SendKeys($case.keys)
  Start-Sleep 4
  Get-Process $case.process -ErrorAction SilentlyContinue | Stop-Process -Force
  Start-Sleep 1
  $after = [Ids]::Of($path)
  $seen = @(); $item = $null; while ($events.TryDequeue([ref]$item)) { $seen += $item }
  $results[$case.process] = [ordered]@{
    file = $case.file; same_file_id = ($before -eq $after); events = $seen
    pattern = if ($before -eq $after) { 'in place (same file)' } else { 'replaced (new file under the name)' }
    others = @(Get-ChildItem $folder -Force | Where-Object { $_.Name -notin 'note.txt', 'doc.rtf', 'pic.png' } | ForEach-Object Name)
  }
  "$($case.process): $($results[$case.process].pattern); events: $($seen -join '; ')"
}
$watcher.EnableRaisingEvents = $false
$results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Evidence 'patterns.json')
Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue
