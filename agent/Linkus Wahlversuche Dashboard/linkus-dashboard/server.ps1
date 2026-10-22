# Linkus Lite - Live-Dashboard fuer Wahlversuche
# Liest das Desktop.log von Linkus Lite fortlaufend mit und stellt die Daten
# unter http://localhost:<Port>/ als Dashboard bereit.
param(
    [int]$Port = 8765,
    [string]$LogPath,
    [switch]$NoBrowser,
    [switch]$DryRun,          # Powerdialer-Probelauf: nichts waehlen
    [string]$ProtoFile,       # anderes Anrufprotokoll (z.B. fuer Tests)
    [string]$HistFile,        # andere Anruf-Historie (z.B. fuer Tests)
    [string]$ArchivePath      # anderer Ordner fuer das Linkus-Log-Archiv (z.B. fuer Tests)
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$htmlPath = Join-Path $here 'dashboard.html'
$dialerJsPath = Join-Path $here 'powerdialer.js'
$dialerHtmlPath = Join-Path $here 'powerdialer.html'
$CrmOrigin = 'https://nina.ppedv.de'

# Einstellungen dieses PCs (vom Installer angelegt): Testnummer + Amtsholung
$Config = @{ testNumber = ''; amtPrefix = '0' }
$configPath = Join-Path $here 'einstellungen.json'
if (Test-Path -LiteralPath $configPath) {
    $j = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($j.testNumber -match '^\+?\d{5,20}$') { $Config.testNumber = [string]$j.testNumber }
    if ($null -ne $j.amtPrefix -and [string]$j.amtPrefix -match '^\d{0,3}$') { $Config.amtPrefix = [string]$j.amtPrefix }
    # Team-Calltracking (vom Installer): Adresse, Team-Code, ggf. feste Nebenstelle
    if ([string]$j.teamUrl -match '^https://[\w.-]+(:\d+)?$' -or [string]$j.teamUrl -match '^http://localhost(:\d+)?$') { $Config.teamUrl = [string]$j.teamUrl }
    if ($j.teamCode) { $Config.teamCode = [string]$j.teamCode }
    if ([string]$j.nebenstelle -match '^\d{2,6}$') { $Config.nebenstelle = [string]$j.nebenstelle }
}
$DesktopDir = Split-Path -Parent (Split-Path -Parent $here)

function Find-LogPath {
    $cands = @(
        (Join-Path $env:APPDATA 'Linkus Lite\logs\Desktop.log'),
        (Join-Path $env:APPDATA 'Linkus\logs\Desktop.log')
    ) | Where-Object { Test-Path $_ }
    $cands | Sort-Object { (Get-Item $_).LastWriteTime } -Descending | Select-Object -First 1
}
if (-not $LogPath) { $LogPath = Find-LogPath }

# ---------------------------------------------------------------- state
$script:pos     = 0L
$script:partial = ''
$script:dec     = [Text.Encoding]::UTF8.GetDecoder()
$script:blk     = $null
$script:calls   = New-Object System.Collections.Generic.List[hashtable]
$script:active  = @{}   # call_id -> record (laufende Anrufe)
$script:nextId  = 1
$script:reg     = $null
$script:lastLine = $null
$script:pending = $null  # Waehlversuch (Klick), zu dem noch kein SIP-Anruf existiert
$script:fileSig = $null  # Anfang des aktuell gelesenen Logs (Rotation erkennen)
$MaxCalls = 10000
$TimeoutWord = [string][char]0x8D85 + [char]0x65F6   # "超时" (Timeout) im Linkus-Log

function New-Attempt([string]$ts, [string]$number, [string]$dir, [int]$state) {
    $rec = @{ id = $script:nextId; sipId = ''; number = $number; dir = $dir; last = $ts
              start = $ts; ring = $null; answer = $null; end = $null; code = 0; state = $state; sipErr = $false }
    $script:nextId++
    $script:calls.Add($rec)
    if ($script:calls.Count -gt $MaxCalls) {
        # aus dem Speicher, aber nicht aus der Historie-Datei
        $script:histHead.Add((ConvertTo-HistLine $script:calls[0]))
        $script:calls.RemoveAt(0)
    }
    $rec
}

# Alle offenen Anrufe beenden, wenn Linkus neu startet/abstuerzt - danach kommt
# fuer sie nie mehr ein "aufgelegt" (code -2)
function Close-AllActive([string]$ts, [int]$code) {
    foreach ($r in @($script:active.Values) + @($script:pending)) {
        # Ende = letzter bekannter Zustand des Anrufs (genauer als der Neustart-Zeitpunkt)
        if ($r -and -not $r.end) { $r.end = if ($r.last) { $r.last } else { $ts }; $r.code = $code; $r.state = 6 }
    }
    $script:active = @{}
    $script:pending = $null
}

# Sicherheitsnetz: ein Anruf, der seit 10 min (Log-Zeit) nicht ueber "klingelt"
# hinausgekommen ist, ist tot (code -3). Laufende Gespraeche bleiben unberuehrt.
function Close-Stale {
    if (-not $script:lastLine) { return }
    $now = [datetime]::ParseExact($script:lastLine, 'yyyy-MM-dd HH:mm:ss', $null)
    foreach ($k in @($script:active.Keys)) {
        $r = $script:active[$k]
        if ($r.state -lt 5 -and ($now - [datetime]::ParseExact($r.last, 'yyyy-MM-dd HH:mm:ss', $null)).TotalMinutes -gt 10) {
            if (-not $r.end) { $r.end = $r.last; $r.code = -3; $r.state = 6 }
            $script:active.Remove($k)
        }
    }
    $p = $script:pending
    if ($p -and ($now - [datetime]::ParseExact($p.last, 'yyyy-MM-dd HH:mm:ss', $null)).TotalMinutes -gt 10) { Close-Pending $p.last }
}

# Waehlversuch beenden, ohne dass je ein SIP-Anruf zustande kam (code -1)
function Close-Pending([string]$ts) {
    $p = $script:pending
    if ($p -and -not $p.end) { $p.end = $ts; $p.code = -1; $p.state = 6 }
    $script:pending = $null
}

function Get-Field([string]$t, [string]$name) {
    $m = [regex]::Match($t, "\b$name\s*:\s*'([^']*)'")
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($t, "\b$name\s*:\s*(-?\d+)")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Add-CallState([string]$ts, [string]$text) {
    $state  = [int](Get-Field $text 'state')
    $code   = Get-Field $text 'last_status'; if ($null -eq $code) { $code = 0 }; $code = [int]$code
    $number = Get-Field $text 'number'
    $sipId  = Get-Field $text 'sip_id'; if ($null -eq $sipId) { $sipId = '' }
    $callId = Get-Field $text 'call_id'

    $rec = $script:active[$callId]
    if ($rec -and $sipId -and $rec.sipId -and $rec.sipId -ne $sipId) { $rec = $null }
    if (-not $rec) {
        # pjsip: 1 = CALLING (ausgehend), 2 = INCOMING (eingehend)
        if ($state -ne 2 -and $script:pending -and -not $script:pending.end) {
            $rec = $script:pending          # SIP-Anruf gehoert zum letzten Klick
            $script:pending = $null
        } else {
            $dir = 'out'; if ($state -eq 2) { $dir = 'in' }
            $rec = New-Attempt $ts $number $dir $state
        }
        $script:active[$callId] = $rec
    }
    if ($sipId -and -not $rec.sipId) { $rec.sipId = $sipId }
    if ($number) { $rec.number = $number }
    $rec.last = $ts
    $rec.state = $state
    if ($code -gt 0) { $rec.code = $code }
    switch ($state) {
        3 { if (-not $rec.ring) { $rec.ring = $ts } }
        5 { if (-not $rec.answer) { $rec.answer = $ts } }
        6 { if (-not $rec.end) { $rec.end = $ts }; $script:active.Remove($callId) }
    }
}

function Complete-Block {
    $b = $script:blk; $script:blk = $null
    Add-CallState $b.Ts $b.Text.ToString()
}

function Invoke-Line([string]$line) {
    if ($null -ne $script:blk) {
        if ($line -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ') {
            $script:blk = $null   # Block nie geschlossen -> verwerfen
        } else {
            [void]$script:blk.Text.Append(' ').Append($line)
            if ($line.TrimEnd().EndsWith('}')) { Complete-Block }
            elseif ($script:blk.Text.Length -gt 8000) { $script:blk = $null }
            return
        }
    }
    # eigene Nebenstelle aus dem Linkus-Login ("registername: '30'") - fuer das Team-Calltracking
    if ($line.IndexOf('registername:') -ge 0) {
        $m = [regex]::Match($line, "registername:\s*'(\d{2,6})'")
        if ($m.Success) { $script:ext = $m.Groups[1].Value }
    }
    if ($line.Length -lt 21) { return }
    if ($line.IndexOf(' SipCall ') -eq 19) {
        $m = [regex]::Match($line, "\{ number: '([^']*)'")
        if ($m.Success) {
            # jeder Waehlvorgang = ein Brutto-Wahlversuch
            Close-Pending $line.Substring(0, 19)
            $script:pending = New-Attempt $line.Substring(0, 19) $m.Groups[1].Value 'out' 0
        } elseif ($script:pending -and $line.EndsWith('callid')) {
            Close-Pending $line.Substring(0, 19)   # aufgelegt, bevor ein Anruf entstand
        }
    } elseif ($line.IndexOf(' CalloutSipErr ') -eq 19) {
        if ($script:pending) {
            $script:pending.sipErr = $true
            if ($line.IndexOf($TimeoutWord) -ge 0) { Close-Pending $line.Substring(0, 19) }
        }
    } elseif ($line.IndexOf(' Desktop PC ') -eq 19 -and $line.IndexOf(' pid: ') -gt 0) {
        # Linkus-Start (z.B. nach Absturz): offene Anrufe sind beendet - Ende = letzte
        # Logzeile vor dem Neustart
        $endTs = if ($script:lastLine) { $script:lastLine } else { $line.Substring(0, 19) }
        Close-AllActive $endTs -2
    } elseif ($line.IndexOf('CallRequestManager sip-callback-call-state:') -ge 0) {
        $script:blk = @{ Ts = $line.Substring(0, 19); Text = (New-Object Text.StringBuilder $line) }
        if ($line.TrimEnd().EndsWith('}')) { Complete-Block }
    } elseif ($line.IndexOf('acc_id') -ge 0) {
        $m = [regex]::Match($line, "type: '(\w+)',\s*status: (\d+)")
        if ($m.Success) { $script:reg = @{ type = $m.Groups[1].Value; status = [int]$m.Groups[2].Value; ts = $line.Substring(0, 19) } }
    }
    if ($line -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ') { $script:lastLine = $line.Substring(0, 19) }
}

# Neuer Dateianfang (Log rotiert): nur die Leseposition zuruecksetzen - laufende
# Anrufe (active/pending) bleiben, ihr Auflegen steht im neuen Log
function Reset-FilePos {
    if ($script:partial) { Invoke-Line $script:partial }
    $script:pos = 0L; $script:partial = ''; $script:blk = $null
    $script:dec = [Text.Encoding]::UTF8.GetDecoder()
}

# Liest $path ab $script:pos bis zum Ende (Linkus-Dateien nur lesend oeffnen)
function Read-Chunk([string]$path) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    $sb = New-Object Text.StringBuilder
    try {
        if ($fs.Length -le $script:pos) { return }
        [void]$fs.Seek($script:pos, 'Begin')
        $buf = New-Object byte[] 262144
        $chars = New-Object char[] 262200
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $c = $script:dec.GetChars($buf, 0, $n, $chars, 0)
            [void]$sb.Append($chars, 0, $c)
            $script:pos += $n
        }
    } finally { $fs.Dispose() }
    $lines = ($script:partial + $sb.ToString()) -split "`r?`n"
    $script:partial = $lines[-1]
    for ($i = 0; $i -lt $lines.Length - 1; $i++) { Invoke-Line $lines[$i] }
}

function Get-OldLogPath { Join-Path (Split-Path -Parent $LogPath) 'Desktop.old.log' }

# Kennung einer Logdatei = ihre ersten Bytes (aendert sich, sobald Linkus eine neue Datei anfaengt)
function Get-FileSig([string]$path) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    try { $b = New-Object byte[] 96; $n = $fs.Read($b, 0, 96) } finally { $fs.Dispose() }
    if ($n -lt 96) { return $null }   # zu kurz, um sicher zu vergleichen
    [Convert]::ToBase64String($b, 0, $n)
}

