# Windows counterpart of delete-profile.swift.
. (Join-Path $PSScriptRoot 'common.ps1')
Add-Type -AssemblyName Microsoft.VisualBasic

function ConvertTo-CompactJson($Value) {
    $json = ConvertTo-Json -InputObject $Value -Compress -Depth 32
    # Windows PowerShell escapes these HTML-sensitive characters; JSON does not need it.
    [regex]::Replace($json, '(?<!\\)((?:\\\\)*)\\u00(26|27|3c|3e)', {
        param($match) $match.Groups[1].Value + [char][Convert]::ToInt32($match.Groups[2].Value, 16)
    })
}

# Retain user config fields and app order.
function Format-Config($Config, $Entries) {
    $known = 'profile', 'name', 'color'
    $rows = @(foreach ($entry in $Entries) {
        $names = @($entry.PSObject.Properties.Name)
        $keys = @($known | Where-Object { $names -contains $_ }) + @($names | Where-Object { $known -notcontains $_ } | Sort-Object)
        '    { ' + (($keys | ForEach-Object { (ConvertTo-CompactJson $_) + ': ' + (ConvertTo-CompactJson $entry.$_) }) -join ', ') + ' }'
    })
    $fields = @('  "apps": [' + $(if ($rows.Count) { "`n" + ($rows -join ",`n") + "`n  " } else { '' }) + ']')
    foreach ($key in @($Config.PSObject.Properties.Name | Where-Object { $_ -ne 'apps' } | Sort-Object)) {
        $fields += '  ' + (ConvertTo-CompactJson $key) + ': ' + (ConvertTo-CompactJson $Config.$key)
    }
    "{`n" + ($fields -join ",`n") + "`n}`n"
}

function Read-ConfigText([string]$Path) {
    if (Test-Path -LiteralPath $Path) { return [IO.File]::ReadAllText($Path) }
    $null
}

function Remove-ToRecycleBin([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Container) {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    } else {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, 'OnlyErrorDialogs', 'SendToRecycleBin')
    }
}

function Assert-ProfileClosed([string]$ProfileName, [string[]]$DataDirs) {
    if (Test-ProfileRunning $ProfileName $DataDirs) {
        throw "Profile '$ProfileName' is running. Quit that Claude instance (tray icon > Quit), then try again. Other profiles can stay open."
    }
}

