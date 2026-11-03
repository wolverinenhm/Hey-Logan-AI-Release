# Stop the Hey Logan AI bridge server started from this folder.
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
$found = @()
Get-CimInstance Win32_Process -Filter "Name='node.exe'" | ForEach-Object {
    $cmd = $_.CommandLine
    if ($cmd -and ($cmd.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
        ($cmd.IndexOf('server\index.js', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
         $cmd.IndexOf('server/index.js', [StringComparison]::OrdinalIgnoreCase) -ge 0)) {
        $found += $_
    }
}
if ($found.Count -eq 0) { exit 1 }
foreach ($proc in $found) {
    Stop-Process -Id $proc.ProcessId -Force
    Write-Host ("  Stopped server process " + $proc.ProcessId)
}
exit 0