function Read-NewLog {
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return }
    $sig = Get-FileSig $LogPath
    $rotated = (Get-Item -LiteralPath $LogPath).Length -lt $script:pos -or
               ($sig -and $script:fileSig -and $sig -ne $script:fileSig)
    if ($sig) { $script:fileSig = $sig }
    if ($rotated) {
        # Linkus hat rotiert (Desktop.log -> Desktop.old.log): erst den Rest des alten Logs lesen
        $old = Get-OldLogPath
        if ((Test-Path $old) -and (Get-Item -LiteralPath $old).Length -ge $script:pos) {
            try { Read-Chunk $old } catch { Write-Warning $_ }
        }
        Reset-FilePos
        Save-RotatedLogs
    }
    Read-Chunk $LogPath
    Close-Stale
}

# ---------------------------------------------------------------- Historie & Log-Archiv
# Alle Anrufe bleiben dauerhaft in anrufe-historie.tsv (auch wenn Linkus seine Logs
# rotiert/ueberschreibt). Rotierte Linkus-Logs werden als ZIP-Kopie archiviert.
$HistPath = if ($HistFile) { $HistFile } else { Join-Path $here 'anrufe-historie.tsv' }
$ArchiveDir = if ($ArchivePath) { $ArchivePath } else { Join-Path $here 'linkus-log-archiv' }
$HistCols = 'start', 'number', 'dir', 'ring', 'answer', 'end', 'code', 'state', 'sipErr'
$script:histHead = New-Object System.Collections.Generic.List[string]   # aeltere Zeilen, nicht im Speicher
$script:histSavedSig = ''

