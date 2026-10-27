#Requires -Version 5.1
<#
.SYNOPSIS
    OmniControl PC installer for 64-bit Windows.

.DESCRIPTION
    Verifies or installs Python and uv, creates an isolated virtual
    environment, installs cactus-needle, downloads the windows-x86_64 Needle
    engine, writes a launcher, and creates a Desktop shortcut.

    The installer is per-user and does not require Administrator rights.

.PARAMETER InstallDir
    Application root. Defaults to the folder containing this script.
    Use -UserInstall for a per-user copy under %LOCALAPPDATA%.

.PARAMETER PythonVersion
    Python series used by uv. Default: 3.12.

.PARAMETER PackageSpec
    pip requirement for the runtime. Default: cactus-needle.
    A local wheel path is also accepted.

.PARAMETER EngineUrl
    Direct URL to the windows-x86_64 engine zip. When omitted, the latest
    GitHub release asset is discovered automatically.

.PARAMETER EngineArchive
    Local engine zip, folder, or needle.exe. Useful for offline installs.

.PARAMETER EngineSha256
    Expected SHA-256 of the engine zip. When omitted, a published
    "<url>.sha256" file is used if one exists.

.PARAMETER UserInstall
    Install a copy under %LOCALAPPDATA%\Programs\OmniControlPC.

.PARAMETER Upgrade
    Reinstall/upgrade cactus-needle even when it already imports.

.PARAMETER Force
    Recreate the virtual environment and reinstall the engine.

.EXAMPLE
    .\install.bat

.EXAMPLE
    .\install.bat -UserInstall -EngineArchive "D:\offline\needle-windows-x86_64.zip"
#>
[CmdletBinding()]
param(
    [string]$InstallDir,
    [string]$PythonVersion = '3.12',
    [string]$PackageSpec = 'cactus-needle faster-whisper sounddevice soundfile numpy',
    [string]$EngineUrl,
    [string]$EngineArchive,
    [string]$EngineSha256,
    [string]$ShortcutName = 'OmniControl PC',
    [switch]$UserInstall,
    [switch]$Upgrade,
    [switch]$Force,
    [switch]$SkipPython,
    [switch]$SkipEngine,
    [switch]$SkipShortcut,
    [switch]$SkipVerify,
    [switch]$NoCache,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstallerVersion = '1.0.0'
$script:ProductName      = 'OmniControl PC'
$script:GitHubRepo       = 'Wagustin/omnicontrolpc'
$script:DefaultEngineUrl = 'https://github.com/Wagustin/omnicontrolpc/releases/latest/download/needle-windows-x86_64.zip'
$script:UserAgent        = 'OmniControl-Installer/1.0'
$script:Utf8NoBom        = New-Object System.Text.UTF8Encoding($false)
$script:InstallDirGiven  = $PSBoundParameters.ContainsKey('InstallDir')
$script:RunFromFile      = -not [string]::IsNullOrEmpty($PSCommandPath)
$global:LASTEXITCODE     = 0

$script:InstallRoot = $null
$script:AppSourceRoot = $null
$script:DataDir     = $null
$script:VenvDir     = $null
$script:EngineDir   = $null
$script:LogFile     = $null
$script:Step        = 0
$script:TotalSteps  = 6
$script:EngineSourceLabel = ''

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    $Path = [Environment]::ExpandEnvironmentVariables($Path)
    if ($Path -eq '~') { return $HOME }
    if ($Path.StartsWith('~\') -or $Path.StartsWith('~/')) {
        $Path = Join-Path $HOME $Path.Substring(2)
    }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $Path))
}

function Remove-TrailingSeparator {
    param([Parameter(Mandatory)][string]$Path)
    $root = [IO.Path]::GetPathRoot($Path)
    if ($root -and $Path.Length -le $root.Length) { return $Path }
    return $Path.TrimEnd([char[]]@('\','/'))
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR','STEP','DEBUG')][string]$Level = 'INFO',
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    $line = '[{0}] [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try {
            [IO.File]::AppendAllText($script:LogFile, $line + [Environment]::NewLine, $script:Utf8NoBom)
        } catch { }
    }
    Write-Host $line -ForegroundColor $Color
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Title)
    $script:Step++
    Write-Log ("[{0}/{1}] {2}" -f $script:Step, $script:TotalSteps, $Title) 'STEP' ([ConsoleColor]::Cyan)
}

function Test-DirectoryWritable {
    param([Parameter(Mandatory)][string]$Path)
    try {
        [IO.Directory]::CreateDirectory($Path) | Out-Null
        $probe = Join-Path $Path ('.omnicontrol-write-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($probe, 'ok', $script:Utf8NoBom)
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$Description = '',
        [switch]$AllowFailure,
        [switch]$Quiet
    )
    if (-not $Description) { $Description = [IO.Path]::GetFileName($FilePath) }
    Write-Log ("Running: {0} {1}" -f $FilePath, ($Arguments -join ' ')) 'DEBUG' ([ConsoleColor]::DarkGray)

    $oldEap = $ErrorActionPreference
    $oldProgress = $ProgressPreference
    $ErrorActionPreference = 'Continue'
    $ProgressPreference = 'SilentlyContinue'
    $global:LASTEXITCODE = 0
    $captured = New-Object System.Collections.Generic.List[string]
    $code = 1
    try {
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
            $captured.Add($line)
            if (-not $Quiet) { Write-Host ('    ' + $line) }
        }
        $code = $global:LASTEXITCODE
    } catch {
        $code = 1
        $message = 'Could not start command: ' + $_.Exception.Message
        $captured.Add($message)
        Write-Host ('    ' + $message) -ForegroundColor Red
    } finally {
        $ErrorActionPreference = $oldEap
        $ProgressPreference = $oldProgress
        if ($captured.Count -gt 0 -and $script:LogFile) {
            try {
                $text = ($captured -join [Environment]::NewLine) + [Environment]::NewLine
                [IO.File]::AppendAllText($script:LogFile, $text, $script:Utf8NoBom)
            } catch { }
        }
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ("{0} failed with exit code {1}. See the log for details." -f $Description, $code)
    }
    return $code
}

