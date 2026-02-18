# ============================================================
# BIDIREKTIONALER SYNC FÜR NETZLAUFWERKE (Produktionsversion)
# ============================================================
#Requires -Version 5.1

[CmdletBinding()]
param(
    # ── VARIANTE 1: Gleicher Ordnername auf beiden Laufwerken ──
    # Laufwerke angeben + gemeinsamer Ordnername
    [string]$DriveA = "Z:\",
    [string]$DriveB = "Y:\",
    [string]$FolderName,

    # ── VARIANTE 2: Unterschiedliche Pfade pro Laufwerk ──
    # Komplette Pfade direkt angeben (überschreibt DriveA/DriveB/FolderName)
    [string]$PathA,
    [string]$PathB,

    # Backup / Konflikt / Log
    [string]$BackupRoot,
    [string]$ConflictRoot,
    [string]$LogFile,

    [int]$MaxRetries = 3,
    [int]$RetryDelaySeconds = 2,
    [int]$BackupRetentionDays = 30,
    [int]$ConflictTimeTolerance = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Pfade zusammenbauen / validieren ──────────────────────

if ($PathA -and $PathB) {
    # Variante 2: Direkte Pfade wurden angegeben → verwenden
    # DriveA für Backup/Log aus PathA ableiten
    $DriveA = Split-Path $PathA -Qualifier
    $DriveA += "\"
}
elseif ($FolderName) {
    # Variante 1: Laufwerk + Ordnername → zusammenbauen
    $PathA = Join-Path $DriveA $FolderName
    $PathB = Join-Path $DriveB $FolderName
}
else {
    Write-Host ""
    Write-Host "FEHLER: Du musst entweder angeben:" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Variante 1 (gleicher Ordner):" -ForegroundColor Yellow
    Write-Host "    .\sync.ps1 -FolderName ""Projekte""" -ForegroundColor Cyan
    Write-Host "    .\sync.ps1 -FolderName ""Projekte"" -DriveA ""X:\"" -DriveB ""W:\""" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Variante 2 (unterschiedliche Pfade):" -ForegroundColor Yellow
    Write-Host "    .\sync.ps1 -PathA ""Z:\Abteilung\Daten"" -PathB ""Y:\Backup\Projekte""" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

# Defaults für Backup/Conflict/Log auf DriveA, falls nicht explizit gesetzt
if (-not $BackupRoot)   { $BackupRoot   = Join-Path $DriveA "_SyncBackup" }
if (-not $ConflictRoot) { $ConflictRoot = Join-Path $DriveA "_SyncConflicts" }
if (-not $LogFile)      { $LogFile      = Join-Path $DriveA "sync_log.txt" }

# ── Interne Variablen ──────────────────────────────────────
$TimeStamp      = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$Stats          = @{ Copied = 0; Updated = 0; Conflicts = 0; Skipped = 0; Errors = 0; Deleted = 0 }

# Ordner, die der Sync selbst nutzt → werden NICHT synchronisiert
$ExcludeFolders = @(
    (Split-Path $BackupRoot -Leaf),
    (Split-Path $ConflictRoot -Leaf),
    '_SyncBackup',
    '_SyncConflicts'
)

# ── Hilfsfunktionen ────────────────────────────────────────

function Write-Log {
    param(
        [string]$Text,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Text"
    try {
        Add-Content -Path $LogFile -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Warning "Log-Schreiben fehlgeschlagen: $_"
    }
    switch ($Level) {
        "WARN"  { Write-Warning $Text }
        "ERROR" { Write-Error $Text -ErrorAction Continue }
        default { Write-Verbose $Text }
    }
}

function Get-HashSafe {
    param([string]$Path)
    try {
        return (Get-FileHash -Algorithm SHA256 -Path $Path -ErrorAction Stop).Hash
    }
    catch {
        Write-Log "Hash-Berechnung fehlgeschlagen: $Path – $_" -Level WARN
        return $null
    }
}

function Test-FileLocked {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        $stream.Dispose()
        return $false
    }
    catch {
        return $true
    }
}

function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [string]$Description = "Aktion"
    )
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            & $Action
            return $true
        }
        catch {
            if ($i -lt $MaxRetries) {
                Write-Log "Retry $i/$MaxRetries für '$Description': $_" -Level WARN
                Start-Sleep -Seconds $RetryDelaySeconds
            }
            else {
                Write-Log "Fehlgeschlagen nach $MaxRetries Versuchen – '$Description': $_" -Level ERROR
                $Stats.Errors++
                return $false
            }
        }
    }
}