function ConvertTo-HistLine($c) {
    ($HistCols | ForEach-Object { $v = $c[$_]; if ($null -eq $v) { '' } else { ([string]$v) -replace "[`t`r`n]", ' ' } }) -join "`t"
}

# Laedt alle Anrufe vor $cutoff (die spaeteren kommen gleich frisch aus den Logs)
function Import-History([string]$cutoff) {
    if (-not (Test-Path -LiteralPath $HistPath)) { return }
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($l in [IO.File]::ReadAllLines($HistPath, [Text.Encoding]::UTF8)) {
        if (-not $l -or $l.StartsWith('start')) { continue }
        if ($cutoff -and $l.Substring(0, [Math]::Min(19, $l.Length)) -ge $cutoff) { continue }
        $rows.Add($l)
    }
    $keep = [Math]::Max(0, $rows.Count - $MaxCalls)
    for ($i = 0; $i -lt $keep; $i++) { $script:histHead.Add($rows[$i]) }
    for ($i = $keep; $i -lt $rows.Count; $i++) {
        $f = $rows[$i].Split("`t")
        $n = { param($s) if ($s) { $s } else { $null } }
        $script:calls.Add(@{ id = $script:nextId; sipId = ''; number = $f[1]; dir = $f[2]; start = $f[0]; last = $f[0]
                             ring = (& $n $f[3]); answer = (& $n $f[4]); end = (& $n $f[5]); code = [int]$f[6]; state = [int]$f[7]
                             sipErr = ($f[8] -eq 'True') })
        $script:nextId++
    }
}

