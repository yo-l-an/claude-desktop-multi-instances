# Windows only. Claude's claude:// sign-in links always start the default profile on Windows,
# so catch them and hand them to the profile that is signing in.
. (Join-Path $PSScriptRoot 'common.ps1')

function Send-Link($Claude, [string]$ProfileName, [string]$Url) {
    # A second process with the same data directory forwards its arguments to the running instance.
    Start-Process -FilePath $Claude.Launch -ArgumentList (@(Get-LaunchArguments $ProfileName) + "`"$Url`"")
    Write-Host "Sent the sign-in link to $ProfileName."
}

function Get-LinkFromText([string]$Text) {
    if ($Text -match '(claude://[^"\s]+)') { return $Matches[1] }
    $null
}

function Main([string[]]$Arguments) {
    if ($Arguments -contains '--help' -or $Arguments -contains '-h') {
        Write-Host "Usage: `"Claude Profiles - Windows.cmd`" sign-in [PROFILE]`nStarts PROFILE and passes Claude's browser sign-in link to it."
        return
    }
    if ($Arguments.Count -gt 1 -or @($Arguments | Where-Object { $_.StartsWith('-') }).Count) { throw 'Use --help for usage.' }
    $configPath = Join-Path $Root 'config.json'
    if (-not (Test-Path -LiteralPath $configPath)) { throw 'Missing config. Run Claude Profiles - Windows.cmd (Create launchers) first.' }
    $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $entries = @($config.apps | Where-Object { $_ -is [Management.Automation.PSCustomObject] -and $_.PSObject.Properties['profile'] -and
        (Test-ValidProfile $_.profile) -and $_.profile -ne 'default' })
    if (-not $entries.Count) { throw 'No profiles to sign in. The default profile uses Claude''s normal sign-in.' }
    if ($Arguments.Count) {
        $entry = $entries | Where-Object { $_.profile -ceq $Arguments[0] } | Select-Object -First 1
        if (-not $entry) { throw "Unknown profile: $($Arguments[0])" }
    } else {
        Write-Host "Choose a Claude profile to sign in:`n"
        for ($index = 0; $index -lt $entries.Count; $index++) { Write-Host "$($index + 1). $($entries[$index].profile) - $($entries[$index].name)" }
        $choice = Read-Host "`nNumber (Enter to cancel)"
        if (-not $choice) { Write-Host 'Cancelled.'; return }
        $number = 0
        if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $entries.Count) { throw 'Invalid selection.' }
        $entry = $entries[$number - 1]
    }
    $profileName = $entry.profile
    $claude = Find-Claude
    $dataDirs = @(Get-ProfileDataDirs $profileName $claude)
    $others = @(Get-ClaudeProcesses | Where-Object {
        $dir = Get-UserDataDir $_
        -not ($dir -and (Test-SamePath $dir $dataDirs[0]))
    })
    if ($others.Count) {
        Write-Warning 'Another Claude profile is running and may receive the sign-in link instead.'
        Read-Host 'Quit other profiles (tray icon > Quit), then press Enter'
    }
    if (-not (Test-ProfileRunning $profileName $dataDirs)) {
        $launchArguments = @(Get-LaunchArguments $profileName)
        Start-Process -FilePath $claude.Launch -ArgumentList $launchArguments
        Write-Host "Started $($entry.name)."
    }
    Write-Host "`nSign in from the $($entry.name) window. When the browser asks to open Claude, allow it:"
    Write-Host "this window passes the link to $profileName. You can also paste a claude:// link here."
    Write-Host "Press Enter on an empty line when you are signed in.`n"
    $handled = @{}
    foreach ($process in Get-ClaudeProcesses) { $handled[[string]$process.ProcessId] = $true }
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Date) -lt $deadline) {
        foreach ($process in Get-ClaudeProcesses) {
            $id = [string]$process.ProcessId
            if ($handled.ContainsKey($id)) { continue }
            $handled[$id] = $true
            $url = Get-LinkFromText $process.CommandLine
            $dir = Get-UserDataDir $process
            if (-not $url -or ($dir -and (Test-SamePath $dir $dataDirs[0]))) { continue }
            # Stop the default profile before it handles a link meant for another account.
            Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            Send-Link $claude $profileName $url
        }
        if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
            $line = [Console]::ReadLine()
            if (-not $line) { break }
            $url = Get-LinkFromText $line
            if ($url) { Send-Link $claude $profileName $url } else { Write-Host 'Paste a link that starts with claude://, or press Enter to finish.' }
        }
        Start-Sleep -Milliseconds 50
    }
    Write-Host 'Done. Use the launcher from now on; sign-in is kept in the profile.'
}

try { Main $args; exit 0 }
catch {
    [Console]::Error.WriteLine("Error: $($_.Exception.Message)")
    exit 1
}