function Get-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination,
        [int]$Attempts = 3,
        [int]$TimeoutSec = 600
    )
    if ($Uri -notmatch '^https://') {
        Write-Log "Downloading over a non-HTTPS URL: $Uri" 'WARN' ([ConsoleColor]::Yellow)
    }
    $parent = [IO.Path]::GetDirectoryName($Destination)
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }

    $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if (Test-Path -LiteralPath $Destination) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
        Write-Log ("Downloading (attempt {0}/{1}): {2}" -f $attempt, $Attempts, $Uri) 'INFO'
        $ok = $false

        if ($curl) {
            try {
                & $curl.Source --location --fail --silent --show-error --retry 2 --retry-delay 2 --connect-timeout 30 --user-agent $script:UserAgent --output $Destination $Uri
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $Destination)) { $ok = $true }
            } catch {
                Write-Log ("curl failed: {0}" -f $_.Exception.Message) 'WARN' ([ConsoleColor]::Yellow)
            }
        }

        if (-not $ok) {
            $oldEap = $ErrorActionPreference
            $oldProgress = $ProgressPreference
            $ErrorActionPreference = 'Continue'
            $ProgressPreference = 'SilentlyContinue'
            try {
                $headers = @{ 'User-Agent' = $script:UserAgent }
                Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -TimeoutSec $TimeoutSec -Headers $headers
                if (Test-Path -LiteralPath $Destination) { $ok = $true }
            } catch {
                Write-Log ("HTTP download failed: {0}" -f $_.Exception.Message) 'WARN' ([ConsoleColor]::Yellow)
            } finally {
                $ErrorActionPreference = $oldEap
                $ProgressPreference = $oldProgress
            }
        }

        if ($ok) {
            $size = (Get-Item -LiteralPath $Destination).Length
            if ($size -gt 0) {
                Write-Log ("Downloaded {0:N1} MB." -f ($size / 1MB)) 'OK' ([ConsoleColor]::Green)
                return
            }
            Write-Log 'The downloaded file is empty.' 'WARN' ([ConsoleColor]::Yellow)
        }
        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    throw "Could not download '$Uri' after $Attempts attempts. Check the network, proxy, or antivirus."
}

function Get-GitHubEngineAsset {
    try {
        $headers = @{
            'User-Agent' = $script:UserAgent
            'Accept'     = 'application/vnd.github+json'
        }
        $uri = "https://api.github.com/repos/$($script:GitHubRepo)/releases?per_page=10"
        $releases = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 60
        $assets = New-Object System.Collections.Generic.List[object]
        foreach ($release in @($releases)) {
            if ($release -and $release.assets) {
                foreach ($asset in @($release.assets)) { $assets.Add($asset) }
            }
        }
        $patterns = @(
            '(?i)(windows|win).*(x86[_-]?64|x64|amd64).*\.zip$',
            '(?i)(x86[_-]?64|x64|amd64).*(windows|win).*\.zip$',
            '(?i)(needle|engine).*(windows|win).*\.zip$',
            '(?i)(needle|engine).*\.zip$'
        )
        foreach ($pattern in $patterns) {
            $match = $assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
            if ($match) { return $match }
        }
    } catch {
        Write-Log ("GitHub release lookup failed: {0}" -f $_.Exception.Message) 'WARN' ([ConsoleColor]::Yellow)
    }
    return $null
}

function Get-PublishedSha256 {
    param([Parameter(Mandatory)][string]$Uri)
    $hashUri = $Uri + '.sha256'
    try {
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            $response = Invoke-WebRequest -Uri $hashUri -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = $script:UserAgent }
        } finally {
            $ProgressPreference = $oldProgress
        }
        if ($response.Content -is [byte[]]) {
            $text = [Text.Encoding]::UTF8.GetString($response.Content)
        } else {
            $text = [string]$response.Content
        }
        if ($text -match '(?i)\b([0-9a-f]{64})\b') { return $Matches[1].ToLowerInvariant() }
    } catch { }
    return $null
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        $hash = $sha.ComputeHash($stream)
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-PythonInfo {
    param([string]$Exe)
    if (-not $Exe -or -not (Test-Path -LiteralPath $Exe -PathType Leaf)) { return $null }
    try {
        $global:LASTEXITCODE = 0
        $output = & $Exe -c "import sys; print('%d.%d.%d' % sys.version_info[:3])" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }
        $raw = (@($output) -join ' ')
        if ($raw -notmatch '(\d+\.\d+\.\d+)') { return $null }
        $version = [version]$Matches[1]
        return [pscustomobject]@{ Path = $Exe; Version = $version }
    } catch {
        return $null
    }
}

function Get-PythonCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    $py = Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($py) {
        foreach ($series in @($PythonVersion, '3.13', '3.12', '3.11', '3.10', '3.9')) {
            try {
                $global:LASTEXITCODE = 0
                $exe = & $py.Source ('-' + $series) -c "import sys; print(sys.executable)" 2>$null
                if ($LASTEXITCODE -eq 0 -and $exe) {
                    $candidates.Add((@($exe) | Select-Object -First 1).ToString().Trim())
                }
            } catch { }
        }
    }

    foreach ($name in @('python.exe', 'python3.exe', 'python', 'python3')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { continue }
        try {
            $item = Get-Item -LiteralPath $cmd.Source -ErrorAction SilentlyContinue
            if ($item -and $item.Length -eq 0) { continue }
        } catch { }
        $candidates.Add($cmd.Source)
    }

    $roots = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $roots.Add((Join-Path $env:LOCALAPPDATA 'Programs\Python')) }
    if ($env:ProgramFiles) { $roots.Add($env:ProgramFiles) }
    if ($env:SystemDrive) { $roots.Add($env:SystemDrive + '\') }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try {
            Get-ChildItem -LiteralPath $root -Directory -Filter 'Python*' -ErrorAction SilentlyContinue | ForEach-Object {
                $exe = Join-Path $_.FullName 'python.exe'
                if (Test-Path -LiteralPath $exe -PathType Leaf) { $candidates.Add($exe) }
            }
        } catch { }
    }

    return ($candidates | Select-Object -Unique)
}

function Get-BestPython {
    $infos = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in @(Get-PythonCandidates)) {
        $info = Get-PythonInfo -Exe $candidate
        if ($info -and $info.Version -ge [version]'3.9') {
            if (-not ($infos | Where-Object { $_.Path -ieq $info.Path })) { $infos.Add($info) }
        }
    }
    if ($infos.Count -eq 0) { return $null }

    $preferred = $infos | Where-Object { $_.Version -eq [version]$PythonVersion } | Select-Object -First 1
    if ($preferred) { return $preferred }
    $modern = $infos | Where-Object { $_.Version -lt [version]'3.14' } | Sort-Object Version -Descending | Select-Object -First 1
    if ($modern) { return $modern }
    return ($infos | Sort-Object Version -Descending | Select-Object -First 1)
}

