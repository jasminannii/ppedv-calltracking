# Baut einrichtung/ppedv-calltracking-agent.zip aus dem Ordner agent/ (nach jeder Agent-Aenderung ausfuehren).
# Nur Programmdateien - keine Anrufdaten, Logs oder Einstellungen.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$src = Join-Path $here 'Linkus Wahlversuche Dashboard\linkus-dashboard'
$zip = Join-Path (Split-Path -Parent $here) 'einrichtung\ppedv-calltracking-agent.zip'
$files = 'server.ps1', 'dashboard.html', 'powerdialer.js', 'powerdialer.html', 'powerdialer-start.ps1',
         'tagesbericht.ps1', 'installieren.ps1', 'Installieren.cmd', 'Dashboard starten.cmd', 'ANLEITUNG.txt'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip }
$za = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    foreach ($f in $files) {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($za, (Join-Path $src $f),
            "Linkus Wahlversuche Dashboard/linkus-dashboard/$f", [IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $za.Dispose() }
Write-Host "Gebaut: $zip"
