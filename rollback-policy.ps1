# Draait alleen de Windows-policy terug. Controleert daarna of hij weg is.
# Start-Transcript schrijft bewijs dat dit script écht gelopen heeft.
param(
    [string]$Log = ""
)

$ErrorActionPreference = "Stop"
if (-not $Log) {
    $logDir = Join-Path $env:USERPROFILE "poc-snapshots"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $Log = Join-Path $logDir "rollback.log"
}
Start-Transcript -Path $Log -Append | Out-Null
try {
    $p = Join-Path $env:ProgramFiles "ClaudeCode\managed-settings.json"
    $dir = Split-Path -Parent $p
    $b = "$p.before-wsl2-poc"
    $n = "$p.no-original-before-wsl2-poc"
    $hadOriginal = $false

    if (Test-Path -LiteralPath $b) {
        Copy-Item -LiteralPath $b -Destination $p -Force
        Remove-Item -LiteralPath $b
        $hadOriginal = $true
        Write-Host "hersteld: $p"
    }
    elseif (Test-Path -LiteralPath $n) {
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $n
        Write-Host "verwijderd: $p (er was geen origineel)"
    }
    else {
        throw "FOUT: geen PoC-rollbackbestand of -marker gevonden"
    }

    if ((Test-Path -LiteralPath $dir) -and -not (Get-ChildItem $dir -Force)) {
        Remove-Item -LiteralPath $dir -Force
        Write-Host "lege map weg: $dir"
    }

    if (Test-Path -LiteralPath $b) { throw "FOUT: backup $b staat er nog" }
    if (Test-Path -LiteralPath $n) { throw "FOUT: marker $n staat er nog" }
    if ($hadOriginal) {
        if (-not (Test-Path -LiteralPath $p)) { throw "FOUT: origineel $p is niet teruggezet" }
    }
    else {
        if (Test-Path -LiteralPath $p) { throw "FOUT: PoC-payload $p staat er nog" }
    }

    Write-Host "rollback-selfcheck OK"
    Write-Host "log: $Log"
    Write-Host "Draai nu: wsl --shutdown"
    Write-Host "Controleer daarna in de distro dat claude weer start, VOORDAT je bwrap weghaalt."
}
finally {
    Stop-Transcript | Out-Null
}
