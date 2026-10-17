# Bunker-Projekt: CC:Tweaked & Advanced Peripherals (ATM10)

## 1. Projekt-Kontext & Szenario
- **Umgebung:** Gehosteter Multiplayer-Server (G-Portal), Minecraft Java **1.21.1**, Modpack **All The Mods 10 (ATM10)** über CurseForge.
- **Szenario & Lore:** Post-apokalyptischer Weltuntergangs-Bunker nach einer Biohazard-Katastrophe (unbewohnbare Oberfläche). Die Programme verbinden **praktische Basis-Steuerung** (AE2, Mekanism, Mystical Agriculture Farmen, Schleusen, Sensoren) mit **immersiven Roleplay- & Design-Elementen** (Emergency/Not-Aus, Lockdown/Verriegelung, Wegweiser/Textanzeigen, Status-Terminals).
- **Zielgruppe:** Der Nutzer ist Hobbyspieler und kein hauptberuflicher Programmierer. Alle Erklärungen erfolgen auf **Deutsch**, verständlich, präzise und ohne unnötigen Fachjargon.
- **Repository:** `https://github.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent` (Branch: `main`, Raw-Basis-URL: `https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/`).

---

## 2. Ordner- & Dateistruktur
- **`programme/<Rolle>/startup.lua`**: Jede Computer-Rolle besitzt eine **einzige, in sich geschlossene `startup.lua`** (All-in-One-Prinzip). Das garantiert maximale Zuverlässigkeit bei Remote-Updates über den MasterComputer, beim `loadfile()`-Syntaxcheck und beim automatischen Backup (`startup.backup`).
  - Bestehende Rollen (Vorbild-Skripte):
    - `programme/MasterComputer/startup.lua` (Zentrale Steuerung & Verwaltung, `MASTER_ID = 24`)
    - `programme/EmergencyTerminal/startup.lua` (Touch-Monitor-Panel für Alarm & Lockdown)
    - `programme/Tuersensor/startup.lua` (Player-Detector-Steuerung für Türen/Schleusen)
    - `programme/TextAnzeige/startup.lua` (Mehrzeilige Wegweiser- & Alarm-Monitore mit Live-Editor)
    - `programme/GPSHost/startup.lua` (GPS-Satelliten-Terminal mit Remote-Relocate)
- **`roles/<Rolle>.txt`**: Rollen-Definitionen für den Erst-Installer (`update.lua`).
- **`docs/netzwerk.md`**: Verbindliche Referenz für alle Rednet-Protokolle, Computer-IDs und Nachrichten-Tabellen.
- **`docs/peripherals.md`**: Verbindliche Referenz für angeschlossene Peripherals, Seiten und bestätigte Methoden in ATM10.
- **`docs/changelog.md`**: Kurzes Protokoll aller durchgeführten Änderungen.

---

## 3. Verbindlicher Code- & Architektur-Standard (Aus den Vorbild-Skripten)

### 3.1 Lua 5.1 / CC:Tweaked Grundlagen
- **Sprachumfang:** Nur Lua 5.1/5.2 Features von CC:Tweaked nutzen (`bit32` statt Bit-Operatoren, kein `//`, kein `<const>`).
- **60-Upvalue-Limit beachten:** Lua 5.1 erlaubt maximal 60 lokale Variablen (Upvalues) pro Funktion. Bei umfangreichen Skripten (wie `TextAnzeige` oder komplexen Steuerungen) **müssen** Konstanten in `local CFG = { ... }`, Zustände in `local state = { ... }` und UI-Klickbereiche in `local hitboxes = { ... }` (bzw. `currentButtons = {}`) gebündelt werden.
- **Keine Umlaute im Ingame-Text:** Alle Texte, die auf Computer-Terminals oder Monitoren ausgegeben werden, schreiben Umlaute konsequent als `ae`, `oe`, `ue`, `ss` (z. B. `ZURUECK`, `TUERSENSOR`, `GROESSE`, `GEAENDERT`), um Darstellungsfehler in CC:Tweaked zu vermeiden. In Lua-Kommentaren sind Umlaute oder `ae/oe/ue` erlaubt (Kommentare immer auf Deutsch).
- **Kein "Too long without yielding":** Jede Schleife benötigt `os.pullEvent()` oder `sleep()`.

