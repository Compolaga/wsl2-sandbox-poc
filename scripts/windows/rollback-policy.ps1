# Draait alleen de Windows-policy terug. Controleert daarna of hij weg is.
# Start-Transcript schrijft bewijs dat dit script écht gelopen heeft.
param(
    [string]$Log = "",
    [string]$Repo = ""
)

$ErrorActionPreference = "Stop"
if (-not $Log) {
    $logDir = Join-Path $env:USERPROFILE "wsl2-sandbox-snapshots"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $Log = Join-Path $logDir "rollback.log"
}
$lifecycleReady = $false
if (-not $Repo) {
    $Repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
}
try {
    $linuxRepo = (& wsl.exe wslpath -u -- $Repo | Select-Object -Last 1)
    if ($LASTEXITCODE -ne 0 -or -not $linuxRepo) { throw "repo is niet bereikbaar in WSL" }
    $lifecycle = "$linuxRepo/tools/trial_lifecycle.py"
    & wsl.exe python3 $lifecycle plan rollback --root $linuxRepo
    if ($LASTEXITCODE -ne 0) { throw "lifecycle-plan weigert rollback" }
    & wsl.exe python3 $lifecycle record rollback-started --root $linuxRepo `
        --evidence local/placement-manifest.json --if-absent
    if ($LASTEXITCODE -ne 0) { throw "rollback-started kon niet worden vastgelegd" }
    $lifecycleReady = $true
}
catch {
    # Een beschadigd journal mag een noodrollback nooit blokkeren. Cleanup blijft
    # daarna wel dicht tot het bewijs met de hand is hersteld en geverifieerd.
    Write-Warning "Lifecycle-bewijs is niet beschikbaar: $($_.Exception.Message). Rollback gaat voor veiligheid wel door; verwijder daarna geen pakketten."
}
Start-Transcript -Path $Log -Append | Out-Null
$rollbackSucceeded = $false
try {
    $p = Join-Path $env:ProgramFiles "ClaudeCode\managed-settings.json"
    $dir = Split-Path -Parent $p
    $b = "$p.before-wsl2-sandbox"
    $n = "$p.no-original-before-wsl2-sandbox"
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
        throw "FOUT: geen sandbox-rollbackbestand of -marker gevonden"
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
        if (Test-Path -LiteralPath $p) { throw "FOUT: sandbox-payload $p staat er nog" }
    }

    Write-Host "rollback-selfcheck OK"
    Write-Host "log: $Log"
    $rollbackSucceeded = $true
    Write-Host "Draai nu: wsl --shutdown"
    Write-Host "Controleer daarna in de distro dat claude weer start, VOORDAT je bwrap weghaalt."
}
finally {
    Stop-Transcript | Out-Null
}
if ($rollbackSucceeded -and $lifecycleReady) {
    $localDir = Join-Path $Repo "local"
    New-Item -ItemType Directory -Force -Path $localDir | Out-Null
    $localLog = Join-Path $localDir "rollback.log"
    Copy-Item -LiteralPath $Log -Destination $localLog -Force
    & wsl.exe python3 $lifecycle record policy-removed --root $linuxRepo `
        --evidence local/rollback.log
    if ($LASTEXITCODE -ne 0) {
        throw "Policy is teruggedraaid, maar policy-removed kon niet worden vastgelegd. Verwijder geen pakketten."
    }
}
