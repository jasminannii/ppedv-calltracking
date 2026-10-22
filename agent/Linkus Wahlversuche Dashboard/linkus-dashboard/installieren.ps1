# ppedv Calltracking - Einrichtung auf einem Vertriebs-PC
#   installieren.ps1             -> Team-Code abfragen, Autostart einrichten, Agent starten
#   installieren.ps1 -Entfernen  -> Autostart entfernen, Team-Meldung abschalten
param(
    [string]$TeamUrl = 'https://ppedv-calltracking.vercel.app',
    [switch]$Entfernen
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $here 'einstellungen.json'
$startup = [Environment]::GetFolderPath('Startup')
$lnk = Join-Path $startup 'ppedv Calltracking.lnk'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function Stop-Agent {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*linkus-dashboard*server.ps1*' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# bestehende Einstellungen (Testnummer, Amtsholung) behalten
$cfg = [ordered]@{}
if (Test-Path -LiteralPath $cfgPath) {
    $j = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
}
function Save-Cfg { [IO.File]::WriteAllText($cfgPath, (ConvertTo-Json -InputObject $cfg), (New-Object Text.UTF8Encoding $false)) }

if ($Entfernen) {
    Stop-Agent
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
    foreach ($k in 'teamUrl', 'teamCode', 'nebenstelle') { $cfg.Remove($k) }
    Save-Cfg
    Write-Host 'Calltracking entfernt (Autostart und Team-Meldung aus).' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host '  ppedv Calltracking - Einrichtung' -ForegroundColor Cyan
Write-Host '  --------------------------------'
Write-Host ''

# 1. Nebenstelle aus dem Linkus-Log
$ext = $null
foreach ($dir in (Join-Path $env:APPDATA 'Linkus Lite\logs'), (Join-Path $env:APPDATA 'Linkus\logs')) {
    foreach ($name in 'Desktop.log', 'Desktop.old.log') {
        $f = Join-Path $dir $name
        if ($ext -or -not (Test-Path -LiteralPath $f)) { continue }
        $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite, Delete')
        try { $t = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
        $m = [regex]::Matches($t, "registername:\s*'(\d{2,6})'")
        if ($m.Count) { $ext = $m[$m.Count - 1].Groups[1].Value }
    }
}
if ($ext) {
    Write-Host "  Nebenstelle aus Linkus erkannt: $ext"
    $cfg.Remove('nebenstelle')
} else {
    $ext = Read-Host '  Nebenstelle (z. B. 30 fuer +49 8677 9889-30)'
    if ($ext -notmatch '^\d{2,6}$') { Write-Host '  Ungueltige Nebenstelle.' -ForegroundColor Red; exit 1 }
    $cfg['nebenstelle'] = $ext
}

# 2. Team-Code pruefen
$ok = $false
for ($i = 0; $i -lt 3 -and -not $ok; $i++) {
    $sec = Read-Host '  Team-Code' -AsSecureString
    $code = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    try {
        $r = Invoke-RestMethod -Uri "$TeamUrl/api/ct?a=pruefen" -Headers @{ 'x-team-code' = $code } -TimeoutSec 20
        $ok = [bool]$r.ok
    } catch {
        $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($st -eq 401) { Write-Host '  Team-Code falsch.' -ForegroundColor Red }
        elseif ($st -eq 503) { Write-Host "  Team-Dashboard ist noch nicht eingerichtet: $TeamUrl" -ForegroundColor Red; exit 1 }
        else { Write-Host "  Keine Verbindung zu $TeamUrl ($($_.Exception.Message))" -ForegroundColor Red; exit 1 }
    }
}
if (-not $ok) { exit 1 }

# Testnummer fuer den Powerdialer-Testmodus (nur beim ersten Mal)
if (-not $cfg['testNumber']) {
    $tn = Read-Host '  Testnummer fuer den Powerdialer, z. B. eigenes Handy (leer = ueberspringen)'
    $tn = $tn -replace '[\s/()-]', ''
    if ($tn -match '^\+?\d{5,20}$') { $cfg['testNumber'] = $tn }
}
if (-not $cfg.Contains('amtPrefix')) { $cfg['amtPrefix'] = '0' }

$cfg['teamUrl'] = $TeamUrl
$cfg['teamCode'] = $code
Save-Cfg

# 3. Autostart (Autostart-Ordner, keine Admin-Rechte noetig) und jetzt starten
$agentArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$here\server.ps1`" -NoBrowser"
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments = $agentArgs
$s.WorkingDirectory = $here
$s.WindowStyle = 7
$s.Description = 'ppedv Calltracking (Linkus-Agent)'
$s.Save()

Stop-Agent
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $agentArgs

Write-Host ''
Write-Host "  Fertig. Der Agent laeuft jetzt im Hintergrund und startet mit Windows." -ForegroundColor Green
Write-Host "  Eigenes Dashboard: http://localhost:8765   Team: $TeamUrl"
Write-Host ''
Start-Sleep -Seconds 4
Start-Process $TeamUrl
