# CC: Tweaked – Technische Regeln & Bunker-Standard

## Sprache, Upvalue-Schutz & Anti-Crash-Regeln
- Nutze nur Lua-Sprachmittel aus Lua 5.1/5.2 (`bit32` statt Bit-Operatoren, kein `//`, kein `<const>`).
- **60-Upvalue-Limit strikt einhalten:** Füge in bestehenden großen Skripten (`MasterComputer`, `TextAnzeige`, `Lautsprecher`) niemals neue einzelne Top-Level-`local`-Variablen hinzu! Lege neue Werte immer als Felder in bestehenden Tabellen (`CFG`, `state`, `spkCfg`, `hitboxes`, `currentButtons`) an.
- **Kein `nil` in `string.format`:** Prüfe vor jedem Edit die exakte Schreibweise der Tabellenfelder am Dateianfang und sichere `string.format` immer mit Fallbacks ab (`tonumber(val) or 0` bzw. `tostring(str or "")`).
- **Keine Umlaute im Ingame-Text:** Schreibe in allen Strings für Terminal- und Monitor-Ausgaben konsequent `ae`, `oe`, `ue`, `ss` (z. B. `ZURUECK`, `TUERSENSOR`, `GROESSE`).
- Jede Programmrolle bleibt eine eigenständige Einzeldatei `programme/<Rolle>/startup.lua` (All-in-One-Prinzip für sicheres Remote-Update, `loadfile()`-Check und Backup).

## Programmfluss, UI & Bildschirm-Geometrie
- **Geräte-Auflösungen strikt beachten:**
  - **`MasterComputer` (ID 24) = Advanced Pocket Computer (`26 Spalten × 20 Zeilen`):** Nutzbare Breite max. 22–24 Zeichen (Spalten `2..25`). Nichts darf über Spalte 25 hinausragen!
  - **Alle anderen Rollen = Stationärer Advanced Computer (`51 Spalten × 19 Zeilen`):** Menü-Buttons maximal bis Zeile `16`, Zeile `17–19` für Status-/Debug-Zeile.
  - **Externe Monitore:** Dynamisch via `monitor.getSize()`.
- **Dirty-Flag Rendering (`dirty = true`):** Zeichne das Terminal nur neu, wenn sich Daten oder Logs geändert haben (`if dirty then draw(); dirty = false end`).
- **GPS-Caching:** Rufe `gps.locate()` niemals ungecacht während laufender Animations-/Blink-/Audio-Timer auf (da `gps.locate` Events konsumiert und Timer verschluckt). Frage GPS beim Start vor dem Starten der Timer ab (`cachedPos`).
- **Bunker-UI-Styleguide:**
  - Hintergrund `colors.black`, Header `--- TITEL ---` in Akzentfarbe, `ID:<nr>` oben rechts in `colors.lightGray`.
  - Ungespeicherte Änderungen (`hasPendingChanges()`) färben den Speichern-/Action-Button **Orange (`colors.orange`) mit schwarzer Schrift (`colors.black`)**.
  - Temporäre Status-/Debug-Meldungen unten in `colors.gray`, die über `tickTimer = os.startTimer(0.5)` nach `LOG_TTL` (4–6s) verschwinden.
- **Fehlerschutz-Wrapper:** Hauptschleife in `pcall(main)` kapseln. `Terminated` sauber durchlassen (Terminal leeren, Cursor-Blink aus).

## Peripherals & Netzwerk
- Kapsle Zugriffe auf externe Blöcke (`monitor`, `player_detector`, `speaker`, Mekanism, AE2 `meBridge`, etc.) in `pcall(...)` und reagiere auf `peripheral` / `peripheral_detach` / `monitor_resize`.
- **ERFINDE NIEMALS Methodennamen von Mod-Blöcken.** Nutze nur bestätigte Methoden aus `docs/peripherals.md`. Bei neuen Blöcken aus ATM10 zuerst Methoden per `peripheral.getMethods()` im Spiel abfragen lassen.
- Alle Rednet-Protokolle und Nachrichtenformate richten sich strikt nach `docs/netzwerk.md` (`MASTER_ID = 24`).
- Remote-Updates prüfen den heruntergeladenen Code immer in `startup.update_tmp` auf HTML-Fehlerseiten und per `loadfile()` auf Lua-Syntaxfehler, legen `startup.backup` an und führen danach `os.reboot()` aus.
