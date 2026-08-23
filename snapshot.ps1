# Exporteert de WSL-distro vóór de proef. Geen snapshot betekent geen proef.
param(
    [string]$Distro = "Ubuntu",
    [string]$Tar = "",
    [string]$Repo = ""
)

$ErrorActionPreference = "Stop"
if (-not $Tar) {
    $dir = Join-Path $env:USERPROFILE "wsl2-sandbox-snapshots"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Tar = Join-Path $dir "$Distro-voor-sandbox.tar"
}

if (Test-Path -LiteralPath $Tar) {
    throw "FOUT: $Tar bestaat al. Verplaats of hernoem hem eerst."
}

wsl -l -v
wsl --shutdown
wsl --export $Distro $Tar
if (-not (Test-Path -LiteralPath $Tar)) {
    throw "FOUT: export klaar maar $Tar ontbreekt"
}
$item = Get-Item -LiteralPath $Tar
if ($item.Length -lt 1MB) {
    throw "FOUT: $Tar is te klein ($($item.Length) bytes) - dit is geen bruikbare snapshot"
}

$meta = [ordered]@{
    distro     = $Distro
    tar        = $Tar
    bytes      = $item.Length
    recordedAt = (Get-Date -Format "o")
}
$json = [System.IO.Path]::ChangeExtension($Tar, ".json")
$meta | ConvertTo-Json | Set-Content -LiteralPath $json -Encoding utf8
if (-not $Repo) { $Repo = $PSScriptRoot }
$localDir = Join-Path $Repo "local"
New-Item -ItemType Directory -Force -Path $localDir | Out-Null
$localMeta = Join-Path $localDir "snapshot.json"
Copy-Item -LiteralPath $json -Destination $localMeta -Force
$linuxRepo = (& wsl.exe wslpath -u -- $Repo | Select-Object -Last 1)
if ($LASTEXITCODE -eq 0 -and $linuxRepo) {
    & wsl.exe python3 "$linuxRepo/tools/trial_lifecycle.py" record snapshot-recorded `
        --root $linuxRepo --evidence local/snapshot.json --if-absent
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Snapshot bestaat, maar lifecycle-registratie lukte niet. Ga niet verder tot local/snapshot.json en het journal kloppen."
    }
}
Write-Host "snapshot: $Tar ($([math]::Round($item.Length / 1MB)) MB)"
Write-Host "meta:     $json"
Write-Host "lokaal:   $localMeta"
Write-Host "Terugzetten: .\herstel-snapshot.ps1 -Distro $Distro -Tar `"$Tar`" -Bevestig"
