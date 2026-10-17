# Bunker-Projekt: CC:Tweaked & Advanced Peripherals (ATM10)

## 1. Projekt-Kontext & Szenario
- **Umgebung:** Gehosteter Multiplayer-Server (G-Portal), Minecraft Java **1.21.1**, Modpack **All The Mods 10 (ATM10)** über CurseForge.
- **Szenario & Lore:** Post-apokalyptischer Weltuntergangs-Bunker nach einer Biohazard-Katastrophe (unbewohnbare Oberfläche). Die Programme verbinden **praktische Basis-Steuerung** (AE2, Mekanism, Mystical Agriculture Farmen, Schleusen, Sensoren) mit **immersiven Roleplay- & Design-Elementen** (Emergency/Not-Aus, Lockdown/Verriegelung, Wegweiser/Textanzeigen, Lautsprecher/Sirenen, Status-Terminals).
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
    - `programme/Lautsprecher/startup.lua` (YouTube Audio-Player mit 4 Trigger-Modi & Emergency/Lockdown-Sirene)
- **`installer.lua`** & **`roles/<Rolle>.txt`**: Interaktiver Erst-Installer im Bunker-Design und Rollen-Definitionen.
- **`backups/<Rolle>/startup.lua`**: Lokale Projekt-Backups der funktionierenden Skripte vor Änderungen.
- **`docs/netzwerk.md`**: Verbindliche Referenz für alle Rednet-Protokolle, Computer-IDs und Nachrichten-Tabellen.
- **`docs/peripherals.md`**: Verbindliche Referenz für angeschlossene Peripherals, Seiten und bestätigte Methoden in ATM10.
- **`docs/changelog.md`**: Kurzes Protokoll aller durchgeführten Änderungen.
- **`.agents/skills/bunker-role-blueprint/SKILL.md`**: Blaupausen-Skill für neue Rollen, MasterComputer-Integration (7-Punkte-Checkliste) und ATM10-Peripheral-Analyse.

---

## 3. Verbindlicher Code- & Architektur-Standard

### 3.1 Lua 5.1 / CC:Tweaked Grundlagen & Anti-Crash-Regeln
- **Sprachumfang:** Nur Lua 5.1/5.2 Features von CC:Tweaked nutzen (`bit32` statt Bit-Operatoren, kein `//`, kein `<const>`).
- **STRIKTES 60-Upvalue-Limit:** Lua 5.1 erlaubt maximal 60 lokale Variablen (Upvalues) pro Funktion.
  - **Verbot neuer Einzel-Locals in großen Skripten:** Füge in bestehenden Skripten (`MasterComputer`, `TextAnzeige`, `Lautsprecher`) **niemals** neue einzelne `local`-Variablen auf Dateiebene hinzu! Lege neue Werte **immer** als Felder in den bestehenden Tabellen (`CFG`, `state`, `spkCfg`, `hitboxes`, `currentButtons`) an.
- **Defensives Programmieren gegen `nil`-Abstürze (PFLICHT):**
  - **Vor jedem Edit prüfen:** Lies vor dem Bearbeiten von UI- oder Event-Code immer zuerst die Tabellen-Deklaration am Dateianfang (z. B. `state` oder `spkCfg`), damit Feldnamen zu 100 % exakt übereinstimmen!
  - **`string.format` absichern:** Übergib niemals ungesicherte Tabellenfelder an `string.format`! Nutze immer Fallbacks: `string.format("%d%%", tonumber(state.val) or 0)` bzw. `tostring(state.text or "")`.
- **Keine Umlaute im Ingame-Text:** Alle Texte für Terminal- oder Monitor-Ausgaben schreiben Umlaute konsequent als `ae`, `oe`, `ue`, `ss` (z. B. `ZURUECK`, `TUERSENSOR`, `GROESSE`, `GEAENDERT`). In Lua-Kommentaren sind Umlaute erlaubt (Kommentare immer auf Deutsch).
- **Kein "Too long without yielding":** Jede Schleife benötigt `os.pullEvent()` oder `sleep()`.

### 3.2 Event-Loop, Timer & GPS-Caching
- **Dirty-Flag Rendering (`dirty = true`):** Die Terminal-UI wird über ein `dirty`-Flag gesteuert (`if dirty then draw(); dirty = false end`). Das verhindert Flackern und schont den Server.
- **GPS-Abfragen niemals ungecacht während laufender Timer:** `gps.locate()` ruft intern `os.pullEvent()` auf und **verschluckt dabei alle ablaufenden Timer-Events** (wodurch Blink-, Audio- oder Laufschrift-Timer einfrieren!).
  - **Regel:** Position beim Programmstart einmalig per `refreshGpsCache()` abfragen und in `cachedPos` speichern. `sendReport()` nutzt im laufenden Betrieb ausschließlich diesen Cache.
