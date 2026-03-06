# ============================================================
# BIDIREKTIONALER SYNC FUER NETZLAUFWERKE (Produktionsversion)
# ============================================================
#Requires -Version 5.1

[CmdletBinding()]
param(
    # -- VARIANTE 1: Gleicher Ordnername auf beiden Laufwerken --
    # Laufwerke angeben + gemeinsamer Ordnername
    [string]$DriveA = "Z:\",
    [string]$DriveB = "Y:\",
    [string]$FolderName,

    # -- VARIANTE 2: Unterschiedliche Pfade pro Laufwerk --
    # Komplette Pfade direkt angeben (ueberschreibt DriveA/DriveB/FolderName)
    [string]$PathA,
    [string]$PathB,

    # Backup / Konflikt / Log
    [string]$BackupRoot,
    [string]$ConflictRoot,
    [string]$LogFile,
    [string]$ProgressFile,

    [int]$MaxRetries = 3,
    [int]$RetryDelaySeconds = 2,
    [int]$BackupRetentionDays = 30,
    [int]$ConflictTimeTolerance = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Pfade zusammenbauen / validieren -------------------------

if ($PathA -and $PathB) {
    # Variante 2: Direkte Pfade wurden angegeben -> verwenden
    # DriveA fuer Backup/Log aus PathA ableiten
    $DriveA = Split-Path $PathA -Qualifier
    $DriveA += "\"
}
elseif ($FolderName) {
    # Variante 1: Laufwerk + Ordnername -> zusammenbauen
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

# Script-Verzeichnis ermitteln (dort landen Backup, Konflikte, Log)
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) {
    # Fallback wenn per Scriptblock ausgefuehrt (z.B. via .bat Wrapper)
    $ScriptDir = (Get-Location).Path
}

# Defaults fuer Backup/Conflict/Log im Script-Verzeichnis, falls nicht explizit gesetzt
if (-not $BackupRoot)   { $BackupRoot   = Join-Path $ScriptDir "_SyncBackup" }
if (-not $ConflictRoot) { $ConflictRoot = Join-Path $ScriptDir "_SyncConflicts" }
if (-not $LogFile)      { $LogFile      = Join-Path $ScriptDir "sync_log.txt" }
if (-not $ProgressFile) { $ProgressFile = Join-Path $ScriptDir "sync_progress.txt" }
$RunLockFile = Join-Path $ScriptDir "sync.lock"

# -- Interne Variablen ----------------------------------------
$TimeStamp      = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$Stats          = @{ Copied = 0; Updated = 0; Conflicts = 0; Skipped = 0; Errors = 0; Deleted = 0 }

# Ordner, die der Sync selbst nutzt -> werden NICHT synchronisiert
$ExcludeFolders = @(
    (Split-Path $BackupRoot -Leaf),
    (Split-Path $ConflictRoot -Leaf),
    '_SyncBackup',
    '_SyncConflicts'
)

# Dateien, die nie synchronisiert/verschoben/gesichert werden sollen
$ExcludeFileNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$ExcludeFileNames.Add('sync_log.txt') | Out-Null
$ExcludeFileNames.Add('sync_progress.txt') | Out-Null
if ($LogFile) {
    $logLeaf = Split-Path $LogFile -Leaf
    if (-not [string]::IsNullOrWhiteSpace($logLeaf)) {
        $ExcludeFileNames.Add($logLeaf) | Out-Null
    }
}
if ($ProgressFile) {
    $progressLeaf = Split-Path $ProgressFile -Leaf
    if (-not [string]::IsNullOrWhiteSpace($progressLeaf)) {
        $ExcludeFileNames.Add($progressLeaf) | Out-Null
    }
}

$script:LastProgressPercent = -1
$script:RunLockHandle = $null

# -- Hilfsfunktionen ------------------------------------------

function Write-Log {
    param(
        [string]$Text,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Text"
    try {
        Add-Content -LiteralPath $LogFile -Value $entry -ErrorAction Stop
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

function Get-ErrorHint {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    if ($null -eq $ErrorRecord) { return "Keine Details verfuegbar." }

    $msg = $ErrorRecord.Exception.Message
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "$ErrorRecord" }

    if ($msg -match "Platzhalterzeichenmuster ist ung.*ltig") {
        return "Pfad enthaelt Wildcard-Zeichen wie [](). Verwende LiteralPath statt Path."
    }
    if ($msg -match "Eigenschaft .Hash. wurde.*nicht gefunden") {
        return "Hash konnte nicht ausgelesen werden (OneDrive/Provider/Dateizugriff). Datei lokal verfuegbar machen und erneut versuchen."
    }
    if ($msg -match "Unerwarteter Netzwerkfehler|Netzwerk") {
        return "Netzwerkpfad ist instabil oder kurzzeitig nicht erreichbar."
    }
    if ($msg -match "wird von einem anderen Prozess verwendet|Zugriff verweigert|access is denied") {
        return "Datei ist gesperrt oder Berechtigung fehlt."
    }
    if ($msg -match "Der Pfad.*nicht gefunden|cannot find path") {
        return "Pfad existiert nicht mehr oder wurde waehrend des Laufs verschoben."
    }
    return "Details im Exception-Text pruefen."
}

function Format-ErrorDetails {
    param(
        [string]$Code,
        [string]$Operation,
        [string]$Path,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $raw = if ($null -eq $ErrorRecord) { "Unbekannt" } else { $ErrorRecord.Exception.Message }
    $hint = Get-ErrorHint -ErrorRecord $ErrorRecord
    return "[$Code] Operation=$Operation | Path=$Path | Ursache=$raw | Hinweis=$hint"
}

function Acquire-RunLock {
    param([string]$LockPath)

    try {
        $script:RunLockHandle = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $lockContent = "pid=$PID`nstarted=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`npathA=$PathA`npathB=$PathB"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($lockContent)
        $script:RunLockHandle.SetLength(0)
        $script:RunLockHandle.Write($bytes, 0, $bytes.Length)
        $script:RunLockHandle.Flush()
        return $true
    }
    catch {
        Write-Log (Format-ErrorDetails -Code "E_LOCK_ACTIVE" -Operation "AcquireRunLock" -Path $LockPath -ErrorRecord $_) -Level ERROR
        return $false
    }
}

function Release-RunLock {
    param([string]$LockPath)

    if ($null -ne $script:RunLockHandle) {
        try { $script:RunLockHandle.Close() } catch {}
        try { $script:RunLockHandle.Dispose() } catch {}
        $script:RunLockHandle = $null
    }
    try { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue } catch {}
}

function Initialize-ProgressFile {
    try {
        $dir = Split-Path -Path $ProgressFile -Parent
        if (-not [string]::IsNullOrWhiteSpace($dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # Vor jedem Lauf leeren und neu befuellen
        Set-Content -LiteralPath $ProgressFile -Value @() -Encoding UTF8 -ErrorAction Stop
        $script:LastProgressPercent = -1
    }
    catch {
        Write-Log "Progress-Datei kann nicht initialisiert werden: $ProgressFile - $_" -Level WARN
    }
}

function Write-ProgressState {
    param(
        [double]$Percent,
        [string]$Phase = "",
        [switch]$Force
    )

    $p = [int][Math]::Floor($Percent)
    if ($p -lt 0)   { $p = 0 }
    if ($p -gt 100) { $p = 100 }

    if (-not $Force -and $p -le $script:LastProgressPercent) { return }

    $script:LastProgressPercent = $p
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $p% | $Phase"
    try {
        Add-Content -LiteralPath $ProgressFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Write-Log "Progress-Schreiben fehlgeschlagen: $ProgressFile - $_" -Level WARN
    }
}

function Update-ProgressRange {
    param(
        [int]$Current,
        [int]$Total,
        [double]$RangeStart,
        [double]$RangeEnd,
        [string]$Phase
    )

    if ($Total -le 0) {
        Write-ProgressState -Percent $RangeEnd -Phase $Phase
        return
    }

    $ratio = $Current / [double]$Total
    if ($ratio -lt 0) { $ratio = 0 }
    if ($ratio -gt 1) { $ratio = 1 }
    $pct = $RangeStart + (($RangeEnd - $RangeStart) * $ratio)
    Write-ProgressState -Percent $pct -Phase $Phase
}

function Get-HashSafe {
    param([string]$Path)
    try {
        return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash
    }
    catch {
        Write-Log (Format-ErrorDetails -Code "E_HASH" -Operation "GetFileHash" -Path $Path -ErrorRecord $_) -Level WARN
        return $null
    }
}

function Test-FileLocked {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
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
                Write-Log (Format-ErrorDetails -Code "E_RETRY" -Operation "$Description (Retry $i/$MaxRetries)" -Path "-" -ErrorRecord $_) -Level WARN
                Start-Sleep -Seconds $RetryDelaySeconds
            }
            else {
                Write-Log (Format-ErrorDetails -Code "E_ACTION_FAILED" -Operation "$Description (Final Retry)" -Path "-" -ErrorRecord $_) -Level ERROR
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
    if (Test-IsExcluded $FilePath) { return }

    $backupPath = Join-Path $BackupRoot "$TimeStamp\$RelativePath"
    $dir = Split-Path $backupPath
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Invoke-WithRetry -Description "Backup $RelativePath" -Action {
        Copy-Item -LiteralPath $FilePath -Destination $backupPath -Force -ErrorAction Stop
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

    Copy-Item -LiteralPath $FileA -Destination $conflictA -Force -ErrorAction Stop
    Copy-Item -LiteralPath $FileB -Destination $conflictB -Force -ErrorAction Stop

    Write-Log "CONFLICT: $RelativePath" -Level WARN
    $Stats.Conflicts++
}

function Test-IsExcluded {
    param([string]$FullPath)

    $leaf = Split-Path $FullPath -Leaf
    if ($ExcludeFileNames.Contains($leaf)) {
        return $true
    }

    foreach ($folder in $ExcludeFolders) {
        if ($FullPath.Contains("\$folder\") -or $FullPath.EndsWith("\$folder")) {
            return $true
        }
    }
    return $false
}

function Build-FileIndex {
    <#
        Scannt ein Verzeichnis einmalig und gibt eine Hashtable zurueck:
        Key = relativer Pfad (lowercase), Value = FileInfo-Objekt.
        Ausgeschlossene Ordner werden direkt uebersprungen.
    #>
    param([string]$Root)

    if (-not $Root.EndsWith('\')) { $Root += '\' }
    $index = @{}

    try {
        $files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop
    }
    catch {
        Write-Log "Kann Verzeichnis nicht lesen: $Root - $_" -Level ERROR
        return $index
    }

    foreach ($f in $files) {
        if (Test-IsExcluded $f.FullName) { continue }
        $rel = $f.FullName.Substring($Root.Length)
        $index[$rel.ToLower()] = $f
    }
    return $index
}

function Build-DirectoryIndex {
    <#
        Scannt ein Verzeichnis einmalig und gibt eine Hashtable zurueck:
        Key = relativer Verzeichnis-Pfad (lowercase), Value = relativer Pfad (Originalschreibweise).
        Damit werden auch leere Verzeichnisse synchronisiert.
    #>
    param([string]$Root)

    if (-not $Root.EndsWith('\')) { $Root += '\' }
    $index = @{}

    $trashRoot = Join-Path $Root "Papierkorb"

    try {
        $dirs = Get-ChildItem -LiteralPath $Root -Recurse -Directory -ErrorAction Stop
    }
    catch {
        Write-Log "Kann Verzeichnisse nicht lesen: $Root - $_" -Level ERROR
        return $index
    }

    foreach ($d in $dirs) {
        if ($d.FullName.StartsWith($trashRoot)) { continue }
        if (Test-IsExcluded $d.FullName) { continue }

        $rel = $d.FullName.Substring($Root.Length)
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $index[$rel.ToLower()] = $rel
    }

    return $index
}

# -- Papierkorb -------------------------------------------------

function Get-UnmarkedRelativePath {
    <#
        Entfernt genau ein fuehrendes "__" vom Dateinamen/Ordnernamen
        des letzten Pfadsegments.
    #>
    param([string]$RelativePath)

    $leaf = Split-Path -Path $RelativePath -Leaf
    if (-not $leaf.StartsWith('__')) { return $null }

    $unmarkedLeaf = $leaf.Substring(2)
    if ([string]::IsNullOrWhiteSpace($unmarkedLeaf)) { return $null }

    $parent = Split-Path -Path $RelativePath -Parent
    if ([string]::IsNullOrEmpty($parent) -or $parent -eq '.') {
        return $unmarkedLeaf
    }
    return (Join-Path $parent $unmarkedLeaf)
}

function Invoke-RemoteTrashFromMarkers {
    <#
        Erkennt "__"-Marker auf einer Seite und verschiebt die passende
        Datei/den passenden Ordner auf der Gegenseite in den Papierkorb.
        Der Name auf der Gegenseite wird dabei ebenfalls mit "__" markiert.
    #>
    param(
        [string]$MarkerRoot,
        [string]$OtherRoot,
        [hashtable]$MarkerIndex,
        [hashtable]$OtherIndex,
        [string]$Label = ""
    )

    if (-not $MarkerRoot.EndsWith('\')) { $MarkerRoot += '\' }
    if (-not $OtherRoot.EndsWith('\'))  { $OtherRoot  += '\' }

    $markerTrashRoot = Join-Path $MarkerRoot "Papierkorb"
    $otherTrashRoot  = Join-Path $OtherRoot "Papierkorb"
    $movedDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 1) Marker-Dateien aus dem Dateiindex auswerten
    foreach ($entry in $MarkerIndex.GetEnumerator()) {
        $markerFile = $entry.Value
        if (-not $markerFile.Name.StartsWith('__')) { continue }
        if ($markerFile.FullName.StartsWith($markerTrashRoot)) { continue }
        if (Test-IsExcluded $markerFile.FullName) { continue }

        $markerRel = $markerFile.FullName.Substring($MarkerRoot.Length)
        $unmarkedRel = Get-UnmarkedRelativePath -RelativePath $markerRel
        if (-not $unmarkedRel) { continue }

        $otherOriginal = Join-Path $OtherRoot $unmarkedRel
        if (-not (Test-Path -LiteralPath $otherOriginal -PathType Leaf)) { continue }

        if (Test-FileLocked $otherOriginal) {
            Write-Log "LOCKED TARGET (remote Papierkorb skipped): $unmarkedRel [$Label]" -Level WARN
            continue
        }

        $otherTrashPath = Join-Path $otherTrashRoot $markerRel
        $targetDir = Split-Path $otherTrashPath
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

        $ok = Invoke-WithRetry -Description "Remote Papierkorb Datei [$Label]: $unmarkedRel" -Action {
            Move-Item -LiteralPath $otherOriginal -Destination $otherTrashPath -Force -ErrorAction Stop
        }
        if ($ok) {
            Write-Log "REMOTE PAPIERKORB (Datei) [$Label]: $unmarkedRel -> Papierkorb/$markerRel"
            $OtherIndex.Remove($unmarkedRel.ToLower()) | Out-Null
            $Stats.Deleted++
        }
    }

    # 2) Marker-Ordner direkt aus Dateisystem lesen (auch leere Ordner)
    try {
        $markerDirs = Get-ChildItem -LiteralPath $MarkerRoot -Recurse -Directory -ErrorAction Stop |
                      Sort-Object { $_.FullName.Length }
    }
    catch {
        Write-Log "Kann Marker-Ordner nicht lesen: $MarkerRoot - $_" -Level WARN
        $markerDirs = @()
    }

    foreach ($dir in $markerDirs) {
        if (-not $dir.Name.StartsWith('__')) { continue }
        if ($dir.FullName.StartsWith($markerTrashRoot)) { continue }
        if (Test-IsExcluded $dir.FullName) { continue }

        $markerRel = $dir.FullName.Substring($MarkerRoot.Length)
        $unmarkedRel = Get-UnmarkedRelativePath -RelativePath $markerRel
        if (-not $unmarkedRel) { continue }

        $otherOriginalDir = Join-Path $OtherRoot $unmarkedRel
        if (-not (Test-Path -LiteralPath $otherOriginalDir -PathType Container)) { continue }

        # Wenn ein Parent-Ordner bereits verschoben wurde, Child ueberspringen
        $skip = $false
        foreach ($md in $movedDirs) {
            if ($otherOriginalDir.StartsWith($md + '\')) { $skip = $true; break }
        }
        if ($skip) { continue }

        $otherTrashPath = Join-Path $otherTrashRoot $markerRel
        $targetDir = Split-Path $otherTrashPath
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

        $ok = Invoke-WithRetry -Description "Remote Papierkorb Ordner [$Label]: $unmarkedRel" -Action {
            Move-Item -LiteralPath $otherOriginalDir -Destination $otherTrashPath -Force -ErrorAction Stop
        }
        if ($ok) {
            Write-Log "REMOTE PAPIERKORB (Ordner) [$Label]: $unmarkedRel -> Papierkorb/$markerRel"
            $movedDirs.Add($otherOriginalDir) | Out-Null

            $prefix = ($unmarkedRel.ToLower() + '\')
            $keys = @($OtherIndex.Keys)
            foreach ($k in $keys) {
                if ($k.StartsWith($prefix)) { $OtherIndex.Remove($k) | Out-Null }
            }
            $Stats.Deleted++
        }
    }
}

function Move-ToTrash {
    <#
        Verschiebt Ordner und Dateien mit __ am Anfang des Namens
        in den Unterordner "Papierkorb" innerhalb des Sync-Verzeichnisses.
        Ordner werden komplett (samt Inhalt) verschoben.
        Entfernt betroffene Keys aus dem FileIndex.
    #>
    param(
        [string]$SyncRoot,
        [hashtable]$FileIndex
    )

    if (-not $SyncRoot.EndsWith('\')) { $SyncRoot += '\' }

    $trashFolder  = Join-Path $SyncRoot "Papierkorb"
    $movedFolders = [System.Collections.Generic.List[string]]::new()

    # Phase 1: Ordner mit __ am Anfang komplett verschieben
    try {
        $dirs = Get-ChildItem -LiteralPath $SyncRoot -Recurse -Directory -ErrorAction Stop |
                Sort-Object { $_.FullName.Length }
    }
    catch {
        Write-Log "Kann Verzeichnisse nicht lesen: $SyncRoot - $_" -Level WARN
        $dirs = @()
    }

    foreach ($dir in $dirs) {
        if ($dir.FullName.StartsWith($trashFolder)) { continue }
        if (Test-IsExcluded $dir.FullName) { continue }

        $alreadyMoved = $false
        foreach ($mf in $movedFolders) {
            if ($dir.FullName.StartsWith($mf)) { $alreadyMoved = $true; break }
        }
        if ($alreadyMoved) { continue }

        if ($dir.Name.StartsWith('__')) {
            $relativePath = $dir.FullName.Substring($SyncRoot.Length)
            $trashPath    = Join-Path $trashFolder $relativePath
            $parentDir    = Split-Path $trashPath

            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null

            $ok = Invoke-WithRetry -Description "Papierkorb (Ordner): $relativePath" -Action {
                Move-Item -LiteralPath $dir.FullName -Destination $trashPath -Force -ErrorAction Stop
            }
            if ($ok) {
                Write-Log "PAPIERKORB (Ordner): $relativePath -> Papierkorb/$relativePath"
                $movedFolders.Add($dir.FullName + '\')
            }
        }
    }

    # Phase 2: Einzelne Dateien mit __ am Anfang verschieben
    $keysToRemove = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in $FileIndex.GetEnumerator()) {
        $file = $entry.Value

        if ($file.FullName.StartsWith($trashFolder)) { continue }

        # Dateien aus bereits verschobenen Ordnern aus Index entfernen
        $inMovedFolder = $false
        foreach ($mf in $movedFolders) {
            if ($file.FullName.StartsWith($mf)) { $inMovedFolder = $true; break }
        }
        if ($inMovedFolder) {
            $keysToRemove.Add($entry.Key)
            continue
        }

        if ($file.Name.StartsWith('__')) {
            if (Test-FileLocked $file.FullName) {
                Write-Log "LOCKED (Papierkorb skipped): $($file.Name)" -Level WARN
                continue
            }

            $relativePath = $file.FullName.Substring($SyncRoot.Length)
            $trashPath    = Join-Path $trashFolder $relativePath
            $targetDir    = Split-Path $trashPath

            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

            $ok = Invoke-WithRetry -Description "Papierkorb: $relativePath" -Action {
                Move-Item -LiteralPath $file.FullName -Destination $trashPath -Force -ErrorAction Stop
            }
            if ($ok) {
                Write-Log "PAPIERKORB: $relativePath -> Papierkorb/$relativePath"
                $keysToRemove.Add($entry.Key)
            }
        }
    }

    foreach ($k in $keysToRemove) { $FileIndex.Remove($k) }
}

# -- Kern-Sync -------------------------------------------------

function Sync-Folders {
    param(
        [string]$Source,
        [string]$Target,
        [string]$Label,
        [hashtable]$SourceIndex,
        [hashtable]$TargetIndex,
        [double]$ProgressStart = -1,
        [double]$ProgressEnd = -1
    )

    Write-Log "-- Sync $Label : $Source -> $Target --"

    if (-not $Source.EndsWith('\')) { $Source += '\' }
    if (-not $Target.EndsWith('\')) { $Target += '\' }

    $totalItems = $SourceIndex.Count
    $currentItem = 0

    foreach ($entry in $SourceIndex.GetEnumerator()) {
        $currentItem++
        if ($ProgressStart -ge 0 -and $ProgressEnd -ge 0) {
            Update-ProgressRange -Current $currentItem -Total $totalItems -RangeStart $ProgressStart -RangeEnd $ProgressEnd -Phase "Dateisync $Label"
        }

        $relKey  = $entry.Key
        $file    = $entry.Value
        $relativePath = $file.FullName.Substring($Source.Length)

        $targetFile = Join-Path $Target $relativePath

        if (-not $TargetIndex.ContainsKey($relKey)) {
            # -- Neue Datei -> kopieren --
            if (Test-FileLocked $file.FullName) {
                Write-Log "LOCKED (skipped): $relativePath" -Level WARN
                $Stats.Skipped++
                continue
            }

            $dir = Split-Path $targetFile
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            $ok = Invoke-WithRetry -Description "Copy $relativePath" -Action {
                Copy-Item -LiteralPath $file.FullName -Destination $targetFile -Force -ErrorAction Stop
            }
            if ($ok) {
                Write-Log "COPIED: $relativePath"
                $Stats.Copied++
            }
        }
        else {
            # -- Datei existiert auf beiden Seiten --
            $targetItem = $TargetIndex[$relKey]

            # Fast-Path nur noch bei exakt gleicher Zeit.
            # Bei "nahezu gleich" (z.B. gleiche Sekunde) kann Inhalt trotzdem abweichen.
            if ($file.Length -eq $targetItem.Length -and
                $file.LastWriteTimeUtc -eq $targetItem.LastWriteTimeUtc) {
                $hashSourceFast = Get-HashSafe $file.FullName
                $hashTargetFast = Get-HashSafe $targetFile
                if ($null -ne $hashSourceFast -and $hashSourceFast -eq $hashTargetFast) {
                    continue
                }
            }

            # Groesse oder Zeit unterschiedlich -> genauer pruefen
            if (Test-FileLocked $file.FullName) {
                Write-Log "LOCKED (skipped): $relativePath" -Level WARN
                $Stats.Skipped++
                continue
            }
            if (Test-FileLocked $targetFile) {
                Write-Log "LOCKED TARGET (skipped): $relativePath" -Level WARN
                $Stats.Skipped++
                continue
            }

            $hashSource = Get-HashSafe $file.FullName
            $hashTarget = Get-HashSafe $targetFile

            if ($null -eq $hashSource -or $null -eq $hashTarget) {
                Write-Log "HASH ERROR (skipped): $relativePath" -Level WARN
                $Stats.Skipped++
                continue
            }

            if ($hashSource -ne $hashTarget) {
                # Neuere Version gewinnt immer. Nur bei identischer Zeit bleibt es ein echter Konflikt.
                if ($file.LastWriteTime -gt $targetItem.LastWriteTime) {
                    Backup-File $targetFile $relativePath
                    $ok = Invoke-WithRetry -Description "Update $relativePath" -Action {
                        Copy-Item -LiteralPath $file.FullName -Destination $targetFile -Force -ErrorAction Stop
                    }
                    if ($ok) {
                        Write-Log "UPDATED (Source newer): $relativePath"
                        $Stats.Updated++
                    }
                }
                elseif ($targetItem.LastWriteTime -gt $file.LastWriteTime) {
                    # Target ist neuer -> wird im Gegenlauf (B->A bzw. A->B) uebernommen
                    continue
                }
                else {
                    Handle-Conflict $file.FullName $targetFile $relativePath
                }
            }
        }
    }
}

function Sync-Directories {
    <#
        Erstellt fehlende Verzeichnisse im Ziel (auch wenn sie leer sind).
    #>
    param(
        [string]$Source,
        [string]$Target,
        [string]$Label,
        [hashtable]$SourceDirIndex,
        [hashtable]$TargetDirIndex
    )

    Write-Log "-- Sync Verzeichnisse $Label : $Source -> $Target --"

    if (-not $Source.EndsWith('\')) { $Source += '\' }
    if (-not $Target.EndsWith('\')) { $Target += '\' }

    foreach ($entry in $SourceDirIndex.GetEnumerator()) {
        $relKey = $entry.Key
        $relativeDir = $entry.Value

        if ($TargetDirIndex.ContainsKey($relKey)) { continue }

        $targetDir = Join-Path $Target $relativeDir
        $ok = Invoke-WithRetry -Description "Create directory $relativeDir" -Action {
            New-Item -ItemType Directory -Path $targetDir -Force -ErrorAction Stop | Out-Null
        }
        if ($ok) {
            Write-Log "DIR CREATED ($Label): $relativeDir"
            $TargetDirIndex[$relKey] = $relativeDir
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
        $targetFiles = Get-ChildItem -LiteralPath $Target -Recurse -File -ErrorAction Stop
    }
    catch { return }

    foreach ($tf in $targetFiles) {
        if (Test-IsExcluded $tf.FullName) { continue }

        $relativePath = $tf.FullName.Substring($Target.Length)
        $sourceFile   = Join-Path $Source $relativePath

        if (-not (Test-Path -LiteralPath $sourceFile)) {
            $otherSide = if ($Target -eq $PathA) { $PathB } else { $PathA }
            $otherFile = Join-Path $otherSide $relativePath

            if (-not (Test-Path -LiteralPath $otherFile)) {
                Backup-File $tf.FullName $relativePath
                Remove-Item -LiteralPath $tf.FullName -Force -ErrorAction SilentlyContinue
                Write-Log "DELETED (Orphan): $relativePath"
                $Stats.Deleted++
            }
        }
    }
}

function Remove-OldBackups {
    <#
        Loescht Backup-Ordner, die aelter als $BackupRetentionDays Tage sind.
    #>
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return }

    Get-ChildItem -LiteralPath $BackupRoot -Directory | ForEach-Object {
        if ($_.CreationTime -lt (Get-Date).AddDays(-$BackupRetentionDays)) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "BACKUP CLEANUP: $($_.Name) removed (older than $BackupRetentionDays days)"
        }
    }

    if (-not (Test-Path -LiteralPath $ConflictRoot)) { return }

    Get-ChildItem -LiteralPath $ConflictRoot -Directory | ForEach-Object {
        if ($_.CreationTime -lt (Get-Date).AddDays(-$BackupRetentionDays)) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "CONFLICT CLEANUP: $($_.Name) removed"
        }
    }
}

# -- Validierung -----------------------------------------------

function Assert-Prerequisites {
    $ok = $true

    if (-not (Test-Path -LiteralPath $PathA)) {
        Write-Log "FATAL: Pfad A nicht erreichbar: $PathA" -Level ERROR
        $ok = $false
    }
    if (-not (Test-Path -LiteralPath $PathB)) {
        Write-Log "FATAL: Pfad B nicht erreichbar: $PathB" -Level ERROR
        $ok = $false
    }
    if (-not $ok) {
        Write-Log "Sync abgebrochen - Voraussetzungen nicht erfuellt." -Level ERROR
        exit 1
    }

    New-Item -ItemType Directory -Path $BackupRoot   -Force | Out-Null
    New-Item -ItemType Directory -Path $ConflictRoot  -Force | Out-Null
}

# -- Hauptablauf -----------------------------------------------

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$lockAcquired = $false
try {
    Assert-Prerequisites

    $lockAcquired = Acquire-RunLock -LockPath $RunLockFile
    if (-not $lockAcquired) {
        Write-Error "Sync bereits aktiv oder Lock-Datei nicht verfuegbar: $RunLockFile"
        exit 1
    }

    Initialize-ProgressFile
    Write-ProgressState -Percent 0 -Phase "Start" -Force

    Write-Log "===== SYNC START ($TimeStamp) ====="
    if ($FolderName) { Write-Log "Sync-Ordner: $FolderName" }
    Write-Log "PathA=$PathA | PathB=$PathB | Retries=$MaxRetries | Retention=${BackupRetentionDays}d"

    try {
        # Beide Seiten einmalig scannen und indexieren
        Write-Log "Scanne Verzeichnis A: $PathA"
        $indexA = Build-FileIndex -Root $PathA
        Write-Log "Index A: $($indexA.Count) Dateien"
        Write-ProgressState -Percent 10 -Phase "Scan A abgeschlossen"

        Write-Log "Scanne Verzeichnis B: $PathB"
        $indexB = Build-FileIndex -Root $PathB
        Write-Log "Index B: $($indexB.Count) Dateien"
        Write-ProgressState -Percent 20 -Phase "Scan B abgeschlossen"

        # "__"-Marker bidirektional auf Gegenseite anwenden (bevor lokale Marker entsorgt werden)
        Invoke-RemoteTrashFromMarkers -MarkerRoot $PathA -OtherRoot $PathB -MarkerIndex $indexA -OtherIndex $indexB -Label "A->B"
        Invoke-RemoteTrashFromMarkers -MarkerRoot $PathB -OtherRoot $PathA -MarkerIndex $indexB -OtherIndex $indexA -Label "B->A"
        Write-ProgressState -Percent 30 -Phase "Markerabgleich abgeschlossen"

        # Dateien mit __ im Namen in Papierkorb verschieben (entfernt Keys aus Index)
        Move-ToTrash -SyncRoot $PathA -FileIndex $indexA
        Move-ToTrash -SyncRoot $PathB -FileIndex $indexB
        Write-ProgressState -Percent 40 -Phase "Papierkorb-Phase abgeschlossen"

        # Verzeichnisse separat synchronisieren, damit auch leere Ordner uebertragen werden
        $dirIndexA = Build-DirectoryIndex -Root $PathA
        $dirIndexB = Build-DirectoryIndex -Root $PathB
        Sync-Directories -Source $PathA -Target $PathB -Label "A->B" -SourceDirIndex $dirIndexA -TargetDirIndex $dirIndexB
        Sync-Directories -Source $PathB -Target $PathA -Label "B->A" -SourceDirIndex $dirIndexB -TargetDirIndex $dirIndexA
        Write-ProgressState -Percent 50 -Phase "Verzeichnissync abgeschlossen"

        # Bidirektionaler Sync mit vorberechneten Indizes
        Sync-Folders -Source $PathA -Target $PathB -Label "A->B" -SourceIndex $indexA -TargetIndex $indexB -ProgressStart 50 -ProgressEnd 75
        Sync-Folders -Source $PathB -Target $PathA -Label "B->A" -SourceIndex $indexB -TargetIndex $indexA -ProgressStart 75 -ProgressEnd 98

        # Optional: verwaiste Dateien aufraeumen (auskommentiert - bewusst aktivieren!)
        # Remove-OrphanedFiles -Source $PathA -Target $PathB
        # Remove-OrphanedFiles -Source $PathB -Target $PathA

        # Alte Backups aufraeumen
        Remove-OldBackups
        Write-ProgressState -Percent 100 -Phase "Fertig"
    }
    catch {
        Write-Log (Format-ErrorDetails -Code "E_UNHANDLED" -Operation "MainSyncLoop" -Path "-" -ErrorRecord $_) -Level ERROR
        Write-ProgressState -Percent $script:LastProgressPercent -Phase "Fehler aufgetreten" -Force
        $Stats.Errors++
    }
}
finally {
    if ($lockAcquired) {
        Release-RunLock -LockPath $RunLockFile
    }
}

$stopwatch.Stop()
$duration = $stopwatch.Elapsed.ToString("hh\:mm\:ss\.fff")

Write-Log ("STATISTIK: Copied={0} | Updated={1} | Conflicts={2} | Skipped={3} | Deleted={4} | Errors={5}" -f `
    $Stats.Copied, $Stats.Updated, $Stats.Conflicts, $Stats.Skipped, $Stats.Deleted, $Stats.Errors)
Write-Log "===== SYNC END (Dauer: $duration) ====="

# Exit-Code: 0 = OK, 1 = mit Fehlern
if ($Stats.Errors -gt 0) { exit 1 } else { exit 0 }
