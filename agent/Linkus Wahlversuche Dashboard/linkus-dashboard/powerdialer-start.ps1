# Powerdialer starten (Desktop-Verknuepfung "Powerdialer")
# 1. Dashboard-Server starten bzw. eine alte Version ohne Powerdialer ersetzen
# 2. Anrufliste als eigenes Chrome-Fenster links oeffnen (Kontakte oeffnen sich rechts daneben)
param(
    [int]$Port = 8765,
    [string]$List   # Dateiname der Liste auf dem Desktop; leer = neueste Anrufliste
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$base = "http://localhost:$Port"

function Test-Url([string]$url) {
    try { return (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { return $false }
}

if (-not (Test-Url "$base/powerdialer.js")) {
    # Laeuft ein altes Dashboard auf dem Port? -> beenden, damit die neue Version starten kann
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*server.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Process powershell.exe -WindowStyle Minimized -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$here\server.ps1`"", '-Port', $Port, '-NoBrowser')
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Url "$base/powerdialer.js")) {
        if ((Get-Date) -gt $deadline) {
            Add-Type -AssemblyName PresentationFramework
            [void][System.Windows.MessageBox]::Show("Der Dashboard-Server startet nicht (Port $Port).", 'Powerdialer')
            exit 1
        }
        Start-Sleep -Milliseconds 500
    }
}

$chrome = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

# Liste direkt als Datei oeffnen (der Dialer ist darin eingebaut). Ohne -List: die neueste
# Anrufliste auf dem Desktop (HTML mit NINA-Ansprechpartnern); keine Liste -> Dashboard
$desktop = Split-Path -Parent (Split-Path -Parent $here)
$listFile = $null
if ($List) {
    $listFile = Join-Path $desktop $List
} else {
    $listFile = Get-ChildItem -LiteralPath $desktop -Filter '*.htm*' -File |
        Where-Object { $_.Extension -match '^\.html?$' } | Sort-Object LastWriteTime -Descending |
        Where-Object { [IO.File]::ReadAllText($_.FullName) -match 'Ansprechpartneredit' } |
        Select-Object -First 1 -ExpandProperty FullName
}
$url = if ($listFile -and (Test-Path -LiteralPath $listFile)) { ([Uri]$listFile).AbsoluteUri } else { "$base/" }
if ($chrome) {
    Add-Type -AssemblyName System.Windows.Forms
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = [int]($wa.Width * 0.4)
    Start-Process $chrome -ArgumentList @("--app=$url", "--window-position=$($wa.Left),$($wa.Top)", "--window-size=$w,$($wa.Height)")
} else {
    Start-Process $url
}
