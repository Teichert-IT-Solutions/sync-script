# Bidirektionaler Sync für Netzlaufwerke

Dieses PowerShell-Script synchronisiert ein **bestimmtes Verzeichnis** zwischen zwei Netzlaufwerken in **beide Richtungen**.  
Neuere Dateien überschreiben ältere. Bei Konflikten werden beide Versionen gesichert.

---

## Voraussetzungen

- **Windows** mit **PowerShell 5.1** oder höher (ist auf Windows 10/11 vorinstalliert)
- Beide Netzlaufwerke müssen als Laufwerksbuchstaben verbunden sein (z. B. `Z:\` und `Y:\`)
- Schreibrechte auf beiden Laufwerken

### PowerShell-Ausführungsrichtlinie prüfen

Falls das Script nicht startet, einmalig in einer **Admin-PowerShell** ausführen:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

---

## Zwei Varianten

### Variante 1: Gleicher Ordnername auf beiden Laufwerken

Der Ordner heißt auf beiden Laufwerken gleich → nur `-FolderName` angeben:

```powershell
.\sync.ps1 -FolderName "Projekte"
```

→ Synchronisiert `Z:\Projekte` ↔ `Y:\Projekte`

Falls die Laufwerke nicht `Z:\` und `Y:\` heißen:

```powershell
.\sync.ps1 -FolderName "Projekte" -DriveA "X:\" -DriveB "W:\"
```

→ Synchronisiert `X:\Projekte` ↔ `W:\Projekte`

---

### Variante 2: Unterschiedliche Pfade auf den Laufwerken

Die Ordner haben **verschiedene Pfade** → `-PathA` und `-PathB` direkt angeben:

```powershell
.\sync.ps1 -PathA "Z:\Abteilung\Daten" -PathB "Y:\Backup\Projekte"
```

→ Synchronisiert `Z:\Abteilung\Daten` ↔ `Y:\Backup\Projekte`

> Bei Variante 2 werden `-DriveA`, `-DriveB` und `-FolderName` ignoriert.

---

## Alle Parameter

| Parameter | Pflicht? | Was es tut | Standardwert |
|---|---|---|---|
| **`-FolderName`** | Variante 1 | Ordnername auf beiden Laufwerken | – |
| `-DriveA` | nein | Erstes Laufwerk (nur mit `-FolderName`) | `Z:\` |
| `-DriveB` | nein | Zweites Laufwerk (nur mit `-FolderName`) | `Y:\` |
| **`-PathA`** | Variante 2 | Kompletter Pfad Seite A | – |
| **`-PathB`** | Variante 2 | Kompletter Pfad Seite B | – |
| `-BackupRoot` | nein | Wo Backups gespeichert werden | `Z:\_SyncBackup` |
| `-ConflictRoot` | nein | Wo Konflikt-Dateien gespeichert werden | `Z:\_SyncConflicts` |
| `-LogFile` | nein | Pfad zur Log-Datei | `Z:\sync_log.txt` |
| `-MaxRetries` | nein | Wie oft bei Netzwerkfehler wiederholt wird | `3` |
| `-RetryDelaySeconds` | nein | Wartezeit zwischen Wiederholungen (Sekunden) | `2` |
| `-BackupRetentionDays` | nein | Nach wie vielen Tagen alte Backups gelöscht werden | `30` |
| `-ConflictTimeTolerance` | nein | Zeitfenster in Sekunden, ab dem ein Konflikt erkannt wird | `2` |

> **Wichtig:** Du musst entweder `-FolderName` ODER `-PathA` + `-PathB` angeben. Ohne eins davon bricht das Script mit einer Hilfe-Anzeige ab.

---

## Weitere Beispiele

### Backups nur 7 Tage behalten

```powershell
.\sync.ps1 -FolderName "Projekte" -BackupRetentionDays 7
```

### Mehr Wiederholungen bei instabilem Netzwerk

```powershell
.\sync.ps1 -FolderName "Projekte" -MaxRetries 5 -RetryDelaySeconds 5
```

### Alles auf einmal (Variante 1)

```powershell
.\sync.ps1 -FolderName "Firma" -DriveA "D:\" -DriveB "E:\" -BackupRoot "D:\_Backup" -ConflictRoot "D:\_Konflikte" -LogFile "D:\sync.log" -MaxRetries 5 -BackupRetentionDays 14
```

### Alles auf einmal (Variante 2)

```powershell
.\sync.ps1 -PathA "D:\Abteilung\Shared" -PathB "E:\NAS\Archiv" -BackupRoot "D:\_Backup" -LogFile "D:\sync.log" -BackupRetentionDays 14
```

---

## Automatisch per Aufgabenplanung (Taskplaner) ausführen

1. **Aufgabenplanung** öffnen (`taskschd.msc`)
2. **Aufgabe erstellen** → Name vergeben (z. B. „Netzwerk-Sync")
3. **Trigger** → z. B. „Täglich" um 12:00 Uhr
4. **Aktion** → „Programm starten":
   - **Programm:** `powershell.exe`
   - **Argumente (Variante 1):**
     `-NoProfile -ExecutionPolicy Bypass -File "C:\Pfad\zu\sync.ps1" -FolderName "Projekte"`
   - **Argumente (Variante 2):**
     `-NoProfile -ExecutionPolicy Bypass -File "C:\Pfad\zu\sync.ps1" -PathA "Z:\Abteilung\Daten" -PathB "Y:\Backup\Projekte"`
5. **Bedingungen** → ggf. „Nur starten, wenn Netzwerkverbindung verfügbar" aktivieren
6. Speichern

> **Tipp:** Ersetze `C:\Pfad\zu\sync.ps1` durch den echten Pfad zum Script.

---

## Was passiert bei einem Sync?

```
Pfad A                             Pfad B
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
│       ├── A_datei.txt           ← Version von Pfad A
│       └── B_datei.txt           ← Version von Pfad B
└── sync_log.txt                  ← Log-Datei
```

> `_SyncBackup` und `_SyncConflicts` werden **nicht** synchronisiert.

---

## Log-Datei lesen

Die Log-Datei (`sync_log.txt`) enthält alles, was passiert ist:

```
2026-02-18 14:30:01 [INFO] ===== SYNC START (2026-02-18_14-30-00) =====
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
| „Pfad nicht erreichbar" | Netzlaufwerk prüfen — ist es verbunden? Existiert der Ordner? |
| Rote Fehlermeldung beim Start | Du musst entweder `-FolderName` oder `-PathA` + `-PathB` angeben |
| Dateien werden übersprungen | Datei ist offen (z. B. in Excel) → schließen und erneut starten |
| Zu viele Konflikte | `-ConflictTimeTolerance` erhöhen (z. B. auf `5`) |
| Backup-Ordner wird zu groß | `-BackupRetentionDays` runtersetzen (z. B. `7`) |
