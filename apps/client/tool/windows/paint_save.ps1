# Saves -Path once in Paint, as a user would (spec #32 W4, #73 review 6):
# open it, select all, clear, Ctrl+S, close. Paint saves by deleting the
# file and creating a new one under the name (editor_patterns.ps1). Runs in
# the console session, unelevated (the W4 E2E calls it from its task).
# Prints the NTFS file id before and after.
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
Add-Type @'
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class PaintIds {
  [StructLayout(LayoutKind.Sequential)] public struct Info { public uint a; public long c, w, l; public uint vol, hi, links, idHi, idLo; }
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(SafeFileHandle h, out Info i);
  public static string Of(string path) {
    using (var f = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
      Info i; GetFileInformationByHandle(f.SafeFileHandle, out i); return i.idHi.ToString("x8") + i.idLo.ToString("x8");
    }
  }
}
'@
$before = [PaintIds]::Of($Path)
$shell = New-Object -ComObject WScript.Shell
$process = Start-Process mspaint.exe -ArgumentList "`"$Path`"" -PassThru
try {
  Start-Sleep 4
  $null = $shell.AppActivate($process.Id)
  Start-Sleep 1
  $shell.SendKeys('^a{DELETE}^s')
  Start-Sleep 4
} finally {
  Get-Process mspaint -ErrorAction SilentlyContinue | Stop-Process -Force
}
Start-Sleep 1
$after = [PaintIds]::Of($Path)
"before $before after $after replaced $($before -ne $after)"