function Save-History {
    $last = if ($script:calls.Count) { $script:calls[$script:calls.Count - 1] } else { $null }
    $sig = "$($script:histHead.Count)|$($script:calls.Count)|$($script:lastLine)"
    if ($sig -eq $script:histSavedSig) { return }
    $tmp = "$HistPath.tmp"
    $w = New-Object IO.StreamWriter($tmp, $false, (New-Object Text.UTF8Encoding $true))
    try {
        $w.WriteLine(($HistCols -join "`t"))
        foreach ($l in $script:histHead) { $w.WriteLine($l) }
        foreach ($c in $script:calls) { $w.WriteLine((ConvertTo-HistLine $c)) }
    } finally { $w.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $HistPath -Force
    $script:histSavedSig = $sig
}

# Kopie (ZIP) jeder rotierten Linkus-Logdatei, bevor Linkus sie beim naechsten
# Rotieren ueberschreibt. Linkus' eigene Dateien werden nur gelesen.
function Save-RotatedLogs {
    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path $ArchiveDir)) { [void](New-Item -ItemType Directory -Path $ArchiveDir) }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    foreach ($name in 'Desktop.old.log', 'pjsip.log.1', 'sdk.log.1') {
        $src = Join-Path $dir $name
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $fi = Get-Item -LiteralPath $src
        $zip = Join-Path $ArchiveDir ('{0}_{1:yyyyMMdd-HHmmss}.zip' -f ($name -replace '\.', '_'), $fi.LastWriteTime)
        if (Test-Path -LiteralPath $zip) { continue }
        try {
            $in = [IO.File]::Open($src, 'Open', 'Read', 'ReadWrite, Delete')
            $za = [IO.Compression.ZipFile]::Open("$zip.tmp", 'Create')
            try {
                $e = $za.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
                $out = $e.Open(); try { $in.CopyTo($out) } finally { $out.Dispose() }
            } finally { $za.Dispose(); $in.Dispose() }
            Move-Item -LiteralPath "$zip.tmp" -Destination $zip
            Write-Host "Log archiviert: $zip"
        } catch { Write-Warning "Archivieren von $name fehlgeschlagen: $_" }
    }
}

# Zeitstempel der ersten Logzeile einer Datei
function Get-FirstLogTs([string]$path) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite, Delete')
    try { $b = New-Object byte[] 64; $n = $fs.Read($b, 0, 64) } finally { $fs.Dispose() }
    $m = [regex]::Match([Text.Encoding]::UTF8.GetString($b, 0, $n), '\d{4}-\d\d-\d\d \d\d:\d\d:\d\d')
    if ($m.Success) { $m.Value } else { $null }
}

# ---------------------------------------------------------------- Team-Calltracking
# Meldet die Anrufe dieses PCs an das Team-Dashboard (einstellungen.json: teamUrl + teamCode).
# Gesendet werden nur Anrufdaten (Zeit, Nummer, Ergebnis) - nie Linkus-Logs oder Zugangsdaten.
# Pro Tag wird nur gesendet, was sich geaendert hat (Stand in sync-stand.json), hoechstens alle
# 90 s; ohne Aenderung alle 15 min ein Lebenszeichen.
$AgentVersion = '2026-10-21'
$SyncPath = Join-Path $here 'sync-stand.json'
$script:syncSigs = @{}
$script:lastPush = [datetime]::MinValue
$script:sync = @{ ok = $null; last = $null; err = $null }
if (Test-Path -LiteralPath $SyncPath) {
    try {
        $sj = [IO.File]::ReadAllText($SyncPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($sj.sigs) { foreach ($p in $sj.sigs.PSObject.Properties) { $script:syncSigs[$p.Name] = [string]$p.Value } }
        if ([string]$sj.ext -match '^\d{2,6}$') { $script:ext = [string]$sj.ext }
    } catch { Write-Warning "sync-stand.json nicht lesbar - alles wird neu gesendet" }
}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function Get-MyExt { if ($Config.nebenstelle) { $Config.nebenstelle } else { $script:ext } }

function Sync-Team {
    if (-not $Config.teamUrl -or -not $Config.teamCode) { return }
    $ext = Get-MyExt
    if (-not $ext) { $script:sync.err = 'Nebenstelle unbekannt (in Linkus einmal ab- und anmelden)'; return }
    $now = Get-Date
    $since = ($now - $script:lastPush).TotalSeconds
    if ($since -lt 90) { return }

    $byDay = @{}
    foreach ($c in $script:calls) {
        $d = $c.start.Substring(0, 10)
        if (-not $byDay.ContainsKey($d)) { $byDay[$d] = New-Object System.Collections.Generic.List[object] }
        $byDay[$d].Add($c)
    }
    $md5 = [Security.Cryptography.MD5]::Create()
    $changed = @{}
    foreach ($d in $byDay.Keys) {
        $s = ($byDay[$d] | ForEach-Object { ConvertTo-HistLine $_ }) -join "`n"
        $h = [Convert]::ToBase64String($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes("$ext|$s")))
        if ($script:syncSigs[$d] -ne $h) { $changed[$d] = $h }
    }
    if (-not $changed.Count -and $since -lt 900) { return }

    $send = @($changed.Keys | Sort-Object -Descending | Select-Object -First 31)
    $days = @{}
    foreach ($d in $send) { $days[$d] = [object[]]$byDay[$d].ToArray() }
    # laufend = ohne Ende, letzter Zustand < 2 h alt (ein Klick ohne SIP-Anruf hoechstens 60 s)
    $live = @(@($script:active.Values) + @($script:pending) | Where-Object {
            $_ -and -not $_.end -and $_.last -and (($now - [datetime]::ParseExact($_.last, 'yyyy-MM-dd HH:mm:ss', $null)).TotalSeconds -lt
                $(if ($_.state -eq 0) { 60 } else { 7200 })) } |
        ForEach-Object { @{ number = $_.number; dir = $_.dir; start = $_.start; ring = $_.ring; answer = $_.answer } })
    $reg = if ($script:reg) { @{ status = $script:reg.status; ts = $script:reg.ts } } else { $null }
    $body = @{ ext = $ext; agent = $AgentVersion; heute = $now.ToString('yyyy-MM-dd'); days = $days; live = [object[]]$live; reg = $reg }
    $json = ConvertTo-Json -InputObject $body -Depth 6 -Compress
    $script:lastPush = $now   # auch bei Fehler: naechster Versuch fruehestens in 90 s
    try {
        $r = Invoke-RestMethod -Uri ($Config.teamUrl + '/api/ct?a=sync') -Method Post -TimeoutSec 20 `
            -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' `
            -Headers @{ 'x-team-code' = $Config.teamCode }
        if (-not $r.ok) { throw "Antwort: $($r.error)" }
        foreach ($d in $send) { $script:syncSigs[$d] = $changed[$d] }
        $w = @{ ext = $ext; sigs = $script:syncSigs }
        [IO.File]::WriteAllText($SyncPath, (ConvertTo-Json -InputObject $w -Depth 3), (New-Object Text.UTF8Encoding $false))
        if ($script:sync.err) { Write-Host 'Team-Sync wieder ok.' -ForegroundColor Green }
        $script:sync.ok = $true; $script:sync.last = $now.ToString('yyyy-MM-dd HH:mm:ss'); $script:sync.err = $null
    } catch {
        $msg = ("$_" -replace '[\x00-\x1f]+', ' ').Trim()
        if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) }
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $msg = 'Team-Code falsch - Installieren.cmd erneut ausfuehren' }
        if ($script:sync.err -ne $msg) { Write-Warning "Team-Sync fehlgeschlagen: $msg" }
        $script:sync.ok = $false; $script:sync.err = $msg
    }
}

