# Entry point behind "Claude Profiles - Windows.cmd": a menu, or an action name followed by its arguments.
$ErrorActionPreference = 'Stop'

$actions = [ordered]@{
    'create' = @{ Label = 'Create launchers'; Script = 'generate-launchers.ps1'; Arguments = @('--install') }
    'sign-in' = @{ Label = 'Sign in a profile'; Script = 'sign-in-profile.ps1'; Arguments = @() }
    'delete' = @{ Label = 'Delete a profile'; Script = 'delete-profile.ps1'; Arguments = @() }
}

$rest = @($args)
if ($rest.Count) {
    $action = $rest[0]
    $rest = @($rest | Select-Object -Skip 1)
} else {
    Write-Host "Claude Profiles`n"
    $names = @($actions.Keys)
    for ($index = 0; $index -lt $names.Count; $index++) { Write-Host "$($index + 1). $($actions[$names[$index]].Label)" }
    $choice = Read-Host "`nNumber (Enter to cancel)"
    if (-not $choice) { Write-Host 'Cancelled.'; exit 0 }
    $number = 0
    if (-not [int]::TryParse($choice, [ref]$number) -or $number -lt 1 -or $number -gt $names.Count) {
        [Console]::Error.WriteLine('Invalid selection.')
        exit 1
    }
    $action = $names[$number - 1]
    Write-Host ''
}

if ($action -in '--help', '-h') {
    Write-Host @'
Usage: "Claude Profiles - Windows.cmd" [ACTION [ARGUMENTS...]]
Without ACTION, choose from a menu.
  create [--validate] [--config FILE] [--output DIR] [--install-dir DIR]
  sign-in [PROFILE]
  delete [PROFILE] [--dry-run]
'@
    exit 0
}
if (-not $actions.Contains($action)) {
    [Console]::Error.WriteLine("Unknown action: $action. Use --help for usage.")
    exit 1
}
$forward = @($actions[$action].Arguments) + $rest
& (Join-Path $PSScriptRoot $actions[$action].Script) @forward
exit $LASTEXITCODE