- **Timer-Verwaltung:** Ein periodischer `tickTimer = os.startTimer(0.5)` räumt abgelaufene Status-/Debug-Meldungen (`expires <= now()`) auf und setzt bei Bedarf `dirty = true`.
- **Fehlerschutz-Wrapper am Skript-Ende:**
  - Hauptschleife immer in `pcall(main)` kapseln.
  - Bei `Terminated` (Strg+T) Terminal sauber zurücksetzen (`term.setCursorBlink(false)`, schwarzer Hintergrund, weiße Schrift, `term.clear()`).

### 3.3 Bunker UI/UX-Styleguide & Bildschirm-Geometrie
- **WICHTIG – Feste Hardware-Zuordnung & Bildschirm-Auflösungen:**
  1. **`MasterComputer` (`ID 24`) ist IMMER ein Advanced Pocket Computer (`26 Spalten Breite × 20 Zeilen Höhe`):**
     - Nutzbare Breite mit Rand: **maximal 22–24 Zeichen** (Spalten `2..25`, Standard-Buttonbreite im Master: `math.min(22, w - 2)`).
     - Texte, Eingabe-Prompts und nebeneinanderliegende Buttons im `MasterComputer` dürfen **niemals breiter als 24 Zeichen** sein (keine Texte über Spalte 25 hinaus!).
     - Vertikal: Zeilen `1–2` Header, Zeilen `3–16` Buttons/Inhalt, Zeilen `17–20` Footer/Debug-Overlay.
  2. **Alle anderen Rollen (`EmergencyTerminal`, `Tuersensor`, `TextAnzeige`, `GPSHost`, `Lautsprecher`) sind stationäre Advanced Computer (`51 Spalten Breite × 19 Zeilen Höhe`):**
     - **Zeile 1–2:** Header (`--- TITEL ---` in Akzentfarbe) und `ID:<nr>` oben rechts in `colors.lightGray`.
     - **Zeile 3–16:** Bedienelemente & Menü-Buttons (maximal 6–7 gestapelte Buttons mit 2 Zeilen Abstand: z. B. Zeilen `4, 6, 8, 10, 12, 14, 16`).
     - **Zeile 17–19:** Reserviert für Status-Zeile / `drawDebugOverlay` am unteren Rand.
  3. **Externe Monitore (Monitor-Blöcke an der Wand):**
     - Dynamische Auflösung über `monitor.getSize()` abhängig von Block-Größe und `setTextScale(0.5 .. 5.0)`.
- **Farben & Interaktion:**
  - Hintergrund: `colors.black`.
  - Standard-Buttons: Hintergrund `colors.gray`, Text `colors.white` (zentriert mit Leerzeichen-Padding).
  - Zurück-Buttons: Hintergrund `colors.lightGray` oder `colors.gray`.
  - Eingabefelder: Inaktiv `colors.gray` mit `colors.white`; fokussiert `colors.lightGray` mit `colors.black` und `term.setCursorBlink(true)`. Unterstütze bei Text-/Link-Eingaben immer auch das `paste`-Event (`Strg+V`).
  - **Dirty-State (Ungespeicherte Änderungen):** Sobald ein Wert im UI verändert, aber noch nicht gespeichert/gesendet wurde (`hasPendingChanges()`), wechselt der Speichern-/Action-Button auf **`colors.orange` (Hintergrund) mit `colors.black` (Text)**.
  - **Klick-Feedback:** Beim Klicken auf Aktions-Buttons blitzt der Button kurz für `0.15s` in `colors.orange` mit schwarzer Schrift auf.
- **Externe Monitore:**
  - Nutzen bei Alarm/Lockdown knallroten Hintergrund (`0xFF0000` via `setPaletteColor` und `colors.red`) mit weißer, optimal skalierter und zentrierter Schrift (`EMERGENCY` / `LOCKDOWN`).
  - Monitor-Zugriffe immer in `pcall(...)` kapseln und auf `monitor_resize`, `peripheral` und `peripheral_detach` reagieren.