function Get-UvPath {
    foreach ($name in @('uv.exe', 'uv')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    $paths = New-Object System.Collections.Generic.List[string]
    if ($env:USERPROFILE) { $paths.Add((Join-Path $env:USERPROFILE '.local\bin\uv.exe')) }
    if ($env:LOCALAPPDATA) {
        $paths.Add((Join-Path $env:LOCALAPPDATA 'Programs\uv\uv.exe'))
        $paths.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\uv.exe'))
    }
    if ($env:CARGO_HOME) { $paths.Add((Join-Path $env:CARGO_HOME 'bin\uv.exe')) }
    if ($env:UV_INSTALL_DIR) { $paths.Add((Join-Path $env:UV_INSTALL_DIR 'uv.exe')) }
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    return $null
}

function Test-Uv {
    param([string]$Uv)
    if (-not $Uv) { return $false }
    try {
        $global:LASTEXITCODE = 0
        $null = & $Uv --version 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Install-Uv {
    if (-not $env:LOCALAPPDATA) {
        Write-Log 'LOCALAPPDATA is not set; cannot bootstrap uv.' 'WARN' ([ConsoleColor]::Yellow)
        return $null
    }
    $targetDir = Join-Path $env:LOCALAPPDATA 'Programs\uv'
    [IO.Directory]::CreateDirectory($targetDir) | Out-Null
    $tempScript = Join-Path ([IO.Path]::GetTempPath()) ('uv-install-' + [Guid]::NewGuid().ToString('N') + '.ps1')

    $oldInstallDir = $env:UV_INSTALL_DIR
    $oldNoModify = $env:UV_NO_MODIFY_PATH
    $env:UV_INSTALL_DIR = $targetDir
    $env:UV_NO_MODIFY_PATH = '1'
    try {
        Get-RemoteFile -Uri 'https://astral.sh/uv/install.ps1' -Destination $tempScript -Attempts 2 -TimeoutSec 120
        $hostExe = $null
        try { $hostExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
        if (-not $hostExe) {
            $pwsh = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($pwsh) { $hostExe = $pwsh.Source }
        }
        if (-not $hostExe) { throw 'Could not locate a PowerShell host executable.' }
        $code = Invoke-External -FilePath $hostExe -Arguments @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$tempScript) -Description 'uv installer' -AllowFailure
        if ($code -ne 0) {
            Write-Log 'The official uv installer failed; trying winget.' 'WARN' ([ConsoleColor]::Yellow)
            $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($winget) {
                $null = Invoke-External -FilePath $winget.Source -Arguments @('install','--id','astral-sh.uv','-e','--scope','user','--silent','--accept-package-agreements','--accept-source-agreements') -Description 'winget uv' -AllowFailure
            }
        }
    } catch {
        Write-Log ("uv bootstrap failed: {0}" -f $_.Exception.Message) 'WARN' ([ConsoleColor]::Yellow)
    } finally {
        $env:UV_INSTALL_DIR = $oldInstallDir
        $env:UV_NO_MODIFY_PATH = $oldNoModify
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }

    $uv = Get-UvPath
    if ($uv -and (Test-Uv $uv)) {
        Write-Log "uv is ready: $uv" 'OK' ([ConsoleColor]::Green)
        return $uv
    }
    return $null
}

function Install-PythonWithWinget {
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        Write-Log 'winget is not available on this system.' 'WARN' ([ConsoleColor]::Yellow)
        return $false
    }
    $id = 'Python.Python.' + $PythonVersion
    $code = Invoke-External -FilePath $winget.Source -Arguments @('install','--id',$id,'-e','--scope','user','--silent','--accept-package-agreements','--accept-source-agreements') -Description "winget install $id" -AllowFailure
    return ($code -eq 0)
}

function Resolve-PythonRuntime {
    $uv = Get-UvPath
    if ($uv -and -not (Test-Uv $uv)) {
        Write-Log "uv was found but does not run: $uv" 'WARN' ([ConsoleColor]::Yellow)
        $uv = $null
    }
    $python = Get-BestPython

    if ($SkipPython) {
        $existingVenv = Join-Path $script:VenvDir 'Scripts\python.exe'
        if (Test-Path -LiteralPath $existingVenv -PathType Leaf) {
            try {
                $global:LASTEXITCODE = 0
                $null = & $existingVenv -c "import sys" 2>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Log "Using the existing virtual environment: $existingVenv" 'OK' ([ConsoleColor]::Green)
                    return [pscustomobject]@{ Uv = $null; Python = $null; ReuseVenv = $true }
                }
            } catch { }
        }
        if (-not $python) { throw 'No usable Python 3.9+ was found and -SkipPython was specified.' }
        Write-Log "Using existing Python: $($python.Path) ($($python.Version))" 'OK' ([ConsoleColor]::Green)
        return [pscustomobject]@{ Uv = $uv; Python = $python; ReuseVenv = $false }
    }

    if (-not $uv -and -not $python) {
        Write-Log 'Python and uv were not found. Bootstrapping uv...' 'INFO'
        $uv = Install-Uv
    }

    if (-not $uv -and -not $python) {
        Write-Log 'Trying to install Python with winget...' 'INFO'
        if (Install-PythonWithWinget) { $python = Get-BestPython }
    }

    if (-not $python -and $uv) {
        Write-Log "Installing Python $PythonVersion with uv..." 'INFO'
        $null = Invoke-External -FilePath $uv -Arguments @('python','install',$PythonVersion) -Description "uv python install $PythonVersion"
    }

    if (-not $uv -and -not $python) {
        throw 'Could not find or install Python 3.9+ or uv. Install Python from https://www.python.org/downloads/windows/ and run install.bat again.'
    }

    if ($python) {
        Write-Log "Python selected: $($python.Path) ($($python.Version))" 'OK' ([ConsoleColor]::Green)
        if ($python.Version -ge [version]'3.13') {
            Write-Log "Python $($python.Version) is very new; Python 3.12 is the safest choice for binary wheels." 'WARN' ([ConsoleColor]::Yellow)
        }
    } else {
        Write-Log "uv will provide Python $PythonVersion." 'OK' ([ConsoleColor]::Green)
    }
    return [pscustomobject]@{ Uv = $uv; Python = $python }
}

function New-OrUpdateVenv {
    param([Parameter(Mandatory)][pscustomobject]$Runtime)

    $venvPython = Join-Path $script:VenvDir 'Scripts\python.exe'
    $valid = $false
    if ((Test-Path -LiteralPath $venvPython -PathType Leaf) -and -not $Force) {
        try {
            $global:LASTEXITCODE = 0
            $raw = & $venvPython -c "import sys; print('%d.%d.%d' % sys.version_info[:3])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $text = (@($raw) | Select-Object -First 1).ToString().Trim()
                if ($text -match '\d+\.\d+\.\d+') {
                    $valid = ([version]$Matches[0] -ge [version]'3.9')
                }
            }
        } catch { $valid = $false }
    }

    if ($valid) {
        Write-Log "Reusing virtual environment: $($script:VenvDir)" 'OK' ([ConsoleColor]::Green)
    } else {
        if (Test-Path -LiteralPath $script:VenvDir) {
            $stamp = Get-Date -Format 'yyyyMMddHHmmss'
            $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 6)
            $backup = $script:VenvDir + '.broken-' + $stamp + '-' + $suffix
            Write-Log "Moving the unusable virtual environment to: $backup" 'WARN' ([ConsoleColor]::Yellow)
            try {
                Move-Item -LiteralPath $script:VenvDir -Destination $backup -Force
            } catch {
                throw "Could not move '$($script:VenvDir)'. Close any running OmniControl window and retry. $($_.Exception.Message)"
            }
        }

        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($script:VenvDir)) | Out-Null
        $created = $false

        if ($Runtime.Uv) {
            Write-Log "Creating virtual environment with uv (Python $PythonVersion)..." 'INFO'
            $code = Invoke-External -FilePath $Runtime.Uv -Arguments @('venv','--seed','--python',$PythonVersion,$script:VenvDir) -Description 'uv venv' -AllowFailure
            if ($code -eq 0 -and (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
                $created = $true
            } else {
                Write-Log 'uv could not create the environment; falling back to python -m venv.' 'WARN' ([ConsoleColor]::Yellow)
            }
        }

        if (-not $created -and $Runtime.Python) {
            Write-Log "Creating virtual environment with $($Runtime.Python.Path)..." 'INFO'
            $null = Invoke-External -FilePath $Runtime.Python.Path -Arguments @('-m','venv','--clear',$script:VenvDir) -Description 'python -m venv'
            $created = (Test-Path -LiteralPath $venvPython -PathType Leaf)
        }

        if (-not $created) { throw 'Could not create the Python virtual environment.' }
    }

    $versionText = ''
    try {
        $global:LASTEXITCODE = 0
        $raw = & $venvPython -c "import sys; print('%d.%d.%d' % sys.version_info[:3])" 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) { $versionText = (@($raw) | Select-Object -First 1).ToString().Trim() }
    } catch { }
    if (-not $versionText) { throw 'The virtual environment Python does not run.' }

    Write-Log "Virtual environment ready (Python $versionText): $($script:VenvDir)" 'OK' ([ConsoleColor]::Green)
    return [pscustomobject]@{ Python = $venvPython; Version = $versionText }
}

