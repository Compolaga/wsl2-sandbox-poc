# Plaatst de gegenereerde testpayload. Weigert de statische template en weigert
# zonder rollbackmarker.
param(
    [Parameter(Mandatory = $true)]
    [string]$Source
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Source)) {
    throw "FOUT: bron ontbreekt: $Source"
}
if ($Source -match '[\\/]config[\\/]managed-settings\.windows\.json$') {
    throw "FOUT: de statische template mag niet geplaatst worden. Gebruik local/managed-settings.windows.generated.json"
}

$dest = Join-Path $env:ProgramFiles "ClaudeCode\managed-settings.json"
$backup = "$dest.before-wsl2-poc"
$marker = "$dest.no-original-before-wsl2-poc"
if (-not ((Test-Path -LiteralPath $backup) -or (Test-Path -LiteralPath $marker))) {
    throw "FOUT: geen rollbackmarker. Regel die eerst (HANDOFF.md, veilige proef stap 1)."
}

$dir = Split-Path -Parent $dest
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
}
Copy-Item -LiteralPath $Source -Destination $dest -Force
Write-Host "geplaatst: $dest"
Write-Host "Draai nu: wsl --shutdown"
Write-Host "Terug:    .\\rollback-policy.ps1  (eerst de policy, pas daarna bwrap)"