### 3.4 Remote-Update & Backup-Mechanismus (GitHub & MasterComputer)
Jedes Slave-Gerät unterstützt Over-The-Air-Updates (vom `MasterComputer`, ID 24):
1. **Empfang:** Lauscht auf sein `UPDATE_PROTOCOL` (`senderId == MASTER_ID` und `message.action == "update"`), sendet sofort `{ action = "ping_ack" }`.
2. **Download:** Lädt von der GitHub-Raw-URL der Rolle per `http.get(url .. "?cb=" .. os.epoch("utc"))` und schließt das Handle (`res.close()`).
3. **Validierung:** Prüft auf nicht-leer, schließt HTML-Fehlerseiten (`<!DOCTYPE` / `<html`) aus, schreibt in `startup.update_tmp` und prüft die Syntax via `loadfile("startup.update_tmp")`. Bei Fehler: Temp-Datei löschen & `sendReport(false, ...)` senden.
4. **Backup & Installation:** Kopiert `startup.lua` nach `startup.backup`, schreibt den neuen Code nach `startup.lua`, löscht ggf. eine endungslose Datei `startup`, sendet `sendReport(true, ...)`, wartet `sleep(2)` und führt `os.reboot()` aus.

### 3.5 Mod-Peripherals (ATM10: Mekanism, AE2, Advanced Peripherals, Mystical Agriculture)
- **Niemals Methodennamen raten!** Verwende ausschließlich Methoden, die in `docs/peripherals.md` als bestätigt dokumentiert sind.
- Wenn für einen neuen Block in ATM10 die Methoden noch nicht in `docs/peripherals.md` stehen: Gib dem Nutzer zuerst den kurzen Ingame-Befehl aus `docs/peripherals.md` zum Auslesen von `peripheral.getMethods(name)`.
- Kapsle alle Aufrufe an externe Mod-Blöcke in `pcall(...)`.

---

## 4. Arbeitsweise & Effizienz-Regeln (Speziell optimiert für schnelle Flash-Modelle)

### 4.1 Vor jeder Änderung (Planung, Rückfragen & Backup-Pflicht!)
1. **Gezielt lesen (Token sparen):** Lies zuerst `docs/netzwerk.md` und `docs/peripherals.md`. Lies bei großen Skripten (>400 Zeilen) gezielt die relevanten Zeilenbereiche (`StartLine`/`EndLine`) statt mehrfach die gesamte Datei.
2. **Skill aktivieren bei neuen Rollen / Master-Integration:** Lies `.agents/skills/bunker-role-blueprint/SKILL.md`, sobald du eine neue Rolle erstellst oder den `MasterComputer` erweiterst.
3. **NIEMALS auf gut Glück probieren:** Bei jeder noch so kleinen Unklarheit (UI-Layout, Verhalten, Trigger) **immer erst über `ask_question` nachfragen**, statt Annahmen zu treffen!
4. **Backup-Abfrage vor JEDER Skript-Änderung (PFLICHT):**
   - Frage den Nutzer **vor jeder Änderung an bestehenden Skripten**, ob vorab ein Projekt-Backup in `backups/<Rolle>/startup.lua` angelegt bzw. aktualisiert werden soll!
   - Erst nach der Antwort des Nutzers wird der Code geändert.

### 4.2 Beim Programmieren & Selbst-Kontrolle
- **Chirurgische Edits:** Ändere mit `replace_file_content` nur die betroffenen Zeilenblöcke. Entferne niemals ungefragt bestehende Funktionen oder Sicherheitsprüfungen.
- **Pflicht-Selbstcheck nach jedem Edit:** Prüfe nach jeder Änderung an einer `.lua`-Datei:
  1. Stimmen alle benutzten Tabellen-/Variablennamen exakt mit ihrer Deklaration oben im Skript überein?
  2. Sind alle `string.format`-Aufrufe mit `or 0` / `or ""` gegen `nil` abgesichert?
  3. Passt die UI-Geometrie zum Gerätetyp (`MasterComputer` = **26×20 Pocket Computer**, max. 24 Zeichen Breite; alle anderen Rollen = **51×19 Advanced Computer**)?

### 4.3 Nach jeder Änderung
1. **Kurze Zusammenfassung:** Erkläre in **höchstens 5 Zeilen**, was geändert wurde und warum.
2. **Was ist im Spiel zu tun?** Sage kurz, wie das Update ins Spiel kommt (GitHub Sync in VS Code $\rightarrow$ Update am MasterComputer).
3. **2–3 konkrete Testschritte:** Beschreibe kurz, was im Spiel getestet werden soll.
4. **Dokumentation pflegen:** Aktualisiere `docs/changelog.md` (und bei Bedarf `docs/netzwerk.md`, `docs/peripherals.md`, `roles/<Rolle>.txt`, `installer.lua`).