function Install-PythonPackage {
    param(
        [Parameter(Mandatory)][string]$VenvPython,
        [string]$Uv
    )

    $alreadyInstalled = $false
    if (-not $Force -and -not $Upgrade) {
        try {
            $global:LASTEXITCODE = 0
            $null = & $VenvPython -c "from needle import Needle" 2>$null
            $alreadyInstalled = ($LASTEXITCODE -eq 0)
        } catch { $alreadyInstalled = $false }
    }

    if ($alreadyInstalled) {
        Write-Log "$PackageSpec is already installed (use -Upgrade to update it)." 'OK' ([ConsoleColor]::Green)
    } else {
        $installed = $false
        if ($Uv) {
            $uvArgs = @('pip','install','--python',$VenvPython,'--upgrade', $PackageSpec)
            if ($NoCache) { $uvArgs += '--no-cache' }
            $code = Invoke-External -FilePath $Uv -Arguments $uvArgs -Description "uv pip install $PackageSpec" -AllowFailure
            $installed = ($code -eq 0)
            if (-not $installed) {
                Write-Log 'uv pip install failed; retrying with the venv pip.' 'WARN' ([ConsoleColor]::Yellow)
            }
        }

        if (-not $installed) {
            $null = Invoke-External -FilePath $VenvPython -Arguments @('-m','ensurepip','--upgrade') -Description 'ensurepip' -AllowFailure -Quiet
            $null = Invoke-External -FilePath $VenvPython -Arguments @('-m','pip','install','--upgrade','pip','setuptools','wheel','--disable-pip-version-check','--retries','5','--timeout','60') -Description 'pip bootstrap'
            $pipArgs = @('-m','pip','install','--upgrade','--prefer-binary','--disable-pip-version-check','--retries','5','--timeout','60', $PackageSpec)
            if ($NoCache) { $pipArgs += '--no-cache-dir' }
            $null = Invoke-External -FilePath $VenvPython -Arguments $pipArgs -Description "pip install $PackageSpec"
        }
    }

    if (-not $SkipVerify) {
        if (Test-PackageImport -VenvPython $VenvPython) {
            Write-Log "$PackageSpec import verified." 'OK' ([ConsoleColor]::Green)
        } else {
            Write-Log 'Import check failed; it will be retried after the engine is installed.' 'WARN' ([ConsoleColor]::Yellow)
        }
    }

    $null = Invoke-External -FilePath $VenvPython -Arguments @('-m','pip','check') -Description 'pip check' -AllowFailure -Quiet
}

function Test-PackageImport {
    param([Parameter(Mandatory)][string]$VenvPython)
    try {
        $global:LASTEXITCODE = 0
        $null = & $VenvPython -c "from needle import Needle" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

function Test-PeX64 {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object IO.BinaryReader($stream)
            if ($reader.ReadUInt16() -ne 0x5A4D) { return $false }
            $stream.Position = 0x3C
            $peOffset = $reader.ReadInt32()
            if ($peOffset -lt 0 -or $peOffset -gt ($stream.Length - 6)) { return $false }
            $stream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x00004550) { return $false }
            $machine = $reader.ReadUInt16()
            return ($machine -eq 0x8664)
        } finally {
            $stream.Dispose()
        }
    } catch {
        return $false
    }
}

function Expand-ZipArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$WorkDir
    )
    $extractDir = Join-Path $WorkDir 'extract'
    [IO.Directory]::CreateDirectory($extractDir) | Out-Null
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $total = 0
        $extractFull = [IO.Path]::GetFullPath($extractDir)
        $extractPrefix = $extractFull
        if (-not $extractPrefix.EndsWith([IO.Path]::DirectorySeparatorChar)) {
            $extractPrefix += [IO.Path]::DirectorySeparatorChar
        }
        foreach ($entry in $zip.Entries) {
            $total += $entry.Length
            $entryName = $entry.FullName -replace '\\', '/'
            $target = [IO.Path]::GetFullPath((Join-Path $extractFull $entryName))
            if (-not $target.StartsWith($extractPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "The archive contains an unsafe path: $($entry.FullName)"
            }
        }
        if ($total -gt 2GB) { throw 'The engine archive is unexpectedly large; refusing to extract it.' }
    } finally {
        $zip.Dispose()
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $extractDir)
    return $extractDir
}