### 3.2 Event-Loop, Timer & GPS-Caching
- **Dirty-Flag Rendering (`dirty = true`):** Die Terminal-UI wird nicht blind bei jedem Event neu gezeichnet, sondern über ein `dirty`-Flag gesteuert (`if dirty then draw(); dirty = false end`). Das verhindert Flackern und schont den G-Portal-Server.
- **GPS-Abfragen niemals ungecacht während laufender Timer:** `gps.locate()` ruft intern `os.pullEvent()` auf und **verschluckt dabei alle ablaufenden Timer-Events** (wodurch Blink- oder Laufschrift-Timer einfrieren!).
  - **Regel:** Position beim Programmstart (oder vor dem Starten von Animations-Timern) einmalig per `refreshGpsCache()` abfragen und in `cachedPos` speichern. `sendReport()` nutzt im laufenden Betrieb diesen Cache.
- **Timer-Verwaltung:** Ein periodischer `tickTimer = os.startTimer(0.5)` räumt abgelaufene Status-/Debug-Meldungen (`expires <= now()`) auf und setzt bei Bedarf `dirty = true`.
- **Fehlerschutz-Wrapper am Skript-Ende:**
  - Jedes Programm läuft in einer geschützten Hauptschleife (`while true do local ok, err = pcall(main) ...`).
  - Bei `Terminated` (Strg+T) wird das Terminal sauber zurückgesetzt (`term.setCursorBlink(false)`, schwarzer Hintergrund, weiße Schrift, `term.clear()`) und das Programm ordentlich beendet.
  - Andere Laufzeitfehler werden geloggt/angezeigt und das Programm startet nach `sleep(2..5)` automatisch neu.

### 3.3 Bunker UI/UX-Styleguide
Alle Benutzeroberflächen im Bunker folgen einem einheitlichen visuellen Stil:
- **Hintergrund:** Grundsätzlich `colors.black`.
- **Kopfzeile (Header):**
  - Titel im Format `--- TITEL ---` in einer zur Rolle passenden Akzentfarbe (`colors.cyan`, `colors.red`, `colors.orange`, `colors.yellow`, `colors.lime`, `colors.green`).
  - Computer-ID immer **oben rechts** in `colors.lightGray` im Format `ID:<nummer>` (z. B. `ID:24`).
- **Buttons & Eingabefelder:**
  - Standard-Buttons: Hintergrund `colors.gray`, Text `colors.white` (zentriert mit Leerzeichen-Padding).
  - Zurück-Buttons: Hintergrund `colors.lightGray` oder `colors.gray`.
  - Text-/Zahlen-Eingabefelder: Inaktiv `colors.gray` mit `colors.white`; aktiv/fokussiert `colors.lightGray` mit `colors.black` und aktivem `term.setCursorBlink(true)`.
  - **Dirty-State (Ungespeicherte Änderungen):** Sobald ein Wert im UI verändert, aber noch nicht gespeichert/gesendet wurde (`hasPendingChanges()`), wechselt der Speichern-/Action-Button auf **`colors.orange` (Hintergrund) mit `colors.black` (Text)**.
  - **Klick-Feedback:** Beim Klicken auf Aktions-Buttons blitzt der Button kurz für `0.15s` in `colors.orange` mit schwarzer Schrift auf, bevor die Aktion ausgeführt wird.
- **Temporäre Status-/Debug-Zeilen:**
  - Werden am unteren Bildschirmrand in `colors.gray` eingeblendet und verschwinden nach `LOG_TTL` (4–6 Sekunden) automatisch.
- **Externe Monitore:**
  - Nutzen bei Alarm/Lockdown knallroten Hintergrund (`0xFF0000` via `setPaletteColor`, falls verfügbar, und `colors.red`) mit weißer, automatisch optimal skalierter und zentrierter Schrift (`EMERGENCY` / `LOCKDOWN`).
  - Monitor-Zugriffe immer in `pcall(...)` kapseln und auf `monitor_resize`, `peripheral` und `peripheral_detach` reagieren.

### 3.4 Remote-Update & Backup-Mechanismus (GitHub & MasterComputer)
Jedes Slave-Gerät unterstützt Over-The-Air-Updates (ausgelöst vom `MasterComputer`, ID 24) sowie ein sicheres Installationsverfahren:
1. **Empfang:** Lauscht auf sein `UPDATE_PROTOCOL` (nur wenn `senderId == MASTER_ID` und `message.action == "update"`). Sendet sofort `{ action = "ping_ack" }` zurück.
2. **Download:** Lädt den neuen Code direkt von der festen GitHub-Raw-URL der Rolle per `http.get` mit Cache-Buster (`?cb=` .. `os.epoch("utc")`) herunter und schließt das Handle mit `response.close()`.
3. **Validierung:**
   - Prüft, ob die Datei nicht leer ist.
   - Prüft, dass keine HTML-Fehlerseite (`<!DOCTYPE` oder `<html`) geliefert wurde.
   - Schreibt den Inhalt in `startup.update_tmp` und prüft die Lua-Syntax mit `local compiled, err = loadfile("startup.update_tmp")`. Bei Syntaxfehlern wird abgebrochen, die Temp-Datei gelöscht und `sendReport(false, ...)` an den Master geschickt!
