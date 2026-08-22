# Exporteert de WSL-distro vóór de proef. Geen snapshot betekent geen proef.
param(
    [string]$Distro = "Ubuntu",
    [string]$Tar = ""
)

$ErrorActionPreference = "Stop"
if (-not $Tar) {
    $dir = Join-Path $env:USERPROFILE "poc-snapshots"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $Tar = Join-Path $dir "$Distro-voor-poc.tar"
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
Write-Host "snapshot: $Tar ($([math]::Round($item.Length / 1MB)) MB)"
Write-Host "meta:     $json"
Write-Host "Kopieer die json naar de clone in WSL als local/snapshot.json voordat je verdergaat."
Write-Host "Terugzetten: .\herstel-snapshot.ps1 -Distro $Distro -Tar `"$Tar`" -Bevestig"