function Install-EnginePayload {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$SourceLabel
    )
    $engineParent = [IO.Path]::GetDirectoryName($script:EngineDir)
    [IO.Directory]::CreateDirectory($engineParent) | Out-Null
    $staging = Join-Path $engineParent ('engine.staging-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null

    try {
        $executables = @(Get-ChildItem -LiteralPath $SourceDir -Filter 'needle.exe' -Recurse -File -ErrorAction SilentlyContinue)
        if ($executables.Count -eq 0) { throw "needle.exe was not found in $SourceLabel." }
        $exe = $executables | Where-Object { $_.FullName -match '(?i)(x86[_-]?64|amd64|win64)' } | Select-Object -First 1
        if (-not $exe) { $exe = $executables | Select-Object -First 1 }

        Get-ChildItem -LiteralPath $exe.DirectoryName -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $staging -Recurse -Force
        }
        foreach ($name in @('needle3.cact','needle.h','libneedle.a')) {
            $destination = Join-Path $staging $name
            if (Test-Path -LiteralPath $destination) { continue }
            $found = Get-ChildItem -LiteralPath $SourceDir -Filter $name -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { Copy-Item -LiteralPath $found.FullName -Destination $destination -Force }
        }
        Get-ChildItem -LiteralPath $SourceDir -Filter '*.dll' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $staging -Force -ErrorAction SilentlyContinue
        }

        Get-ChildItem -LiteralPath $staging -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { Unblock-File -LiteralPath $_.FullName } catch { }
        }

        $stagedExe = Join-Path $staging 'needle.exe'
        if (-not (Test-PeX64 $stagedExe)) {
            throw 'needle.exe is not a valid 64-bit Windows executable. The release asset may be corrupt.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $staging 'needle3.cact') -PathType Leaf)) {
            Write-Log 'needle3.cact is missing from the engine package; the engine may not have embedded weights.' 'WARN' ([ConsoleColor]::Yellow)
        }

        if (Test-Path -LiteralPath $script:EngineDir) {
            $backup = $script:EngineDir + '.bak-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            Move-Item -LiteralPath $script:EngineDir -Destination $backup -Force
            try {
                Move-Item -LiteralPath $staging -Destination $script:EngineDir -Force
            } catch {
                Move-Item -LiteralPath $backup -Destination $script:EngineDir -Force
                throw
            }
            Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Move-Item -LiteralPath $staging -Destination $script:EngineDir -Force
        }

        Write-Log "Needle engine installed: $($script:EngineDir)" 'OK' ([ConsoleColor]::Green)
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-BundledEngineDirs {
    $dirs = New-Object System.Collections.Generic.List[string]
    $roots = @($script:InstallRoot, $PSScriptRoot) | Select-Object -Unique
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $dirs.Add((Join-Path $root 'windows-x86_64\windows-x86_64'))
        $dirs.Add((Join-Path $root 'windows-x86_64'))
        $dirs.Add((Join-Path $root 'engine\windows-x86_64'))
    }
    return $dirs
}

function Install-NeedleEngine {
    $existing = Join-Path $script:EngineDir 'needle.exe'
    if (-not $SkipEngine -and -not $Force -and (Test-Path -LiteralPath $existing -PathType Leaf) -and (Test-PeX64 $existing)) {
        Write-Log "Engine already installed: $existing" 'OK' ([ConsoleColor]::Green)
        return
    }
    if ($SkipEngine) {
        Write-Log 'Engine download skipped (-SkipEngine).' 'WARN' ([ConsoleColor]::Yellow)
        return
    }

    $source = $EngineArchive
    $url = $EngineUrl
    if (-not $url) { $url = $env:OMNICONTROL_ENGINE_URL }
    $downloadHash = $null

    if (-not $source -and -not $url) {
        foreach ($candidate in @(Get-BundledEngineDirs)) {
            if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'needle.exe') -PathType Leaf)) {
                $source = $candidate
                break
            }
        }
    }

    if (-not $source -and -not $url) {
        $asset = Get-GitHubEngineAsset
        if ($asset) {
            $url = $asset.browser_download_url
            Write-Log "Discovered release asset: $($asset.name)" 'INFO'
        } else {
            $url = $script:DefaultEngineUrl
            Write-Log 'No release asset was discovered; trying the default URL.' 'WARN' ([ConsoleColor]::Yellow)
        }
    }

    $workDir = Join-Path ([IO.Path]::GetTempPath()) ('omnicontrol-engine-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($workDir) | Out-Null

    try {
        if ($source) {
            $script:EngineSourceLabel = $source
            if (-not (Test-Path -LiteralPath $source)) { throw "Engine archive not found: $source" }
            $item = Get-Item -LiteralPath $source
            $localExpected = $EngineSha256
            if (-not $localExpected) { $localExpected = $env:OMNICONTROL_ENGINE_SHA256 }
            if (-not $item.PSIsContainer -and $localExpected) {
                $localHash = Get-FileSha256 -Path $item.FullName
                $wanted = ($localExpected -replace '[^0-9a-fA-F]', '').ToLowerInvariant()
                if ($localHash -ne $wanted) {
                    throw "Engine checksum mismatch. Expected $wanted but got $localHash."
                }
                Write-Log 'Local engine SHA-256 verified.' 'OK' ([ConsoleColor]::Green)
            }
            if ($item.PSIsContainer) {
                Install-EnginePayload -SourceDir $item.FullName -SourceLabel $source
            } elseif ($item.Extension -ieq '.exe') {
                $stage = Join-Path $workDir 'single'
                [IO.Directory]::CreateDirectory($stage) | Out-Null
                Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $stage 'needle.exe') -Force
                $model = Join-Path $item.DirectoryName 'needle3.cact'
                if (Test-Path -LiteralPath $model) { Copy-Item -LiteralPath $model -Destination $stage -Force }
                Install-EnginePayload -SourceDir $stage -SourceLabel $source
            } elseif ($item.Extension -ieq '.zip') {
                $extracted = Expand-ZipArchive -ArchivePath $item.FullName -WorkDir $workDir
                Install-EnginePayload -SourceDir $extracted -SourceLabel $source
            } else {
                throw "Unsupported engine archive '$($item.Name)'. Use a .zip, a folder, or needle.exe."
            }
        } else {
            $script:EngineSourceLabel = $url
            $expected = $EngineSha256
            if (-not $expected) { $expected = $env:OMNICONTROL_ENGINE_SHA256 }
            if (-not $expected) { $expected = Get-PublishedSha256 -Uri $url }

            $download = Join-Path $workDir 'needle-engine.download'
            Get-RemoteFile -Uri $url -Destination $download
            $downloadHash = Get-FileSha256 -Path $download

            if ($expected) {
                $normalized = ($expected -replace '[^0-9a-fA-F]', '').ToLowerInvariant()
                if ($downloadHash -ne $normalized) {
                    throw "Engine checksum mismatch. Expected $normalized but got $downloadHash."
                }
                Write-Log 'Engine SHA-256 verified.' 'OK' ([ConsoleColor]::Green)
            } else {
                Write-Log 'No published checksum found; recorded the download hash in install.json.' 'WARN' ([ConsoleColor]::Yellow)
            }

            $header = New-Object byte[] 4
            $stream = [IO.File]::OpenRead($download)
            try {
                $read = $stream.Read($header, 0, 4)
            } finally {
                $stream.Dispose()
            }
            if ($read -lt 4) { throw 'The downloaded engine file is too small.' }
            $isZip = ($header[0] -eq 0x50 -and $header[1] -eq 0x4B)
            $isPe = ($header[0] -eq 0x4D -and $header[1] -eq 0x5A)

            if ($isZip) {
                $extracted = Expand-ZipArchive -ArchivePath $download -WorkDir $workDir
                Install-EnginePayload -SourceDir $extracted -SourceLabel $url
            } elseif ($isPe) {
                $stage = Join-Path $workDir 'single'
                [IO.Directory]::CreateDirectory($stage) | Out-Null
                Copy-Item -LiteralPath $download -Destination (Join-Path $stage 'needle.exe') -Force
                $model = Join-Path $script:EngineDir 'needle3.cact'
                if (Test-Path -LiteralPath $model -PathType Leaf) {
                    Copy-Item -LiteralPath $model -Destination $stage -Force
                } else {
                    foreach ($candidate in @(Get-BundledEngineDirs)) {
                        $bundledModel = Join-Path $candidate 'needle3.cact'
                        if (Test-Path -LiteralPath $bundledModel -PathType Leaf) {
                            Copy-Item -LiteralPath $bundledModel -Destination $stage -Force
                            break
                        }
                    }
                }
                Write-Log 'The URL returned a bare needle.exe; needle3.cact may be missing.' 'WARN' ([ConsoleColor]::Yellow)
                Install-EnginePayload -SourceDir $stage -SourceLabel $url
            } else {
                throw 'The downloaded engine is neither a zip archive nor a Windows executable.'
            }
        }

        if ($downloadHash) {
            $metadata = [pscustomobject]@{
                source      = $script:EngineSourceLabel
                installedAt = (Get-Date).ToString('o')
                sha256      = $downloadHash
                architecture = 'x86_64'
            }
            try {
                $json = $metadata | ConvertTo-Json
                [IO.File]::WriteAllText((Join-Path $script:EngineDir 'engine.json'), $json, $script:Utf8NoBom)
            } catch {
                Write-Log ("Could not write engine.json: {0}" -f $_.Exception.Message) 'WARN' ([ConsoleColor]::Yellow)
            }
        }
    } finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-AppPayload {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DestinationRoot
    )
    $sourceFull = Remove-TrailingSeparator (Get-FullPath $SourceRoot)
    $destinationFull = Remove-TrailingSeparator (Get-FullPath $DestinationRoot)
    $sameDirectory = ($sourceFull -ieq $destinationFull)

    [IO.Directory]::CreateDirectory($DestinationRoot) | Out-Null
    foreach ($relative in @('jarvis_client.py','schemas')) {
        if ($sameDirectory) { continue }
        $source = Join-Path $SourceRoot $relative
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $destination = Join-Path $DestinationRoot $relative
        if (Test-Path -LiteralPath $source -PathType Container) {
            [IO.Directory]::CreateDirectory($destination) | Out-Null
            Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
            }
        } else {
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $DestinationRoot 'jarvis_client.py') -PathType Leaf)) {
        throw "jarvis_client.py is missing from $DestinationRoot."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $DestinationRoot 'schemas\tools.json') -PathType Leaf)) {
        throw "schemas\tools.json is missing from $DestinationRoot."
    }
}