4. **Backup & Installation (Ingame):**
   - Kopiert die bestehende `startup.lua` nach `startup.backup`.
   - Schreibt den geprüften Code nach `startup.lua` (und entfernt eine eventuelle endungslose Datei `startup`, damit es keine Konflikte gibt).
5. **Abschluss:** Sendet `sendReport(true, ...)` an den Master, wartet `sleep(2)` und führt `os.reboot()` aus.

### 3.5 Mod-Peripherals (ATM10: Mekanism, AE2, Advanced Peripherals, Mystical Agriculture)
- **Niemals Methodennamen raten!** Verwende ausschließlich Methoden, die in `docs/peripherals.md` dokumentiert oder vom Nutzer im Spiel bestätigt wurden.
- Wenn für ein neues System (z. B. Mekanism Reaktor/Induction Matrix, AE2 `meBridge`, Advanced Peripherals `environmentDetector` / `energyDetector` / `chatBox` / `redstoneIntegrator`, Mystical Agriculture Farm) die exakten Methodennamen der ATM10-Version noch nicht in `docs/peripherals.md` stehen:
  - Erfinde keine Methoden, sondern gib dem Nutzer einen kurzen Ingame-Befehl oder ein kleines Analyse-Skript, das `peripheral.getMethods(name)` ausliest.
- Kapsle alle Aufrufe an externe Mod-Blöcke in `pcall(...)`, damit das Skript niemals abstürzt, wenn ein Block abgebaut wird, Energie verliert oder der Chunk entladen wird.

---

## 4. Arbeitsweise des Agenten (Verbindlicher Workflow)

### 4.1 Vor jeder Änderung (Planung, Rückfragen & Backup-Pflicht!)
1. **Lesen:** Lies zuerst die betroffenen Skripte in `programme/` sowie `docs/netzwerk.md` und `docs/peripherals.md`.
2. **NIEMALS auf gut Glück probieren:** Wenn bei einem Prompt, einer Funktion, einem Layout oder einer Logik auch nur die kleinste Unsicherheit besteht, **immer erst nachfragen** (gerne über das Frage-Tool), statt Annahmen zu treffen oder auf gut Glück Code zu ändern!
3. **Backup-Abfrage vor JEDER Skript-Änderung (PFLICHT):**
   - Frage den Nutzer **vor jeder Änderung an bestehenden Skripten**, ob vorab ein Projekt-Backup des aktuellen funktionierenden Skripts angelegt bzw. das letzte Backup überschrieben werden soll!
   - Erst nach der Antwort des Nutzers (und ggf. dem Speichern des Backups) wird die eigentliche Code-Änderung durchgeführt.
4. **Kurzer Plan:** Schlage bei neuen Features oder größeren Umbauten einen kurzen, klaren Plan vor (welche Dateien betroffen sind, wie die UI/Logik aussieht, mögliche Risiken) und warte auf das OK des Nutzers.

### 4.2 Beim Programmieren
- **Bestehendes schützen:** Ändere an funktionierenden Skripten nur genau das, was für die Aufgabe nötig ist. Entferne niemals ungefragt bestehende Features, Sicherheitsprüfungen oder UI-Elemente.
- **Abschnitts-Kommentare beibehalten:** Nutze die etablierte Struktur mit klaren deutschen Kommentarblöcken (`-- ==================================`).

### 4.3 Nach jeder Änderung
1. **Kurze Zusammenfassung:** Erkläre in **höchstens 5 Zeilen**, was geändert wurde und warum.
2. **Was ist im Spiel zu tun?** Sage kurz, wie das Update ins Spiel kommt (z. B. in VS Code auf GitHub pushen $\rightarrow$ am MasterComputer Update auslösen).
3. **2–3 konkrete Testschritte:** Beschreibe kurz, was im Spiel getestet werden soll und welches Ergebnis zu sehen sein muss.
4. **Dokumentation pflegen:**
   - Trage die Änderung in `docs/changelog.md` ein.
   - Aktualisiere `docs/netzwerk.md`, falls neue Rednet-Protokolle oder Nachrichtenfelder hinzugekommen sind.
   - Aktualisiere `docs/peripherals.md`, falls neue Peripherals oder Methoden genutzt werden.
   - Lege bei einer komplett neuen Computer-Rolle auch die passende Datei in `roles/<Rolle>.txt` an.
