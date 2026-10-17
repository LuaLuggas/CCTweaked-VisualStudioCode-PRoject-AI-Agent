# Bunker-Netzwerk (Rednet & Kanäle)

Diese Datei dokumentiert alle Funk-Protokolle, Kanäle, festen Computer-IDs und Nachrichtenformate im Bunker-System.
**Wichtig:** Änderungen an Protokollnamen oder Nachrichten-Tabellen müssen immer gleichzeitig im `MasterComputer` und in den betroffenen Geräten angepasst und hier eingetragen werden.

---

## 1. Feste Computer-IDs & Kanäle

| ID / Kanal | Rolle / Zweck | Beschreibung |
| :--- | :--- | :--- |
| **ID `24`** | `MASTER_ID` (`MasterComputer`) | Zentrale Steuereinheit (Bunker Master). Empfängt alle Log-Berichte (`log_report`), verwaltet die Geräteliste, synchronisiert Einstellungen und verteilt Remote-Updates. |
| **Kanal `65534`** | `CHANNEL_GPS` (`GPSHost`) | Standard-Modem-Kanal von CC:Tweaked für `gps.locate()`-Pings (`"PING"` $\rightarrow$ `{x, y, z}`). |

---

## 2. Rednet-Protokolle im Überblick

| Protokollname | Verwendet von | Zweck |
| :--- | :--- | :--- |
| `notaus` | `EmergencyTerminal`, `Tuersensor`, `TextAnzeige`, `MasterComputer` | Globaler **Emergency / Not-Aus** Status (`EMERGENCY_ON` / `EMERGENCY_OFF`). Öffnet Türen dauerhaft (Fluchtweg) und schaltet Monitore in den roten Warnmodus. |
| `lockdown` | `EmergencyTerminal`, `Tuersensor`, `TextAnzeige` | Globaler **Lockdown / Verriegelungs** Status (`LOCKDOWN_ON` / `LOCKDOWN_OFF`). Verriegelt alle Türen/Schleusen komplett und schaltet Monitore in den Lockdown-Warnmodus. |
| `notaus_update` | `MasterComputer` $\leftrightarrow$ `EmergencyTerminal` | Remote-Updates, Status-Abfragen und `log_report` für Not-Aus-Terminals. |
| `doors_update` | `MasterComputer` $\leftrightarrow$ `Tuersensor` | Remote-Updates und `log_report` für Türsensoren. |
| `doors_config` | `MasterComputer` $\leftrightarrow$ `Tuersensor` | Konfigurations-Befehle (z. B. Sensor-Reichweite `set_range`) und Status-Pings für Türsensoren. |
| `signs_update` | `MasterComputer` $\leftrightarrow$ `TextAnzeige` (sowie Legacy `GPSHost`) | Remote-Updates, Status-Pings und `log_report` für Textanzeigen/Wegweiser. |
| `signs_config` | `MasterComputer` $\leftrightarrow$ `TextAnzeige` | Zentrale Synchronisation der Alarm-Blinkgeschwindigkeit (`set_blink` / `request_blink_sync`) und Status-Pings. |
| `gps_update` | `MasterComputer` $\leftrightarrow$ `GPSHost` | Remote-Updates, Relocate-Befehle, Status-Pings und `log_report` für GPS-Hosts. |
| `gps_config` | `MasterComputer` $\leftrightarrow$ `GPSHost` | Remote-Relocate (`relocate`) und Status-Pings für GPS-Hosts. |

---

## 3. Nachrichtenformate im Detail

### 3.1 Globale Alarme (`notaus` & `lockdown`)

| Protokoll | Sender $\rightarrow$ Empfänger | Nachricht (String) | Wirkung |
| :--- | :--- | :--- | :--- |
| `notaus` | Broadcast | `"EMERGENCY_ON"` | Aktiviert Not-Aus: Türsensoren schalten Redstone dauerhaft **AN** (Türen offen), Textanzeigen blinken rot (`EMERGENCY`), Terminals zeigen `EMERGENCY`. |
| `notaus` | Broadcast | `"EMERGENCY_OFF"` | Beendet Not-Aus: Rückkehr in den Normalbetrieb. |
| `notaus` | Broadcast $\rightarrow$ `EmergencyTerminal` | `"STATUS_REQUEST"` | Fragt beim Start eines Geräts den aktuellen Not-Aus-Status ab. `EmergencyTerminal` antwortet direkt an den Sender mit `"EMERGENCY_ON"` oder `"EMERGENCY_OFF"`. |
| `lockdown` | Broadcast | `"LOCKDOWN_ON"` | Aktiviert Lockdown: Türsensoren schalten Redstone dauerhaft **AUS** (Türen verriegelt), Textanzeigen blinken rot (`LOCKDOWN`), Terminals zeigen `VERRIEGELT`. |
| `lockdown` | Broadcast | `"LOCKDOWN_OFF"` | Beendet Lockdown: Rückkehr in den Normalbetrieb. |
| `lockdown` | Broadcast $\rightarrow$ `EmergencyTerminal` | `"STATUS_REQUEST"` | Fragt beim Start eines Geräts den aktuellen Lockdown-Status ab. `EmergencyTerminal` antwortet direkt an den Sender mit `"LOCKDOWN_ON"` oder `"LOCKDOWN_OFF"`. |

