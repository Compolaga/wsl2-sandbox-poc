# Plaatst uitsluitend een payload die door het placement-manifest aan alle
# veiligheidsbewijzen is gebonden. Ook direct gebruik gaat door de WSL-poort.
param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Manifest)) {
    throw "FOUT: placement-manifest ontbreekt: $Manifest"
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "FOUT: start PowerShell als administrator; de plaatsingspoort blijft ook dan verplicht."
}

$linuxManifest = (& wsl.exe wslpath -u -- $Manifest | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0 -or -not $linuxManifest) {
    throw "FOUT: kon het manifest niet naar een WSL-pad vertalen: $Manifest"
}
$linuxLocal = (& wsl.exe dirname $linuxManifest | Select-Object -Last 1)
$linuxRepo = (& wsl.exe dirname $linuxLocal | Select-Object -Last 1)
$linuxGate = "$linuxRepo/tools/placement_gate.py"
$verifiedOutput = (& wsl.exe python3 $linuxGate verify --root $linuxRepo --manifest $linuxManifest --json)
if ($LASTEXITCODE -ne 0 -or -not $verifiedOutput) {
    throw "FOUT: placement-manifest is niet geldig; er is niets geplaatst."
}
$verified = (($verifiedOutput -join "`n") | ConvertFrom-Json)
$linuxSource = $verified.artifact
$lifecycleOutput = (& wsl.exe python3 "$linuxRepo/tools/trial_lifecycle.py" plan place --root $linuxRepo)
if ($LASTEXITCODE -ne 0) {
    throw "FOUT: lifecycle-poort weigert plaatsing: $($lifecycleOutput -join ' ')"
}
& wsl.exe python3 "$linuxRepo/tools/trial_lifecycle.py" record placement-started `
    --root $linuxRepo --evidence local/placement-manifest.json
if ($LASTEXITCODE -ne 0) {
    throw "FOUT: kon placement-started niet veilig vastleggen; er is niets geplaatst."
}
$Source = (& wsl.exe wslpath -w -- $linuxSource | Select-Object -Last 1)
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Source)) {
    throw "FOUT: gevalideerde payload is niet bereikbaar vanuit Windows."
}

$dest = Join-Path $env:ProgramFiles "ClaudeCode\managed-settings.json"
$staging = "$dest.wsl2-sandbox-staging"
$dir = Split-Path -Parent $dest
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
}
if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Force
}
Copy-Item -LiteralPath $Source -Destination $staging
$copiedHash = (Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash.ToLowerInvariant()
if ($copiedHash -ne $verified.sha256) {
    Remove-Item -LiteralPath $staging -Force
    throw "FOUT: payload wijzigde tussen verificatie en kopie; bestaande policy is niet aangeraakt."
}
Move-Item -LiteralPath $staging -Destination $dest -Force
& wsl.exe python3 "$linuxRepo/tools/trial_lifecycle.py" record policy-placed `
    --root $linuxRepo --evidence local/placement-manifest.json
if ($LASTEXITCODE -ne 0) {
    throw "FOUT: policy is geplaatst, maar lifecycle-bewijs ontbreekt. Start geen verificatie; inspecteer local/trial-lifecycle.jsonl."
}
Write-Host "geplaatst: $dest"
Write-Host "Draai nu: wsl --shutdown"
$rollbackScript = Join-Path $PSScriptRoot "rollback-policy.ps1"
Write-Host "Terug:    & `"$rollbackScript`"  (eerst de policy, pas daarna bwrap)"
