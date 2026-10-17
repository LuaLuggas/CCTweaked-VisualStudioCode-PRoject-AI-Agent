# CC: Tweaked – Technische Regeln & Bunker-Standard

## Sprache und Umgebung
- Nutze nur Lua-Sprachmittel aus Lua 5.1/5.2 (`bit32` statt Bit-Operatoren, kein `//`, kein `<const>`).
- **60-Upvalue-Limit beachten:** Bündle in größeren Skripten Konstanten in `local CFG = {...}`, Laufzeit-Variablen in `local state = {...}` und Klick-Bereiche in `local hitboxes = {...}` (bzw. `currentButtons = {}`).
- **Keine Umlaute im Ingame-Text:** Schreibe in allen Strings für Terminal- und Monitor-Ausgaben konsequent `ae`, `oe`, `ue`, `ss` (z. B. `ZURUECK`, `TUERSENSOR`, `GROESSE`).
- Jede Programmrolle bleibt eine eigenständige Einzeldatei `programme/<Rolle>/startup.lua` (All-in-One-Prinzip für sicheres Remote-Update, `loadfile()`-Check und Backup).

## Programmfluss, UI & Timer
- **Dirty-Flag Rendering (`dirty = true`):** Zeichne das Terminal nur neu, wenn sich Daten oder Logs geändert haben (`if dirty then draw(); dirty = false end`).
- **GPS-Caching:** Rufe `gps.locate()` niemals ungecacht während laufender Animations-/Blink-Timer auf (da `gps.locate` Events konsumiert und Timer verschluckt). Frage GPS beim Start vor dem Starten der Timer ab (`cachedPos`).
- **Bunker-UI-Styleguide:**
  - Hintergrund `colors.black`, Header `--- TITEL ---` in Akzentfarbe, `ID:<nr>` oben rechts in `colors.lightGray`.
  - Ungespeicherte Änderungen (`hasPendingChanges()`) färben den Speichern-/Action-Button **Orange (`colors.orange`) mit schwarzer Schrift (`colors.black`)**.
  - Temporäre Status-/Debug-Meldungen unten in `colors.gray`, die über `tickTimer = os.startTimer(0.5)` nach `LOG_TTL` (4–6s) verschwinden.
- **Fehlerschutz-Wrapper:** Hauptschleife in `while true do local ok, err = pcall(main) ...` kapseln. `Terminated` sauber durchlassen (Terminal leeren, Cursor-Blink aus), andere Fehler anzeigen und nach 2–5s weiterlaufen.

## Peripherals & Netzwerk
- Kapsle Zugriffe auf externe Blöcke (`monitor`, `player_detector`, Mekanism, AE2 `meBridge`, etc.) in `pcall(...)` und reagiere auf `peripheral` / `peripheral_detach` / `monitor_resize`.
- **ERFINDE NIEMALS Methodennamen von Mod-Blöcken.** Nutze nur bestätigte Methoden aus `docs/peripherals.md`. Bei neuen Blöcken aus ATM10 zuerst Methoden per `peripheral.getMethods()` im Spiel abfragen lassen.
- Alle Rednet-Protokolle und Nachrichtenformate richten sich strikt nach `docs/netzwerk.md` (`MASTER_ID = 24`).
- Remote-Updates prüfen den heruntergeladenen Code immer in `startup.update_tmp` auf HTML-Fehlerseiten und per `loadfile()` auf Lua-Syntaxfehler, legen `startup.backup` an und führen danach `os.reboot()` aus.