function Install-AppPayloadFromSource {
    param([Parameter(Mandatory)][string]$DestinationRoot)

    if ($script:AppSourceRoot -and (Test-Path -LiteralPath (Join-Path $script:AppSourceRoot 'jarvis_client.py') -PathType Leaf)) {
        Install-AppPayload -SourceRoot $script:AppSourceRoot -DestinationRoot $DestinationRoot
        return
    }

    $client = Join-Path $DestinationRoot 'jarvis_client.py'
    $tools = Join-Path $DestinationRoot 'schemas\tools.json'
    if (-not $Force -and -not $Upgrade -and (Test-Path -LiteralPath $client -PathType Leaf) -and (Test-Path -LiteralPath $tools -PathType Leaf)) {
        Write-Log "Application files already present: $DestinationRoot" 'OK' ([ConsoleColor]::Green)
        return
    }

    Write-Log 'Downloading the application files from GitHub...' 'INFO'
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ('omnicontrol-app-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($workDir) | Out-Null
    try {
        $archive = Join-Path $workDir 'source.zip'
        $url = "https://github.com/$($script:GitHubRepo)/archive/refs/heads/main.zip"
        Get-RemoteFile -Uri $url -Destination $archive
        $extracted = Expand-ZipArchive -ArchivePath $archive -WorkDir $workDir
        $found = Get-ChildItem -LiteralPath $extracted -Filter 'jarvis_client.py' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $found) { throw 'jarvis_client.py was not found in the downloaded repository archive.' }
        Install-AppPayload -SourceRoot $found.DirectoryName -DestinationRoot $DestinationRoot
    } finally {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-Launcher {
    $launcherPs1 = @'
# OmniControl PC launcher (generated by install.ps1)
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Command
)

$ErrorActionPreference = 'Stop'
$dataDir = $PSScriptRoot
$root = [IO.Path]::GetDirectoryName($dataDir)
$python = Join-Path $dataDir '.venv\Scripts\python.exe'
$client = Join-Path $root 'jarvis_client.py'
$engineDir = Join-Path $dataDir 'engine\windows-x86_64'

if (-not (Test-Path -LiteralPath $client -PathType Leaf)) {
    Write-Host "[ERROR] jarvis_client.py was not found in $root" -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    $cmd = Get-Command python.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) {
        Write-Host '[ERROR] The Python environment is missing. Re-run install.bat.' -ForegroundColor Red
        Read-Host 'Press Enter to close'
        exit 1
    }
    $python = $cmd.Source
}

$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
if (Test-Path -LiteralPath $engineDir -PathType Container) {
    $env:Path = $engineDir + ';' + $env:Path
}
Set-Location -LiteralPath $root

function Invoke-OmniControl([string]$Text) {
    & $python $client $Text
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[!] The command returned exit code $LASTEXITCODE." -ForegroundColor Yellow
    }
}

if ($Command.Count -gt 0) {
    if ($Command[0] -in @('--help', '-h', '/?', 'help')) {
        Write-Host 'Usage: OmniControl.cmd "sube el volumen al 50%"'
        Write-Host '       OmniControl.cmd            (interactive prompt)'
        exit 0
    }
    Invoke-OmniControl ($Command -join ' ')
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host '  OmniControl PC' -ForegroundColor Cyan
Write-Host '  Offline assistant. Type a command in Spanish, or "exit" to quit.' -ForegroundColor Gray
Write-Host '  Examples: "sube el volumen al 50%", "abre el campus virtual"' -ForegroundColor DarkGray
Write-Host ''
while ($true) {
    $line = Read-Host 'OmniControl'
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if ($line.Length -eq 0) { continue }
    if ($line -match '^(exit|quit|salir)$') { break }
    try { Invoke-OmniControl $line }
    catch { Write-Host "[!] $($_.Exception.Message)" -ForegroundColor Red }
}
'@

    $launcherCmd = @'
@echo off
setlocal EnableExtensions
set "DATA=%~dp0"
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
    set "PS_EXE=pwsh.exe"
) else if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    set "PS_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
) else (
    set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
)
if not exist "%PS_EXE%" if /I not "%PS_EXE%"=="pwsh.exe" set "PS_EXE=powershell.exe"
"%PS_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%DATA%OmniControl.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
'@

    $launcherPs1 = $launcherPs1 -replace "`r?`n", "`r`n"
    $launcherCmd = $launcherCmd -replace "`r?`n", "`r`n"
    $ps1Path = Join-Path $script:DataDir 'OmniControl.ps1'
    $cmdPath = Join-Path $script:DataDir 'OmniControl.cmd'
    [IO.File]::WriteAllText($ps1Path, $launcherPs1, $script:Utf8NoBom)
    [IO.File]::WriteAllText($cmdPath, $launcherCmd, $script:Utf8NoBom)
    Write-Log "Launcher written: $cmdPath" 'OK' ([ConsoleColor]::Green)
    return $cmdPath
}

