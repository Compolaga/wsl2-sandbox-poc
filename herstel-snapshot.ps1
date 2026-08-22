# Zet de distro terug uit de snapshot. Wist de huidige distro.
param(
    [string]$Distro = "Ubuntu",
    [Parameter(Mandatory = $true)]
    [string]$Tar,
    [string]$InstallDir = "",
    [switch]$Bevestig
)

$ErrorActionPreference = "Stop"
if (-not $Bevestig) {
    throw "FOUT: herstel wist de huidige distro. Roep aan met -Bevestig als je dat wilt."
}
if (-not (Test-Path -LiteralPath $Tar)) {
    throw "FOUT: snapshot ontbreekt: $Tar"
}
if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "wsl\$Distro"
}

Write-Host "unregister $Distro en import uit $Tar"
wsl --shutdown
wsl --unregister $Distro
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
wsl --import $Distro $InstallDir $Tar --version 2
wsl -d $Distro -e echo "herstel-snapshot OK"
Write-Host "distro $Distro staat terug op versie 2"
