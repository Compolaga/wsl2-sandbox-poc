# Bewijst dat je op dit moment écht in een admin-PowerShell kunt schrijven en wissen
# onder Program Files. Zonder dit rondje is de latere rollback geen rollback.
$ErrorActionPreference = "Stop"
$dir = Join-Path $env:ProgramFiles "ClaudeCode"
$p = Join-Path $dir "_rollbacktest.json"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
New-Item $p -ItemType File -Force | Out-Null
Remove-Item -LiteralPath $p
if (Test-Path -LiteralPath $p) {
    throw "FOUT: rollbackpad werkt niet - NIET verdergaan"
}
if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem $dir -Force)) {
    Remove-Item -LiteralPath $dir -Force
}
Write-Host "rollback-round-trip OK"
$meta = Join-Path $env:USERPROFILE "poc-snapshots\rollback-roundtrip.ok"
New-Item -ItemType Directory -Force -Path (Split-Path $meta) | Out-Null
Set-Content -LiteralPath $meta -Value ((Get-Date -Format "o") + "`n")
Write-Host "marker: $meta"
Write-Host "Kopieer die marker naar de clone in WSL als local/rollback-roundtrip.ok"