---

### 3.2 Geräte-Reporting an den Master (`*_update` / `*_config`)

Alle Geräte melden ihren Status, Updates und Positionsdaten mit folgender Tabelle an `MASTER_ID = 24`:

```lua
{
    action  = "log_report",
    success = true,                  -- boolean: true = [OK] (grün), false = [FEHL] (rot)
    details = "Online (Range: 5)",   -- string: Details für das Konsolen-Log im Master
    pos     = "100, 64, -200",       -- string: GPS-Koordinaten ("X, Y, Z" oder "GPS n.verf.")
    label   = "Tuer 12",             -- string: Computer-Label oder Fallback-Name
    preview = "Wegweiser",           -- string (optional): Vorschautext für Geräteliste (bei TextAnzeige 1. Zeile, bei GPSHost "X:.. Y:.. Z:..")
    devType = "sign"                 -- string (optional): "terminal" | "door" | "sign" | "gps"
}
```

**Geräte-Ping vom Master (`REF`-Button in der Geräteliste):**
- Master sendet `"STATUS_REQUEST"` per Broadcast auf `notaus`, `notaus_update`, `doors_config`, `signs_config`, `signs_update`, `gps_config`, `gps_update`.
- Alle aktiven Geräte antworten daraufhin mit einem `log_report` (bzw. Status-String).

---

### 3.3 Konfigurations-Befehle (`doors_config`, `signs_config`, `gps_config`)

| Protokoll | Richtung | Nachrichten-Tabelle | Beschreibung |
| :--- | :--- | :--- | :--- |
| `doors_config` | Master $\rightarrow$ Broadcast | `{ action = "set_range", range = 5 }` | Setzt die Erkennungs-Reichweite (1–30 Blöcke) aller Türsensoren und speichert sie lokal. |
| `signs_config` | `TextAnzeige` $\rightarrow$ Master (`24`) | `{ action = "request_blink_sync" }` | Fragt beim Start oder beim Aktivieren von `[x] Sync` den zentralen Blink-Takt vom Master ab. |
| `signs_config` | Master $\rightarrow$ Broadcast / Einzel-ID | `{ action = "set_blink", splitBlink = false, blinkOn = 1.20, blinkOff = 1.20, isReply = false }` | Überträgt den zentralen Alarm-Blink-Takt an alle Textanzeigen, bei denen `[x] Sync` aktiviert ist. |
| `gps_config` & `gps_update` | Master $\rightarrow$ Broadcast | `{ action = "relocate" }` | Weist alle GPS-Hosts an, ihre lokal gespeicherten Koordinaten neu zu laden und das Modem neu zu initialisieren. |

---

### 3.4 Remote-Update-Protokoll über GitHub (`notaus_update`, `doors_update`, `signs_update`, `gps_update`)

| Schritt | Richtung | Nachrichten-Tabelle | Beschreibung |
| :--- | :--- | :--- | :--- |
| **1. Befehl** | Master (`24`) $\rightarrow$ Broadcast | `{ action = "update" }` | Startet das Selbst-Update über die feste GitHub-Raw-URL auf allen Geräten der gewählten Kategorie. |
| **2. Quittung** | Gerät $\rightarrow$ Master (`24`) | `{ action = "ping_ack" }` | Sofortige Empfangsbestätigung vor Beginn des GitHub-Downloads. |
| **3. Ergebnis** | Gerät $\rightarrow$ Master (`24`) | `{ action = "log_report", success = true/false, details = "..." }` | Meldet Erfolg (vor `os.reboot()`) oder den genauen Fehlergrund (z. B. `"Syntaxfehler im Code"`, `"Download fehlgeschlagen"`). |