function Backup-File {
    param(
        [string]$FilePath,
        [string]$RelativePath
    )
    $backupPath = Join-Path $BackupRoot "$TimeStamp\$RelativePath"
    $dir = Split-Path $backupPath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Invoke-WithRetry -Description "Backup $RelativePath" -Action {
        Copy-Item $FilePath $backupPath -Force -ErrorAction Stop
    } | Out-Null
}

function Handle-Conflict {
    param(
        [string]$FileA,
        [string]$FileB,
        [string]$RelativePath
    )
    $conflictDir = Join-Path $ConflictRoot $TimeStamp
    $conflictA = Join-Path $conflictDir "A_$RelativePath"
    $conflictB = Join-Path $conflictDir "B_$RelativePath"

    New-Item -ItemType Directory -Path (Split-Path $conflictA) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path $conflictB) -Force | Out-Null

    Copy-Item $FileA $conflictA -Force
    Copy-Item $FileB $conflictB -Force

    Write-Log "CONFLICT: $RelativePath" -Level WARN
    $Stats.Conflicts++
}

function Test-IsExcluded {
    param([string]$FullPath)
    foreach ($folder in $ExcludeFolders) {
        if ($FullPath -match "(\\|/)$([regex]::Escape($folder))(\\|/|$)") {
            return $true
        }
    }
    return $false
}

# ── Kern-Sync ──────────────────────────────────────────────