function Main([string[]]$Arguments) {
    if ($Arguments -contains '--help' -or $Arguments -contains '-h') {
        Write-Host "Usage: `"Claude Profiles - Windows.cmd`" delete [PROFILE] [--dry-run]`nWithout PROFILE, choose interactively. Deletion always requires typed confirmation."
        return
    }
    $dryRun = $Arguments -contains '--dry-run'
    $positional = @($Arguments | Where-Object { $_ -ne '--dry-run' })
    if ($positional.Count -gt 1 -or @($positional | Where-Object { $_.StartsWith('-') }).Count) { throw 'Use --help for usage.' }
    $configPath = Join-Path $Root 'config.json'
    Assert-NoReparsePoint $configPath
    $originalConfig = Read-ConfigText $configPath
    $config = [pscustomobject]@{}
    $entries = @()
    if ($null -ne $originalConfig) {
        $config = $originalConfig | ConvertFrom-Json
        if (-not $config -or -not $config.PSObject.Properties['apps']) { throw 'Invalid config.json.' }
        if ($config.apps -is [array]) { $entries = @($config.apps) }
        elseif (-not ($config.apps -is [Management.Automation.PSCustomObject] -and @($config.apps.PSObject.Properties).Count -eq 0)) {
            throw 'config.json apps must be an array or an empty object.'
        }
        foreach ($entry in $entries) {
            if (-not ($entry -is [Management.Automation.PSCustomObject] -and $entry.PSObject.Properties['profile'] -and (Test-ValidProfile $entry.profile))) {
                throw 'config.json contains an invalid profile.'
            }
        }
    }
    $claude = Get-ClaudeInstall
    Assert-NoReparsePoint $ProfilesRoot
    $profiles = @{}
    foreach ($entry in $entries) { $profiles[$entry.profile] = $true }
    if (Test-Path -LiteralPath $ProfilesRoot) {
        foreach ($folder in Get-ChildItem -LiteralPath $ProfilesRoot -Directory -Force) {
            if ($folder.Name -ne 'default' -and (Test-ValidProfile $folder.Name)) { $profiles[$folder.Name] = $true }
        }
    }
    if (@($claude.DefaultData | Where-Object { Test-Path -LiteralPath $_ }).Count) { $profiles['default'] = $true }
    $launchers = @{}
    foreach ($directory in (Join-Path $Root 'apps'), $DefaultInstallDir) {
        Assert-NoReparsePoint $directory
        if (-not (Test-Path -LiteralPath $directory)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $directory -Filter *.lnk -File -Force) {
            $launcherProfile = Get-LauncherProfile $item.FullName
            if (-not $launcherProfile) { continue }
            if (-not $launchers.ContainsKey($launcherProfile)) { $launchers[$launcherProfile] = @() }
            $launchers[$launcherProfile] += $item.FullName
            $profiles[$launcherProfile] = $true
        }
    }
    $ordered = @($profiles.Keys | Sort-Object)
    if (-not $ordered.Count) { Write-Host 'No Claude profiles found.'; return }
    if ($positional.Count) {
        if (-not $profiles.ContainsKey($positional[0])) { throw "Unknown profile: $($positional[0])" }
        $profileName = $positional[0]
    } else {
        Write-Host "Choose a Claude profile to remove:`n"
        for ($index = 0; $index -lt $ordered.Count; $index++) {
            $entry = $entries | Where-Object { $_.profile -eq $ordered[$index] } | Select-Object -First 1
            $label = if ($entry -and $entry.PSObject.Properties['name']) { " - $($entry.name)" } else { '' }
            Write-Host "$($index + 1). $($ordered[$index])$label"
        }
        $choice = Read-Host "`nNumber (Enter to cancel)"
        if (-not $choice) { Write-Host 'Cancelled.'; return }
        $number = 0
        if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $ordered.Count) { throw 'Invalid selection.' }
        $profileName = $ordered[$number - 1]
    }
    $dataDirs = @(Get-ProfileDataDirs $profileName $claude)
    $icons = @()
    if (Test-Path -LiteralPath $IconStore) {
        $icons = @(Get-ChildItem -LiteralPath $IconStore -Filter "$profileName-*.ico" -File |
            Where-Object { $_.Name -cmatch "^$profileName-[0-9a-f]{16}\.ico$" } | ForEach-Object { $_.FullName })
    }
    $targets = @($dataDirs | Where-Object { Test-Path -LiteralPath $_ }) + @(if ($launchers.ContainsKey($profileName)) { $launchers[$profileName] }) + $icons
    foreach ($target in $targets) { Assert-NoReparsePoint $target }
    Write-Host "`nProfile: $profileName"
    if ($profileName -eq 'default') { Write-Host 'WARNING: default is your regular Claude Desktop session, including its local settings and Cowork data.' }
    Write-Host 'Move to Recycle Bin:'
    foreach ($target in $targets) { Write-Host "  $target" }
    $remaining = @($entries | Where-Object { $_.profile -ne $profileName })
    $updateConfig = $remaining.Count -ne $entries.Count
    if ($updateConfig) { Write-Host "Remove its entry from: $configPath" }
    Write-Host 'The original Claude app and online account will remain unchanged.'
    Assert-ProfileClosed $profileName $dataDirs
    if ($dryRun) { Write-Host 'Profile is not running. Dry run: no changes made.'; return }
    if ((Read-Host "`nType DELETE $profileName to confirm") -cne "DELETE $profileName") { Write-Host 'Cancelled. No changes made.'; return }
    Assert-ProfileClosed $profileName $dataDirs
    if ((Read-ConfigText $configPath) -cne $originalConfig) { throw 'config.json changed. Run this command again.' }
    # Serialize before touching files.
    $updatedConfig = if ($updateConfig) { Format-Config $config $remaining } else { $null }
    foreach ($target in $targets) {
        Assert-NoReparsePoint $target
        Remove-ToRecycleBin $target
        Write-Host "Moved to Recycle Bin: $target"
    }
    if ($updateConfig) { [IO.File]::WriteAllText($configPath, $updatedConfig) }
    Write-Host "Removed profile: $profileName."
}

try { Main $args; exit 0 }
catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit 1
}