function Get-DesktopPath {
    $candidates = New-Object System.Collections.Generic.List[string]
    try { $candidates.Add([Environment]::GetFolderPath('DesktopDirectory')) } catch { }
    if ($env:USERPROFILE) { $candidates.Add((Join-Path $env:USERPROFILE 'Desktop')) }
    foreach ($name in @('OneDrive','OneDriveConsumer','OneDriveCommercial')) {
        $base = [Environment]::GetEnvironmentVariable($name)
        if ($base) { $candidates.Add((Join-Path $base 'Desktop')) }
    }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) { return $candidate }
    }
    if (-not $env:USERPROFILE) { throw 'Could not locate the Desktop folder.' }
    $fallback = Join-Path $env:USERPROFILE 'Desktop'
    [IO.Directory]::CreateDirectory($fallback) | Out-Null
    return $fallback
}

function New-DesktopShortcut {
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$IconPath
    )
    if ($SkipShortcut) {
        Write-Log 'Desktop shortcut skipped (-SkipShortcut).' 'WARN' ([ConsoleColor]::Yellow)
        return $null
    }
    if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
        throw "Launcher not found: $LauncherPath"
    }

    $desktop = Get-DesktopPath
    $safeName = ($ShortcutName -replace '[\\/:*?"<>|]', '').Trim()
    if (-not $safeName) { $safeName = $script:ProductName }
    $linkPath = Join-Path $desktop ($safeName + '.lnk')

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($linkPath)
        $shortcut.TargetPath = $LauncherPath
        $shortcut.WorkingDirectory = $WorkingDirectory
        $shortcut.Description = 'OmniControl PC - offline system assistant'
        $shortcut.WindowStyle = 1
        if ($IconPath -and (Test-Path -LiteralPath $IconPath -PathType Leaf) -and $IconPath -notmatch ',') {
            $shortcut.IconLocation = "$IconPath,0"
        }
        $shortcut.Save()
    } finally {
        if ($shortcut) { try { [Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut) | Out-Null } catch { } }
        if ($shell) { try { [Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null } catch { } }
    }

    if (-not (Test-Path -LiteralPath $linkPath -PathType Leaf)) {
        throw "The shortcut was not created: $linkPath"
    }
    Write-Log "Desktop shortcut created: $linkPath" 'OK' ([ConsoleColor]::Green)
    return $linkPath
}

