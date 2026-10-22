# Tagesbericht: Screenshot des Dashboards (Ansicht "Heute") als PNG speichern
# Ablage standardmaessig im OneDrive unter "Linkus Tagesberichte" -> von dort teilbar.
#   tagesbericht.ps1              -> Screenshot jetzt
#   tagesbericht.ps1 -Install     -> taeglich um 17:30 automatisch (Windows-Aufgabenplanung)
#   tagesbericht.ps1 -Uninstall   -> automatische Aufgabe entfernen
param(
    [int]$Port = 8765,
    [string]$OutDir,
    [string]$Time = '17:30',
    [switch]$Install,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$TaskName = 'Linkus Tagesbericht'
if (-not $OutDir) {
    $root = if ($env:OneDriveCommercial) { $env:OneDriveCommercial } elseif ($env:OneDrive) { $env:OneDrive } else { [Environment]::GetFolderPath('MyDocuments') }
    $OutDir = Join-Path $root 'Linkus Tagesberichte'
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Aufgabe '$TaskName' entfernt."
    exit 0
}
if ($Install) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$here\tagesbericht.ps1`" -Port $Port -OutDir `"$OutDir`"")
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $Time
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Host "Eingerichtet: Mo-Fr um $Time -> $OutDir"
    exit 0
}

$base = "http://localhost:$Port"
function Test-Url([string]$url) {
    try { return (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { return $false }
}

# Server kurz selbst starten, falls er nicht laeuft (liest das ganze Linkus-Log ein)
$started = $null
if (-not (Test-Url "$base/api/state")) {
    $started = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$here\server.ps1`"", '-Port', $Port, '-NoBrowser')
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Url "$base/api/state")) {
        if ((Get-Date) -gt $deadline) { throw "Dashboard-Server startet nicht (Port $Port)." }
        Start-Sleep -Milliseconds 500
    }
}

try {
    $browser = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $browser) { throw 'Weder Edge noch Chrome gefunden.' }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $file = Join-Path $OutDir ("{0} {1}.png" -f (Get-Date -Format 'yyyy-MM-dd'), $env:USERNAME)
    # eigenes, leeres Profil -> Ansicht "Heute / Ausgehend" (Standard), keine gemerkten Filter
    $profileDir = Join-Path $env:TEMP 'linkus-tagesbericht-profil'
    $p = Start-Process $browser -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '--headless=new', '--disable-gpu', '--hide-scrollbars', "--user-data-dir=`"$profileDir`"",
        '--window-size=1400,1800', '--virtual-time-budget=8000', "--screenshot=`"$file`"", "$base/")
    if (-not (Test-Path -LiteralPath $file)) { throw "Screenshot fehlgeschlagen (Exitcode $($p.ExitCode))." }
    Write-Host "Gespeichert: $file"
} finally {
    if ($started) { Stop-Process -Id $started.Id -Force -ErrorAction SilentlyContinue }
}
