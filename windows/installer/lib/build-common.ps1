# Shared helpers for the Hey Logan AI Windows build scripts.
# Dot-source this file from build-setup.ps1 / build-portable.ps1 / build-all.ps1.

function Get-ReleaseRoot {
    # This file lives in <root>\windows\installer\lib
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

function Get-PayloadDefaultPath {
    param([string]$ReleaseRoot)
    return (Join-Path $ReleaseRoot 'windows\payload\HeyLoganAI')
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Format-Bytes {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes bytes"
}

# Files and folders every payload must contain. These are the launchers written
# for the release, the private Node.js runtime and the application itself.
$script:RequiredPayloadFiles = @(
    'Launch.vbs',
    'Start Console.cmd',
    'Stop.cmd',
    'Pairing.cmd',
    'Allow through Firewall.cmd',
    'HELP.txt',
    'heylogan.ico',
    'tools\pair.js',
    'tools\stop.ps1',
    'tools\firewall.ps1',
    'runtime\node.exe',
    'app\package.json',
    'app\server\index.js',
    'app\server\config.js',
    'app\public\index.html',
    'app\node_modules\selfsigned\index.js',
    'app\node_modules\qrcode\package.json'
)

function Assert-Payload {
    param(
        [Parameter(Mandatory)][string]$PayloadDir,
        # Set when validating the *source* payload folder (which may contain a
        # leftover app\data from a local smoke test - it is excluded when
        # staging and must never reach an artifact).
        [switch]$AllowAppData
    )

    if (-not (Test-Path -LiteralPath $PayloadDir -PathType Container)) {
        throw "Payload folder not found: $PayloadDir"
    }

    $missing = @()
    foreach ($relative in $script:RequiredPayloadFiles) {
        $full = Join-Path $PayloadDir $relative
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $missing += $relative }
    }
    if ($missing.Count -gt 0) {
        throw ("Payload is incomplete. Missing:`n  " + ($missing -join "`n  ") + "`n`nWait for the payload launcher scripts to be finished, then rebuild.")
    }

    # The package must never contain user data: app\data is created on first
    # start and is the one folder the installer/uninstaller must preserve.
    $dataDir = Join-Path $PayloadDir 'app\data'
    if (Test-Path -LiteralPath $dataDir) {
        if (-not $AllowAppData) {
            throw "Payload must not contain app\data (found: $dataDir). Remove it before building - user data is created on first run."
        }
        Write-Warning "Source payload contains a stray app\data (from a local smoke test); it is excluded from the staged package."
    }

    $nodeExe = Join-Path $PayloadDir 'runtime\node.exe'
    $nodeInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($nodeExe)
    $nodeSize = (Get-Item -LiteralPath $nodeExe).Length
    if ($nodeSize -lt 20MB) {
        throw "The bundled Node.js runtime looks wrong (runtime\node.exe is only $(Format-Bytes $nodeSize))."
    }

    $files = @(Get-ChildItem -LiteralPath $PayloadDir -Recurse -File -Force | Where-Object {
        $_.FullName -notlike (Join-Path $PayloadDir 'app\data\*')
    })
    $total = ($files | Measure-Object -Property Length -Sum).Sum

    return [pscustomobject]@{
        Path              = $PayloadDir
        FileCount         = $files.Count
        TotalBytes        = $total
        NodeVersion       = $nodeInfo.FileVersion
        NodeSizeBytes     = $nodeSize
        AppPackageVersion = ((Get-Content -LiteralPath (Join-Path $PayloadDir 'app\package.json') -Raw | ConvertFrom-Json).version)
        HasAppData        = (Test-Path -LiteralPath $dataDir)
    }
}

function Get-MakensisPath {
    param(
        [Parameter(Mandatory)][string]$ReleaseRoot,
        # Explicit path from -Makensis. When empty, search in this order:
        #   1. the NSIS toolchain bundled in this release tree
        #   2. %ProgramFiles%\NSIS\makensis.exe
        #   3. %ProgramFiles(x86)%\NSIS\makensis.exe
        #   4. makensis / makensis.exe on PATH
        [string]$Makensis = ''
    )

    if ($Makensis) {
        if (-not (Test-Path -LiteralPath $Makensis -PathType Leaf)) {
            throw "The -Makensis path does not exist: $Makensis"
        }
        return (Resolve-Path -LiteralPath $Makensis).Path
    }

    $tried = New-Object System.Collections.ArrayList
    $candidates = @(
        (Join-Path $ReleaseRoot '_toolchain\nsis\Bin\makensis.exe'),
        (Join-Path $ReleaseRoot '_toolchain\nsis\makensis.exe')
    )
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'NSIS\makensis.exe')
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates += (Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe')
    }
    foreach ($candidate in $candidates) {
        [void]$tried.Add($candidate)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $onPath = Get-Command 'makensis.exe' -ErrorAction SilentlyContinue
    if (-not $onPath) { $onPath = Get-Command 'makensis' -ErrorAction SilentlyContinue }
    [void]$tried.Add('PATH: makensis.exe / makensis (Get-Command)')
    if ($onPath) { return $onPath.Source }

    throw ("makensis.exe was not found. Tried:`n  " + ($tried -join "`n  ") + "`n`nInstall NSIS 3.x with Modern UI 2 and either add it to PATH, pass -Makensis <path-to-makensis.exe>, or keep the bundled toolchain in <release root>\_toolchain\nsis.")
}

function Format-NsisDefine {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    # NSIS accepts quoted /D values; quote whenever the value contains spaces
    # or quotes so the build also works from paths like C:\My Builds\...
    if ($Value -match '[\s"]') {
        $escaped = $Value.Replace('"', '""')
        return "/D$Name=`"$escaped`""
    }
    return "/D$Name=$Value"
}

function New-CleanDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Copy-PayloadTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    New-CleanDirectory -Path $Destination | Out-Null
    # app\data is user data (settings, token, certificates). It is created on
    # first start and is never part of a release artifact.
    $dataDir = Join-Path $Source 'app\data'
    $robocopy = Join-Path $env:WINDIR 'System32\robocopy.exe'
    if (Test-Path -LiteralPath $robocopy) {
        & $robocopy $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS /NP /XD $dataDir | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy failed with exit code $LASTEXITCODE while staging the payload."
        }
    }
    else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    }
    if (Test-Path -LiteralPath (Join-Path $Destination 'app\data')) {
        Remove-Item -LiteralPath (Join-Path $Destination 'app\data') -Recurse -Force
    }
}

function Write-ArtifactInfo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = 'Artifact'
    )
    $item = Get-Item -LiteralPath $Path
    $hash = Get-Sha256 -Path $Path
    Write-Host ''
    Write-Host "  $Label" -ForegroundColor Green
    Write-Host "    path   : $($item.FullName)"
    Write-Host "    size   : $($item.Length) bytes ($(Format-Bytes $item.Length))"
    Write-Host "    sha256 : $hash"
    return [pscustomobject]@{
        Path   = $item.FullName
        Name   = $item.Name
        Size   = $item.Length
        Sha256 = $hash
    }
}