# ---------------------------------------------------------------- JSON
function Esc([string]$s) {
    if ($null -eq $s) { return 'null' }
    '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Get-StateJson {
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('{"now":').Append((Esc (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')))
    [void]$sb.Append(',"logPath":').Append((Esc $LogPath))
    [void]$sb.Append(',"lastLogLine":').Append((Esc $script:lastLine))
    [void]$sb.Append(',"team":{"url":').Append((Esc $Config.teamUrl)).Append(',"ext":').Append((Esc (Get-MyExt))).Append(',"last":').Append((Esc $script:sync.last)).Append(',"err":').Append((Esc $script:sync.err)).Append('}')
    if ($script:reg) {
        [void]$sb.Append(',"reg":{"type":').Append((Esc $script:reg.type)).Append(',"status":').Append($script:reg.status).Append(',"ts":').Append((Esc $script:reg.ts)).Append('}')
    } else { [void]$sb.Append(',"reg":null') }
    [void]$sb.Append(',"calls":[')
    $first = $true
    foreach ($c in $script:calls) {
        if (-not $first) { [void]$sb.Append(',') }; $first = $false
        [void]$sb.Append('{"id":').Append($c.id).Append(',"number":').Append((Esc $c.number)).Append(',"dir":').Append((Esc $c.dir))
        [void]$sb.Append(',"start":').Append((Esc $c.start)).Append(',"ring":').Append((Esc $c.ring)).Append(',"answer":').Append((Esc $c.answer))
        [void]$sb.Append(',"end":').Append((Esc $c.end)).Append(',"code":').Append($c.code).Append(',"state":').Append($c.state)
        [void]$sb.Append(',"sipErr":').Append($(if ($c.sipErr) { 'true' } else { 'false' })).Append('}')
    }
    [void]$sb.Append(']}')
    $sb.ToString()
}

# ---------------------------------------------------------------- Powerdialer-Protokoll
# Jeder Waehlvorgang landet in Powerdialer-Anrufprotokoll.csv auf dem Desktop. Eine Firma, ein
# Ansprechpartner und eine Nummer werden pro Modus (LIVE/TEST) nie ein zweites Mal gewaehlt.
$ProtoPath = if ($ProtoFile) { $ProtoFile } else { Join-Path $DesktopDir 'Powerdialer-Anrufprotokoll.csv' }
$ProtoCols = 'Zeit', 'Modus', 'FirmaID', 'Firma', 'AP-ID', 'Ansprechpartner', 'Nummer', 'Gewaehlt', 'Ergebnis', 'LogId'

# gleiche Nummer in verschiedenen Schreibweisen (0151..., +49151..., 00049151...) -> gleicher Schluessel
function Get-NumKey([string]$n) {
    # fuehrende Nullen (Amt-0, 00-Vorwahl) zaehlen nicht - sonst passen kurze Nummern nicht zusammen
    $d = ($n -replace '\D', '').TrimStart('0')
    if ($d.Length -gt 9) { $d.Substring($d.Length - 9) } else { $d }
}

function Get-Proto {
    if (-not (Test-Path -LiteralPath $ProtoPath)) { return @() }
    @(Import-Csv -LiteralPath $ProtoPath -Delimiter ';' -Encoding UTF8)
}

# Wiederholung (Liste markiert Zeile als "nicht erreicht"): gesperrt bleibt nur, was heute schon
# gewaehlt wurde oder wo schon ein echtes Gespraech (>= 30 s) stattfand
function Test-RetryBlock($r) {
    if (([string]$r.Zeit).StartsWith((Get-Date -Format 'yyyy-MM-dd'))) { return $true }
    if ([string]$r.Ergebnis -match 'Gespr\S*ch (\d+):(\d\d)') { return ([int]$Matches[1] * 60 + [int]$Matches[2]) -ge 30 }
    $false
}

function Find-Duplicate($rows, [string]$mode, [string]$firmaId, [string]$apId, [string]$number, [bool]$retry = $false) {
    $key = Get-NumKey $number
    foreach ($r in $rows) {
        if ($r.Modus -ne $mode) { continue }
        if ($retry -and -not (Test-RetryBlock $r)) { continue }
        if ($firmaId -and $r.FirmaID -eq $firmaId) { return "Firma $($r.Firma) schon angerufen ($($r.Zeit))" }
        if ($apId -and $r.'AP-ID' -eq $apId) { return "$($r.Ansprechpartner) schon angerufen ($($r.Zeit))" }
        if ($key.Length -ge 5 -and (Get-NumKey $r.Nummer) -eq $key) { return "Nummer schon angerufen bei $($r.Firma) ($($r.Zeit))" }
    }
    $null
}

function Add-ProtoRow([hashtable]$row) {
    $q = { param($v) '"' + ([string]$v).Replace('"', '""') + '"' }
    $utf8 = New-Object Text.UTF8Encoding $true
    if (-not (Test-Path -LiteralPath $ProtoPath)) {
        [IO.File]::WriteAllText($ProtoPath, (($ProtoCols | ForEach-Object { & $q $_ }) -join ';') + "`r`n", $utf8)
    }
    $line = ($ProtoCols | ForEach-Object { & $q $row[$_] }) -join ';'
    [IO.File]::AppendAllText($ProtoPath, $line + "`r`n", (New-Object Text.UTF8Encoding $false))
}

function Set-ProtoResult([string]$logId, [string]$result) {
    $rows = Get-Proto
    $hit = $rows | Where-Object { $_.LogId -eq $logId }
    if (-not $hit) { return }
    foreach ($h in $hit) { $h.Ergebnis = $result }
    $rows | Export-Csv -LiteralPath $ProtoPath -Delimiter ';' -Encoding UTF8 -NoTypeInformation
}

# Alle Telefonnummern aus den HTML-Listen auf dem Desktop (Freigabe fuer file://-Seiten)
$TestNumber = $Config.testNumber
function Get-DesktopListNumbers {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in Get-ChildItem -LiteralPath $DesktopDir -Filter '*.htm*' -File) {
        $t = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
        foreach ($m in [regex]::Matches($t, '\+?\d[\d /().-]{4,24}\d')) {
            $k = Get-NumKey $m.Value
            if ($k.Length -ge 6) { [void]$set.Add($k) }
        }
    }
    , $set
}

function Get-CalledJson([string]$mode) {
    $rows = @(Get-Proto | Where-Object { $_.Modus -eq $mode })
    $f = ($rows | Where-Object FirmaID | ForEach-Object { Esc $_.FirmaID }) -join ','
    $a = ($rows | Where-Object { $_.'AP-ID' } | ForEach-Object { Esc $_.'AP-ID' }) -join ','
    $n = ($rows | Where-Object Nummer | ForEach-Object { Esc (Get-NumKey $_.Nummer) }) -join ','
    $rb = @($rows | Where-Object { Test-RetryBlock $_ })
    $rf = ($rb | Where-Object FirmaID | ForEach-Object { Esc $_.FirmaID }) -join ','
    $ra = ($rb | Where-Object { $_.'AP-ID' } | ForEach-Object { Esc $_.'AP-ID' }) -join ','
    $rn = ($rb | Where-Object Nummer | ForEach-Object { Esc (Get-NumKey $_.Nummer) }) -join ','
    '{"ok":true,"firmen":[' + $f + '],"aps":[' + $a + '],"nummern":[' + $n + '],' +
    '"retry":{"firmen":[' + $rf + '],"aps":[' + $ra + '],"nummern":[' + $rn + ']}}'
}

Add-Type -AssemblyName System.Web
function Get-Query($ctx) { , [Web.HttpUtility]::ParseQueryString($ctx.Request.Url.Query, [Text.Encoding]::UTF8) }

function Send-Json($ctx, [string]$json, [int]$status = 200) {
    Send-Response $ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8' $status
}

function Send-Response($ctx, [byte[]]$bytes, [string]$type, [int]$status = 200) {
    $res = $ctx.Response
    $res.StatusCode = $status
    $res.ContentType = $type
    $res.Headers.Add('Cache-Control', 'no-store')
    # Powerdialer laeuft im CRM (https://nina.ppedv.de) oder in einer Liste als file:// (Origin "null")
    $origin = $ctx.Request.Headers['Origin']
    if ($origin -eq $CrmOrigin -or $origin -eq 'null') {
        $res.Headers.Add('Access-Control-Allow-Origin', $origin)
        $res.Headers.Add('Access-Control-Allow-Private-Network', 'true')
        $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    }
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

# ---------------------------------------------------------------- main
Write-Host "Linkus-Log: $LogPath"
Write-Host 'Lese bisherige Anrufe ein ...'
if ($LogPath -and (Test-Path $LogPath)) {
    # Historie bis zum Beginn der vorhandenen Logs, danach Desktop.old.log + Desktop.log
    $old = Get-OldLogPath
    $hasOld = Test-Path $old
    $cutoff = Get-FirstLogTs $(if ($hasOld) { $old } else { $LogPath })
    Import-History $cutoff
    Write-Host ("{0} Anrufe aus der Historie (vor {1})." -f ($script:calls.Count + $script:histHead.Count), $cutoff)
    if ($hasOld) { Read-Chunk $old; Reset-FilePos }
    Read-NewLog
} else { Import-History $null }
Write-Host ("{0} Anrufe gesamt." -f ($script:calls.Count + $script:histHead.Count))

$url = "http://localhost:$Port/"
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($url)
try {
    $listener.Start()
} catch {
    # Port belegt - laeuft das Dashboard schon? Dann einfach oeffnen.
    try { [void](Invoke-WebRequest "${url}api/state" -UseBasicParsing -TimeoutSec 3) } catch {
        Write-Host "Port $Port ist von einem anderen Programm belegt. Start mit anderem Port: server.ps1 -Port 8766" -ForegroundColor Red
        exit 1
    }
    Write-Host "Dashboard laeuft bereits: $url"
    if (-not $NoBrowser) { Start-Process $url }
    exit 0
}
Write-Host "Dashboard laeuft: $url   (Beenden mit Strg+C)"
if (-not $NoBrowser) { Start-Process $url }

# erst jetzt schreiben - eine zweite Instanz (Port belegt) hat oben schon beendet
if ($LogPath) { try { Save-RotatedLogs } catch { Write-Warning $_ } }
try { Save-History } catch { Write-Warning "Historie nicht gespeichert: $_" }
$lastSave = Get-Date
try { Sync-Team } catch { Write-Warning "Team-Sync: $_" }

$lastRead = Get-Date
try {
    $task = $listener.GetContextAsync()
    while ($listener.IsListening) {
        if ($task.Wait(400)) {
            $ctx = $task.Result
            $task = $listener.GetContextAsync()
            try {
                if ($ctx.Request.HttpMethod -eq 'OPTIONS') {
                    Send-Response $ctx ([byte[]]@()) 'text/plain' 204
                    continue
                }
                switch ($ctx.Request.Url.AbsolutePath) {
                    '/' {
                        Send-Response $ctx ([IO.File]::ReadAllBytes($htmlPath)) 'text/html; charset=utf-8'
                    }
                    '/powerdialer' {
                        Send-Response $ctx ([IO.File]::ReadAllBytes($dialerHtmlPath)) 'text/html; charset=utf-8'
                    }
                    '/powerdialer.js' {
                        $js = [IO.File]::ReadAllText($dialerJsPath, [Text.Encoding]::UTF8)
                        $cfg = '{ testNumber: ' + (Esc $Config.testNumber) + ', amtPrefix: ' + (Esc $Config.amtPrefix) + ' }'
                        $js = [regex]::Replace($js, '/\*PD_CONFIG\*/.*?/\*PD_CONFIG_END\*/', { param($m) "/*PD_CONFIG*/$cfg/*PD_CONFIG_END*/" })
                        Send-Response $ctx ([Text.Encoding]::UTF8.GetBytes($js)) 'application/javascript; charset=utf-8'
                    }
                    { $_ -like '/api/*' -and $_ -ne '/api/state' -and -not (
                        $ctx.Request.Headers['Origin'] -eq $CrmOrigin -or
                        $ctx.Request.Headers['Origin'] -eq 'null' -or
                        $ctx.Request.Headers['Sec-Fetch-Site'] -eq 'same-origin') } {
                        # Powerdialer-Schnittstellen nur fuer das CRM, file://-Listen und die Listen unter /desktop/
                        Send-Json $ctx '{"ok":false,"error":"origin"}' 403
                        break
                    }
                    '/api/called' {
                        $mode = if ((Get-Query $ctx)['test'] -eq '1') { 'TEST' } else { 'LIVE' }
                        Send-Json $ctx (Get-CalledJson $mode)
                    }
                    '/api/dial' {
                        $qs = Get-Query $ctx
                        $num = [string]$qs['number']            # was gewaehlt wird (im Test die Testnummer)
                        $contact = [string]$qs['contact']       # Nummer des Kontakts
                        if (-not $contact) { $contact = $num }
                        $mode = if ($qs['test'] -eq '1') { 'TEST' } else { 'LIVE' }
                        if ($num -notmatch '^\+?\d{3,20}$') {
                            Send-Json $ctx '{"ok":false,"error":"number"}' 400
                            break
                        }
                        if ($ctx.Request.Headers['Origin'] -eq 'null') {
                            # Origin "null" kann auch eine fremde Seite (sandboxed iframe) senden ->
                            # nur Nummern aus den HTML-Listen auf dem Desktop bzw. die Testnummer zulassen
                            $known = Get-DesktopListNumbers
                            $okContact = $known.Contains((Get-NumKey $contact))
                            $okDial = ((Get-NumKey $num) -eq (Get-NumKey $contact)) -or ($mode -eq 'TEST' -and (Get-NumKey $num) -eq (Get-NumKey $TestNumber))
                            if (-not ($okContact -and $okDial)) {
                                Send-Json $ctx ('{"ok":false,"error":"unbekannt","detail":' + (Esc "Nummer steht in keiner Liste auf dem Desktop") + '}') 403
                                break
                            }
                        }
                        try {
                            $dup = Find-Duplicate (Get-Proto) $mode $qs['firmaId'] $qs['apId'] $contact ($qs['retry'] -eq '1')
                        } catch {
                            Send-Json $ctx ('{"ok":false,"error":"protokoll","detail":' + (Esc "Protokoll nicht lesbar (in Excel geoeffnet?): $ProtoPath") + '}') 500
                            break
                        }
                        if ($dup) {
                            Write-Host "Powerdialer: NICHT gewaehlt - $dup" -ForegroundColor Yellow
                            Send-Json $ctx ('{"ok":false,"error":"doppelt","detail":' + (Esc $dup) + '}') 409
                            break
                        }
                        $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                        $logId = [guid]::NewGuid().ToString('N').Substring(0, 12)
                        try {
                            Add-ProtoRow @{ Zeit = $now; Modus = $mode; FirmaID = $qs['firmaId']; Firma = $qs['firma']
                                            'AP-ID' = $qs['apId']; Ansprechpartner = $qs['name']; Nummer = $contact
                                            Gewaehlt = $num; Ergebnis = 'gewaehlt'; LogId = $logId }
                        } catch {
                            # ohne Protokoll keine Sperre gegen Doppelanrufe -> lieber nicht waehlen
                            Send-Json $ctx ('{"ok":false,"error":"protokoll","detail":' + (Esc "Protokoll nicht schreibbar (in Excel geoeffnet?): $ProtoPath") + '}') 500
                            break
                        }
                        Read-NewLog
                        Write-Host "Powerdialer waehlt $num ($mode) - $($qs['firma']) / $($qs['name'])"
                        if ($DryRun) { Write-Host '  (Probelauf - nicht gewaehlt)' } else { Start-Process "tel:$num" }
                        Send-Json $ctx ('{"ok":true,"now":' + (Esc $now) + ',"logId":' + (Esc $logId) + '}')
                    }
                    '/api/result' {
                        try { $q = Get-Query $ctx; Set-ProtoResult $q['logId'] $q['result'] } catch { Write-Warning $_ }
                        Send-Json $ctx '{"ok":true}'
                    }
                    '/api/state' {
                        Read-NewLog; $lastRead = Get-Date
                        Send-Response $ctx ([Text.Encoding]::UTF8.GetBytes((Get-StateJson))) 'application/json; charset=utf-8'
                    }
                    { $_ -like '/desktop/*' } {
                        # Eigene Anruflisten (HTML) vom Desktop, damit der Powerdialer darauf laufen kann
                        $name = [Uri]::UnescapeDataString($_.Substring(9))
                        $file = Join-Path $DesktopDir $name
                        if ($name -match '^[\w .()-]+\.html?$' -and (Test-Path -LiteralPath $file -PathType Leaf)) {
                            # Powerdialer beim Ausliefern einbauen -> die Datei selbst bleibt unveraendert
                            $html = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
                            $i = $html.LastIndexOf('</body>', [StringComparison]::OrdinalIgnoreCase)
                            $tag = '<script src="/powerdialer.js"></script>'
                            if ($i -ge 0) { $html = $html.Insert($i, $tag) } else { $html += $tag }
                            Send-Response $ctx ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8'
                        } else {
                            Send-Response $ctx ([Text.Encoding]::UTF8.GetBytes('not found')) 'text/plain' 404
                        }
                    }
                    default { Send-Response $ctx ([Text.Encoding]::UTF8.GetBytes('not found')) 'text/plain' 404 }
                }
            } catch {
                Write-Warning $_
                try { $ctx.Response.Abort() } catch {}
            }
        }
        if (((Get-Date) - $lastRead).TotalMilliseconds -gt 1000) {
            if (-not $LogPath) { $LogPath = Find-LogPath }
            try { Read-NewLog } catch { Write-Warning $_ }
            $lastRead = Get-Date
        }
        if (((Get-Date) - $lastSave).TotalSeconds -gt 30) {
            try { Save-History } catch { Write-Warning "Historie nicht gespeichert: $_" }
            if ($LogPath) { try { Save-RotatedLogs } catch { Write-Warning $_ } }
            $lastSave = Get-Date
            try { Sync-Team } catch { Write-Warning "Team-Sync: $_" }
        }
    }
} finally {
    try { Save-History } catch {}
    $listener.Stop(); $listener.Close()
}