function Initialize-Environment {
    $defaultRoot = $PSScriptRoot
    if (-not $defaultRoot) { $defaultRoot = (Get-Location).ProviderPath }
    $localPayload = (Test-Path -LiteralPath (Join-Path $defaultRoot 'jarvis_client.py') -PathType Leaf)
    $script:AppSourceRoot = if ($localPayload) { $defaultRoot } else { $null }

    $root = $InstallDir
    if ($UserInstall) {
        if (-not $root) { $root = Join-Path $env:LOCALAPPDATA 'Programs\OmniControlPC' }
    } elseif (-not $root) {
        if ($localPayload -and $script:RunFromFile) {
            $root = $defaultRoot
        } else {
            $root = Join-Path $env:LOCALAPPDATA 'Programs\OmniControlPC'
        }
    }
    $root = Remove-TrailingSeparator (Get-FullPath $root)

    if (-not (Test-DirectoryWritable $root)) {
        if ($script:InstallDirGiven -or $UserInstall) {
            throw "The install directory is not writable: $root"
        }
        $fallback = Join-Path $env:LOCALAPPDATA 'Programs\OmniControlPC'
        Write-Host "[WARN] The project folder is not writable; installing to $fallback" -ForegroundColor Yellow
        $root = $fallback
        if (-not (Test-DirectoryWritable $root)) {
            throw "The install directory is not writable: $root"
        }
    }

    if ($root -like '\\*') {
        Write-Host '[WARN] Installing to a network path can make Python and NTFS permissions unreliable.' -ForegroundColor Yellow
    }
    if ($root -match '(?i)onedrive') {
        Write-Host '[WARN] OneDrive can lock files during synchronization. Consider -UserInstall.' -ForegroundColor Yellow
    }

    $script:InstallRoot = $root
    $script:DataDir = Join-Path $root '.omnicontrol'
    $script:VenvDir = Join-Path $script:DataDir '.venv'
    $script:EngineDir = Join-Path $script:DataDir 'engine\windows-x86_64'
    $script:LogFile = Join-Path $script:DataDir 'install.log'
    [IO.Directory]::CreateDirectory($script:DataDir) | Out-Null

    if ((Test-Path -LiteralPath $script:LogFile -PathType Leaf) -and (Get-Item -LiteralPath $script:LogFile).Length -gt 5MB) {
        Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.1') -Force -ErrorAction SilentlyContinue
    }

    Write-Log ("{0} installer {1}" -f $script:ProductName, $script:InstallerVersion) 'INFO'
    Write-Log ("Install root: {0}" -f $script:InstallRoot) 'INFO'
    Write-Log ("PowerShell: {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) 'INFO'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }
    if (-not $SkipPython) { $env:PIP_DISABLE_PIP_VERSION_CHECK = '1' }
    $env:PIP_NO_INPUT = '1'
    $env:UV_HTTP_TIMEOUT = '120'
    $env:PYTHONUTF8 = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    $env:NO_COLOR = '1'
    $env:CLICOLOR = '0'
}

function Assert-Preflight {
    try {
        $parsedVersion = [version]$PythonVersion
    } catch {
        throw "Invalid -PythonVersion '$PythonVersion'. Use a value such as 3.12."
    }
    if ($parsedVersion.Major -ne 3 -or $parsedVersion -lt [version]'3.9') {
        throw "Python $PythonVersion is not supported; use Python 3.9 through 3.13 (3.12 recommended)."
    }
    if (-not $PackageSpec -or $PackageSpec.StartsWith('-')) {
        throw 'Invalid -PackageSpec. Pass a package name, a requirement, or a wheel path.'
    }

    if ($env:OS -ne 'Windows_NT') { throw 'This installer targets Windows.' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit version of Windows is required.' }

    $architecture = $env:PROCESSOR_ARCHITECTURE
    if (-not $architecture -and $env:PROCESSOR_ARCHITEW6432) { $architecture = $env:PROCESSOR_ARCHITEW6432 }
    if ($architecture -and $architecture -notin @('AMD64','ARM64')) {
        Write-Log "Unexpected processor architecture: $architecture" 'WARN' ([ConsoleColor]::Yellow)
    }
    if ($architecture -eq 'ARM64') {
        Write-Log 'ARM64 detected; the x86-64 engine will run under Windows emulation.' 'WARN' ([ConsoleColor]::Yellow)
    }
    if ([Environment]::OSVersion.Version -lt [version]'10.0') {
        Write-Log 'Windows 10 or newer is recommended; current Python builds may not support this Windows version.' 'WARN' ([ConsoleColor]::Yellow)
    }

    try {
        $root = [IO.Path]::GetPathRoot($script:InstallRoot)
        if ($root -and $root -notlike '\\*') {
            $drive = New-Object -TypeName IO.DriveInfo -ArgumentList $root
            $freeMb = [math]::Floor($drive.AvailableFreeSpace / 1MB)
            if ($freeMb -lt 512) {
                throw "At least 512 MB of free space is required; only $freeMb MB is available."
            } elseif ($freeMb -lt 1024) {
                Write-Log "Low disk space: $freeMb MB free. 1 GB or more is recommended." 'WARN' ([ConsoleColor]::Yellow)
            } else {
                Write-Log "Free disk space: $freeMb MB." 'INFO'
            }
        }
    } catch {
        if ($_.Exception.Message -like 'At least 512 MB*') { throw }
        Write-Log ("Could not check free disk space: {0}" -f $_.Exception.Message) 'WARN' ([ConsoleColor]::Yellow)
    }

    if ($script:InstallRoot.Length -gt 180) {
        Write-Log 'The install path is very long; some tools may fail unless long-path support is enabled.' 'WARN' ([ConsoleColor]::Yellow)
    }
}

function Save-Manifest {
    param(
        [string]$VenvPython,
        [string]$VenvVersion,
        [string]$UvPath,
        [string]$ShortcutPath
    )
    $manifest = [pscustomobject]@{
        product          = $script:ProductName
        installerVersion = $script:InstallerVersion
        installedAt      = (Get-Date).ToString('o')
        installRoot      = $script:InstallRoot
        dataDir          = $script:DataDir
        python           = $VenvPython
        pythonVersion    = $VenvVersion
        uv               = $UvPath
        package          = $PackageSpec
        engineDir        = $script:EngineDir
        engineSource     = $script:EngineSourceLabel
        launcher         = (Join-Path $script:DataDir 'OmniControl.cmd')
        shortcut         = $ShortcutPath
    }
    try {
        $json = $manifest | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText((Join-Path $script:DataDir 'install.json'), $json, $script:Utf8NoBom)
    } catch {
        Write-Log ("Could not write install.json: {0}" -f $_.Exception.Message) 'WARN' ([ConsoleColor]::Yellow)
    }
}

function Write-Banner {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '  OmniControl PC - Windows Installer' -ForegroundColor Cyan
    Write-Host '  Offline assistant for low-end 64-bit laptops' -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Invoke-Main {
    $script:Step = 0
    Initialize-Environment
    Write-Banner

    Write-Step 'Checking system requirements'
    Assert-Preflight

    Write-Step 'Verifying Python and uv'
    $runtime = Resolve-PythonRuntime

    Write-Step 'Preparing the isolated Python environment'
    $venv = New-OrUpdateVenv -Runtime $runtime

    Write-Step "Installing $PackageSpec"
    Install-PythonPackage -VenvPython $venv.Python -Uv $runtime.Uv

    Write-Step 'Installing the Needle engine (windows-x86_64)'
    Install-NeedleEngine

    if (-not $SkipVerify -and -not (Test-PackageImport -VenvPython $venv.Python)) {
        throw "The package '$PackageSpec' is installed, but 'from needle import Needle' still fails. Check the log, or retry with -PythonVersion 3.11."
    }
    if (-not $SkipVerify) {
        Write-Log "$PackageSpec import verified after engine setup." 'OK' ([ConsoleColor]::Green)
    }

    Write-Step 'Creating the launcher and Desktop shortcut'
    Install-AppPayloadFromSource -DestinationRoot $script:InstallRoot
    $launcher = New-Launcher
    $icon = Join-Path $script:EngineDir 'needle.exe'
    $shortcut = New-DesktopShortcut -LauncherPath $launcher -WorkingDirectory $script:InstallRoot -IconPath $icon
    Save-Manifest -VenvPython $venv.Python -VenvVersion $venv.Version -UvPath $runtime.Uv -ShortcutPath $shortcut

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host '  Installation complete' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Green
    Write-Host ("  Python   : {0} ({1})" -f $venv.Python, $venv.Version) -ForegroundColor Gray
    Write-Host ("  Package  : {0}" -f $PackageSpec) -ForegroundColor Gray
    Write-Host ("  Engine   : {0}" -f $script:EngineDir) -ForegroundColor Gray
    Write-Host ("  Launcher : {0}" -f $launcher) -ForegroundColor Gray
    if ($shortcut) {
        Write-Host ("  Shortcut : {0}" -f $shortcut) -ForegroundColor Gray
    } else {
        Write-Host '  Shortcut : not created' -ForegroundColor Yellow
    }
    Write-Host ("  Log      : {0}" -f $script:LogFile) -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Double-click the Desktop shortcut, or run:' -ForegroundColor Gray
    Write-Host ('    "{0}" "sube el volumen al 50%"' -f $launcher) -ForegroundColor DarkGray
    Write-Host ''
}

if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 0
    try {
        Invoke-Main
    } catch {
        $exitCode = 1
        $message = $_.Exception.Message
        if ($script:LogFile) {
            Write-Log $message 'ERROR' ([ConsoleColor]::Red)
            try {
                $details = $_ | Out-String
                [IO.File]::AppendAllText($script:LogFile, $details + [Environment]::NewLine, $script:Utf8NoBom)
            } catch { }
        } else {
            Write-Host "[ERROR] $message" -ForegroundColor Red
        }
        Write-Host ''
        Write-Host 'Installation failed. Read the log above for the exact command that failed.' -ForegroundColor Red
        if ($script:LogFile) { Write-Host ("Log: {0}" -f $script:LogFile) -ForegroundColor Yellow }
        Write-Host 'If this is a network problem, retry, set OMNICONTROL_ENGINE_URL, or use install.bat -EngineArchive <local zip>.' -ForegroundColor Yellow
        Write-Host ''
    }
    if ($script:RunFromFile) {
        exit $exitCode
    } elseif ($exitCode -ne 0) {
        Write-Host 'The one-line installer failed. Re-run it in a new PowerShell window to retry.' -ForegroundColor Yellow
    }
}
