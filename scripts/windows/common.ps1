# Shared helpers for the Windows scripts. Keep this file ASCII: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ProfilesRoot = Join-Path $env:USERPROFILE '.claude-instances'
$IconStore = Join-Path $env:LOCALAPPDATA 'ClaudeProfiles\icons'
$DefaultInstallDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Profiles'
# Shortcuts carry their profile in the description, so renaming them is harmless.
$LauncherMarker = 'Claude profile: '
$Shell = New-Object -ComObject WScript.Shell

function Test-ValidProfile([string]$Value) {
    $Value.Length -le 64 -and $Value -cmatch '^[a-z0-9][a-z0-9-]*$'
}

function Test-SamePath([string]$Left, [string]$Right) {
    [IO.Path]::GetFullPath($Left).TrimEnd('\') -ieq [IO.Path]::GetFullPath($Right).TrimEnd('\')
}

function Assert-NoReparsePoint([string]$Path) {
    # Check every ancestor: never act on data reached through a redirected folder.
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing a symlink or junction path: $current"
        }
        $current = Split-Path -Parent $current
    }
}

# Returns how to start Claude and where its default profile lives. Launch is $null when Claude cannot be started.
function Get-ClaudeInstall {
    $package = $null
    try {
        $package = Get-AppxPackage -Name Claude -ErrorAction Stop | Where-Object { $_.PackageFamilyName -like 'Claude_*' } |
            Select-Object -First 1
    } catch {}
    if ($package) {
        # The MSIX build only receives command-line arguments through its execution alias.
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\claude-desktop.exe'
        return [pscustomobject]@{
            Launch = $(if (Test-Path -LiteralPath $alias) { $alias } else { $null })
            Executable = Join-Path $package.InstallLocation 'app\Claude.exe'
            # MSIX redirects Claude's %APPDATA% writes into the package folder; processes still report %APPDATA%.
            DefaultData = @(
                (Join-Path $env:LOCALAPPDATA "Packages\$($package.PackageFamilyName)\LocalCache\Roaming\Claude"),
                (Join-Path $env:APPDATA 'Claude'))
        }
    }
    $squirrel = Join-Path $env:LOCALAPPDATA 'AnthropicClaude\claude.exe'
    [pscustomobject]@{
        Launch = $(if (Test-Path -LiteralPath $squirrel) { $squirrel } else { $null })
        Executable = $squirrel
        DefaultData = @(Join-Path $env:APPDATA 'Claude')
    }
}

function Find-Claude {
    $claude = Get-ClaudeInstall
    if (-not $claude.Launch) {
        if (Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue) {
            throw 'Turn on the claude-desktop.exe alias in Settings > Apps > App execution aliases, then try again.'
        }
        throw 'Install Claude Desktop first.'
    }
    $claude
}

function Get-ProfileDataDirs([string]$ProfileName, $Claude) {
    if ($ProfileName -eq 'default') { return $Claude.DefaultData }
    # Profile names are validated before use; never interpret them as paths.
    if (-not (Test-ValidProfile $ProfileName)) { throw "Invalid profile: $ProfileName" }
    @(Join-Path $ProfilesRoot $ProfileName)
}

function Get-LaunchArguments([string]$ProfileName) {
    if ($ProfileName -eq 'default') { return @() }
    @('--user-data-dir="' + @(Get-ProfileDataDirs $ProfileName $null)[0] + '"')
}

function Get-LauncherProfile([string]$Path) {
    try { $description = $Shell.CreateShortcut($Path).Description } catch { return $null }
    if ($description -and $description.StartsWith($LauncherMarker)) {
        $candidate = $description.Substring($LauncherMarker.Length)
        if (Test-ValidProfile $candidate) { return $candidate }
    }
    $null
}

function Get-ClaudeProcesses {
    # Claude Code's CLI is also claude.exe; keep Claude Desktop's binaries only.
    Get-CimInstance Win32_Process -Filter "Name='claude.exe' OR Name='claude-desktop.exe'" | Where-Object {
        $_.CommandLine -and (
            "$($_.ExecutablePath)" -like '*\WindowsApps\Claude_*' -or
            "$($_.ExecutablePath)" -like '*\AnthropicClaude\*' -or
            $_.CommandLine -like '*\WindowsApps\claude-desktop.exe*')
    }
}

function Get-UserDataDir($Process) {
    if ($Process.CommandLine -match '--user-data-dir=(?:"([^"]*)"|(\S+))') {
        if ($Matches[1]) { return $Matches[1] }
        return $Matches[2]
    }
    $null
}

function Test-ProfileRunning([string]$ProfileName, [string[]]$DataDirs) {
    foreach ($process in Get-ClaudeProcesses) {
        $dir = Get-UserDataDir $process
        # Launchers use one stable data directory per profile. Helpers carry it too.
        if ($dir) {
            if (@($DataDirs | Where-Object { Test-SamePath $_ $dir }).Count) { return $true }
        } elseif ($ProfileName -eq 'default') {
            return $true
        }
    }
    $false
}
