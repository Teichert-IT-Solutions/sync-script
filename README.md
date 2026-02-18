# Bidirektionaler Sync für Netzlaufwerke

Dieses PowerShell-Script synchronisiert ein **bestimmtes Verzeichnis** zwischen zwei Netzlaufwerken in **beide Richtungen**.  
Das Verzeichnis muss auf beiden Laufwerken den gleichen Namen haben.  
Neuere Dateien überschreiben ältere. Bei Konflikten werden beide Versionen gesichert.

---

## Voraussetzungen

- **Windows** mit **PowerShell 5.1** oder höher (ist auf Windows 10/11 vorinstalliert)
- Beide Netzlaufwerke müssen als Laufwerksbuchstaben verbunden sein (z. B. `Z:\` und `Y:\`)
- Das zu synchronisierende Verzeichnis muss auf **beiden** Laufwerken existieren
- Schreibrechte auf beiden Laufwerken

### PowerShell-Ausführungsrichtlinie prüfen

Falls das Script nicht startet, einmalig in einer **Admin-PowerShell** ausführen:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## Schnellstart

Du hast `Z:\` und `Y:\` und willst den Ordner **Projekte** synchronisieren:

```powershell
.\sync.ps1 -FolderName "Projekte"
```

Das synchronisiert `Z:\Projekte` ↔ `Y:\Projekte`. Fertig.

> **`-FolderName` ist der einzige Pflichtparameter!** Alles andere hat Standardwerte.

---

## Parameter

| Parameter | Pflicht? | Was es tut | Standardwert |
|---|---|---|---|
| **`-FolderName`** | **JA** | Name des Ordners, der auf beiden Laufwerken synchronisiert wird | – |
| `-DriveA` | nein | Erstes Netzlaufwerk | `Z:\` |
| `-DriveB` | nein | Zweites Netzlaufwerk | `Y:\` |
| `-BackupRoot` | nein | Wo Backups gespeichert werden (vor dem Überschreiben) | `Z:\_SyncBackup` |
| `-ConflictRoot` | nein | Wo Konflikt-Dateien gespeichert werden | `Z:\_SyncConflicts` |
| `-LogFile` | nein | Pfad zur Log-Datei | `Z:\sync_log.txt` |
| `-MaxRetries` | nein | Wie oft bei Netzwerkfehler wiederholt wird | `3` |
| `-RetryDelaySeconds` | nein | Wartezeit zwischen Wiederholungen (Sekunden) | `2` |
| `-BackupRetentionDays` | nein | Nach wie vielen Tagen alte Backups gelöscht werden | `30` |
| `-ConflictTimeTolerance` | nein | Zeitfenster in Sekunden, ab dem ein Konflikt erkannt wird | `2` |

---

## Beispiele

### Ordner "Projekte" auf Standard-Laufwerken (Z:\ ↔ Y:\) synchronisieren

```powershell
.\sync.ps1 -FolderName "Projekte"
```

→ Synchronisiert `Z:\Projekte` ↔ `Y:\Projekte`

### Andere Laufwerke verwenden

```powershell
.\sync.ps1 -FolderName "Dokumente" -DriveA "X:\" -DriveB "W:\"
```

→ Synchronisiert `X:\Dokumente` ↔ `W:\Dokumente`

### Eigenen Backup-Ort und Log-Datei festlegen

```powershell
.\sync.ps1 -FolderName "Projekte" -BackupRoot "Z:\_MeinBackup" -LogFile "Z:\mein_log.txt"
```

### Backups nur 7 Tage behalten

```powershell
.\sync.ps1 -FolderName "Projekte" -BackupRetentionDays 7
```

### Mehr Wiederholungen bei instabilem Netzwerk

```powershell
.\sync.ps1 -FolderName "Projekte" -MaxRetries 5 -RetryDelaySeconds 5
```

### Alles auf einmal

```powershell
.\sync.ps1 -FolderName "Firma" -DriveA "D:\" -DriveB "E:\" -BackupRoot "D:\_Backup" -ConflictRoot "D:\_Konflikte" -LogFile "D:\sync.log" -MaxRetries 5 -RetryDelaySeconds 3 -BackupRetentionDays 14
```

→ Synchronisiert `D:\Firma` ↔ `E:\Firma`

---

## Automatisch per Aufgabenplanung (Taskplaner) ausführen

1. **Aufgabenplanung** öffnen (`taskschd.msc`)
2. **Aufgabe erstellen** → Name vergeben (z. B. „Netzwerk-Sync")
3. **Trigger** → z. B. „Täglich" um 12:00 Uhr
4. **Aktion** → „Programm starten":
   - **Programm:** `powershell.exe`
   - **Argumente:** `-NoProfile -ExecutionPolicy Bypass -File "C:\Pfad\zu\sync.ps1" -FolderName "Projekte"`
5. **Bedingungen** → ggf. „Nur starten, wenn Netzwerkverbindung verfügbar" aktivieren
6. Speichern

> **Tipp:** Ersetze `C:\Pfad\zu\sync.ps1` durch den echten Pfad zum Script.

---

## Was passiert bei einem Sync?

Beispiel: `-FolderName "Projekte"`, Laufwerke `Z:\` und `Y:\`

```
Z:\Projekte\                       Y:\Projekte\
├── datei1.txt (neuer)  →→→→→→→→  ├── datei1.txt (wird überschrieben)
├── datei2.txt (älter)  ←←←←←←←←  ├── datei2.txt (neuer, wird zurückkopiert)
├── datei3.txt          ≠≠≠≠≠≠≠≠  ├── datei3.txt (Konflikt → beide gesichert)
└── datei4.txt (neu)    →→→→→→→→  └── (wird kopiert)
```

- **Neuere Datei gewinnt** — die ältere wird vorher ins Backup gesichert
- **Gleich alt aber unterschiedlich** — Konflikt, beide Versionen werden in `_SyncConflicts` gesichert
- **Datei nur auf einer Seite** — wird zur anderen Seite kopiert
- **Gesperrte Dateien** — werden übersprungen (z. B. offene Excel-Dateien)

---

## Ordnerstruktur nach dem Sync

```
Z:\
├── Projekte\                     ← Dein synchronisierter Ordner
│   └── (deine Dateien)
├── _SyncBackup\                  ← Backups vor dem Überschreiben
│   └── 2026-02-18_14-30-00\
│       └── Unterordner\datei.txt
├── _SyncConflicts\               ← Konflikt-Versionen
│   └── 2026-02-18_14-30-00\
│       ├── A_datei.txt           ← Version von Z:\Projekte
│       └── B_datei.txt           ← Version von Y:\Projekte
└── sync_log.txt                  ← Log-Datei
```

> `_SyncBackup` und `_SyncConflicts` werden **nicht** zwischen den Laufwerken synchronisiert.

---

## Log-Datei lesen

Die Log-Datei (`sync_log.txt`) enthält alles, was passiert ist:

```
2026-02-18 14:30:01 [INFO] ===== SYNC START (2026-02-18_14-30-00) =====
2026-02-18 14:30:01 [INFO] Sync-Ordner: 'Projekte'
2026-02-18 14:30:01 [INFO] PathA=Z:\Projekte | PathB=Y:\Projekte | Retries=3 | Retention=30d
2026-02-18 14:30:01 [INFO] COPIED: Dokumente\Bericht.docx
2026-02-18 14:30:02 [INFO] UPDATED (Quelle neuer): Tabellen\Budget.xlsx
2026-02-18 14:30:02 [WARN] CONFLICT: Notizen\todo.txt
2026-02-18 14:30:03 [WARN] LOCKED (übersprungen): Daten\geöffnet.xlsx
2026-02-18 14:30:03 [INFO] STATISTIK: Kopiert=1 | Aktualisiert=1 | Konflikte=1 | Übersprungen=1 | Gelöscht=0 | Fehler=0
2026-02-18 14:30:03 [INFO] ===== SYNC END (Dauer: 00:00:02.451) =====
```

---

## Exit-Codes

| Code | Bedeutung |
|---|---|
| `0` | Alles OK, keine Fehler |
| `1` | Es gab Fehler (siehe Log-Datei) |

---

## Häufige Probleme

| Problem | Lösung |
|---|---|
| Script startet nicht | `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` ausführen |
| „Pfad nicht erreichbar" | Netzlaufwerk prüfen — ist es verbunden? Existiert der Ordner auf beiden Laufwerken? |
| „-FolderName fehlt" | Du musst `-FolderName "DeinOrdner"` angeben — das ist Pflicht! |
| Dateien werden übersprungen | Datei ist offen (z. B. in Excel) → schließen und erneut starten |
| Zu viele Konflikte | `-ConflictTimeTolerance` erhöhen (z. B. auf `5`) |
| Backup-Ordner wird zu groß | `-BackupRetentionDays` runtersetzen (z. B. `7`) |
