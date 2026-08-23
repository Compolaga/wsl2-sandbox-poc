# Bewijst dat je op dit moment écht in een admin-PowerShell kunt schrijven en wissen
# onder Program Files. Zonder dit rondje is de latere rollback geen rollback.
param(
    [string]$Repo = ""
)

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
$meta = Join-Path $env:USERPROFILE "wsl2-sandbox-snapshots\rollback-roundtrip.ok"
New-Item -ItemType Directory -Force -Path (Split-Path $meta) | Out-Null
Set-Content -LiteralPath $meta -Value ((Get-Date -Format "o") + "`n")
$repoPath = if ($Repo) { $Repo } else { $PSScriptRoot }
$localDir = Join-Path $repoPath "local"
New-Item -ItemType Directory -Force -Path $localDir | Out-Null
$localMarker = Join-Path $localDir "rollback-roundtrip.ok"
Copy-Item -LiteralPath $meta -Destination $localMarker -Force
$linuxRepo = (& wsl.exe wslpath -u -- $repoPath | Select-Object -Last 1)
if ($LASTEXITCODE -eq 0 -and $linuxRepo) {
    & wsl.exe python3 "$linuxRepo/tools/trial_lifecycle.py" record rollback-route-tested `
        --root $linuxRepo --evidence local/rollback-roundtrip.ok --if-absent
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Rollbacktest slaagde, maar lifecycle-registratie lukte niet. Ga niet verder tot marker en journal kloppen."
    }
}
Write-Host "marker: $meta"
Write-Host "lokaal: $localMarker"