function Sync-Folders {
    param(
        [string]$Source,
        [string]$Target,
        [string]$Label
    )

    Write-Log "── Sync $Label : $Source → $Target ──"

    # Sicherstellen, dass Pfade mit Backslash enden
    if (-not $Source.EndsWith('\')) { $Source += '\' }
    if (-not $Target.EndsWith('\')) { $Target += '\' }

    try {
        $files = Get-ChildItem $Source -Recurse -File -ErrorAction Stop
    }
    catch {
        Write-Log "Kann Quelle nicht lesen: $Source – $_" -Level ERROR
        $Stats.Errors++
        return
    }

    foreach ($file in $files) {

        $relativePath = $file.FullName.Substring($Source.Length)

        # Ausgeschlossene Ordner überspringen
        if (Test-IsExcluded $file.FullName) { continue }

        # Gesperrte Quelldatei überspringen
        if (Test-FileLocked $file.FullName) {
            Write-Log "LOCKED (übersprungen): $relativePath" -Level WARN
            $Stats.Skipped++
            continue
        }

        $targetFile = Join-Path $Target $relativePath

        if (-not (Test-Path $targetFile)) {
            # ── Neue Datei → kopieren ──
            $dir = Split-Path $targetFile
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $ok = Invoke-WithRetry -Description "Copy $relativePath" -Action {
                Copy-Item $file.FullName $targetFile -Force -ErrorAction Stop
            }
            if ($ok) {
                Write-Log "COPIED: $relativePath"
                $Stats.Copied++
            }
        }
        else {
            # ── Datei existiert auf beiden Seiten ──
            if (Test-FileLocked $targetFile) {
                Write-Log "LOCKED TARGET (übersprungen): $relativePath" -Level WARN
                $Stats.Skipped++
                continue
            }

            $hashSource = Get-HashSafe $file.FullName
            $hashTarget = Get-HashSafe $targetFile

            # Wenn einer der Hashes null ist → Fehler, überspringen
            if ($null -eq $hashSource -or $null -eq $hashTarget) {
                Write-Log "HASH FEHLER (übersprungen): $relativePath" -Level WARN
                $Stats.Skipped++
                continue
            }

            if ($hashSource -ne $hashTarget) {
                $targetItem = Get-Item $targetFile
                $timeDiff   = [Math]::Abs(($file.LastWriteTime - $targetItem.LastWriteTime).TotalSeconds)

                if ($timeDiff -lt $ConflictTimeTolerance) {
                    # Beide fast gleichzeitig geändert → Konflikt
                    Handle-Conflict $file.FullName $targetFile $relativePath
                }
                elseif ($file.LastWriteTime -gt $targetItem.LastWriteTime) {
                    # Quelle neuer → Ziel aktualisieren
                    Backup-File $targetFile $relativePath
                    $ok = Invoke-WithRetry -Description "Update $relativePath" -Action {
                        Copy-Item $file.FullName $targetFile -Force -ErrorAction Stop
                    }
                    if ($ok) {
                        Write-Log "UPDATED (Quelle neuer): $relativePath"
                        $Stats.Updated++
                    }
                }
                # else: Ziel ist neuer → wird beim Rück-Sync behandelt
            }
        }
    }
}

function Remove-OrphanedFiles {
    <#
        Entfernt Dateien im Ziel, die in der Quelle nicht mehr existieren.
        Sichert sie vorher im Backup.
    #>
    param(
        [string]$Source,
        [string]$Target
    )

    if (-not $Source.EndsWith('\')) { $Source += '\' }
    if (-not $Target.EndsWith('\')) { $Target += '\' }

    try {
        $targetFiles = Get-ChildItem $Target -Recurse -File -ErrorAction Stop
    }
    catch { return }

    foreach ($tf in $targetFiles) {
        if (Test-IsExcluded $tf.FullName) { continue }

        $relativePath = $tf.FullName.Substring($Target.Length)
        $sourceFile   = Join-Path $Source $relativePath

        if (-not (Test-Path $sourceFile)) {
            # Prüfen ob die Datei auch in der Gegenrichtung fehlt
            # (wurde evtl. gerade erst kopiert) → nur entfernen wenn
            # sie tatsächlich auf KEINER Seite mehr existiert
            $otherSide = if ($Target -eq $PathA) { $PathB } else { $PathA }
            $otherFile = Join-Path $otherSide $relativePath

            if (-not (Test-Path $otherFile)) {
                Backup-File $tf.FullName $relativePath
                Remove-Item $tf.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "DELETED (Orphan): $relativePath"
                $Stats.Deleted++
            }
        }
    }
}

function Remove-OldBackups {
    <#
        Löscht Backup-Ordner, die älter als $BackupRetentionDays Tage sind.
    #>
    if (-not (Test-Path $BackupRoot)) { return }

    Get-ChildItem $BackupRoot -Directory | ForEach-Object {
        if ($_.CreationTime -lt (Get-Date).AddDays(-$BackupRetentionDays)) {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "BACKUP CLEANUP: $($_.Name) entfernt (älter als $BackupRetentionDays Tage)"
        }
    }

    if (-not (Test-Path $ConflictRoot)) { return }

    Get-ChildItem $ConflictRoot -Directory | ForEach-Object {
        if ($_.CreationTime -lt (Get-Date).AddDays(-$BackupRetentionDays)) {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "CONFLICT CLEANUP: $($_.Name) entfernt"
        }
    }
}

# ── Validierung ────────────────────────────────────────────

function Assert-Prerequisites {
    $ok = $true

    if (-not (Test-Path $PathA)) {
        Write-Log "FATAL: Pfad A nicht erreichbar: $PathA" -Level ERROR
        $ok = $false
    }
    if (-not (Test-Path $PathB)) {
        Write-Log "FATAL: Pfad B nicht erreichbar: $PathB" -Level ERROR
        $ok = $false
    }
    if (-not $ok) {
        Write-Log "Sync abgebrochen – Voraussetzungen nicht erfüllt." -Level ERROR
        exit 1
    }

    New-Item -ItemType Directory -Path $BackupRoot   -Force | Out-Null
    New-Item -ItemType Directory -Path $ConflictRoot  -Force | Out-Null
}

# ── Hauptablauf ────────────────────────────────────────────

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

Assert-Prerequisites

Write-Log "===== SYNC START ($TimeStamp) ====="
if ($FolderName) { Write-Log "Sync-Ordner: '$FolderName'" }
Write-Log "PathA=$PathA | PathB=$PathB | Retries=$MaxRetries | Retention=${BackupRetentionDays}d"

try {
    # Bidirektionaler Sync
    Sync-Folders -Source $PathA -Target $PathB -Label "A→B"
    Sync-Folders -Source $PathB -Target $PathA -Label "B→A"

    # Optional: verwaiste Dateien aufräumen (auskommentiert – bewusst aktivieren!)
    # Remove-OrphanedFiles -Source $PathA -Target $PathB
    # Remove-OrphanedFiles -Source $PathB -Target $PathA

    # Alte Backups aufräumen
    Remove-OldBackups
}
catch {
    Write-Log "UNERWARTETER FEHLER: $_" -Level ERROR
    $Stats.Errors++
}

$stopwatch.Stop()
$duration = $stopwatch.Elapsed.ToString("hh\:mm\:ss\.fff")

Write-Log ("STATISTIK: Kopiert={0} | Aktualisiert={1} | Konflikte={2} | Übersprungen={3} | Gelöscht={4} | Fehler={5}" -f `
    $Stats.Copied, $Stats.Updated, $Stats.Conflicts, $Stats.Skipped, $Stats.Deleted, $Stats.Errors)
Write-Log "===== SYNC END (Dauer: $duration) ====="

# Exit-Code: 0 = OK, 1 = mit Fehlern
if ($Stats.Errors -gt 0) { exit 1 } else { exit 0 }

