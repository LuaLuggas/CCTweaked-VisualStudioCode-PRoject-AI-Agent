# CC: Tweaked – technische Regeln

## Sprache und Umgebung
- Nutze nur Lua-Sprachmittel aus Lua 5.1/5.2. Keine Features aus Lua 5.3/5.4 (z. B. Bit-Operatoren, `//`, `<const>`), außer ich bestätige, dass sie in CC: Tweaked funktionieren. Für Bit-Operationen nutze `bit32`.
- Es gibt kein `os.execute`, kein `io.popen` und keine externen Lua-Bibliotheken. Dateien gehen über `fs`, Netzwerk über `http` und `rednet`.
- Verwende kein `getfenv`/`setfenv` und kein `string.dump`.
- Gemeinsamen Code aus `lib/` lade mit `dofile("/lib/name.lua")`; das Modul gibt eine Tabelle zurück.

## Programmfluss
- Dauerprogramme müssen regelmäßig abgeben: Jede Schleife braucht `sleep(...)` oder `os.pullEvent(...)`, sonst bricht CC mit "Too long without yielding" ab.
- Mehrere Dinge gleichzeitig (z. B. Bedienung und Netzwerk) löst du mit `parallel.waitForAny` oder `parallel.waitForAll`.
- Verschlucke `terminate` (Strg+T) nie unbeabsichtigt, damit ich ein Programm immer abbrechen kann.
- Rufe `os.shutdown()` und `os.reboot()` nie ohne ausdrückliche Anweisung auf.
- Dauerprogramme fangen Fehler in der Hauptschleife mit `pcall` ab, zeigen die Meldung auf dem Bildschirm und laufen nach 5 Sekunden weiter, außer ich sage etwas anderes.

## Peripherals (Monitore, Modems, Mod-Blöcke)
- Hole Peripherals mit `peripheral.find(typ)` oder `peripheral.wrap(name)` und prüfe immer auf `nil`, bevor du sie benutzt.
- Bei Peripherals, die ihren Chunk verlieren können, kapsle Aufrufe in `pcall`.
- ERFINDE NIEMALS Methodennamen von Mod-Blöcken. Verwende nur Methoden, die in `docs/peripherals.md` stehen oder die ich bestätigt habe. Fehlt eine, schreibe ein kleines Testprogramm `tests/peripheral_info.lua`, das `peripheral.getNames()` und `peripheral.getMethods(name)` ausgibt, und bitte mich, die Ausgabe zu schicken.
- Monitore: Touch-Eingaben kommen als Event `monitor_touch` (nur bei Advanced Monitors). Textgröße mit `setTextScale`, Bildschirmaufbau mit `term.redirect` oder `window`.

## Netzwerk
- Rednet: Modem zuerst mit `rednet.open(...)` öffnen. Sende Tabellen mit einem Feld `type` und gib immer einen Protokollnamen mit (`rednet.send`, `rednet.broadcast`, `rednet.receive(protokoll, timeout)`).
- Protokollnamen, Computer-IDs und Nachrichtenformate stehen in `docs/netzwerk.md`. Ändere sie nur gemeinsam an allen betroffenen Programmen und trage die Änderung dort ein.
- `http.get` liefert bei Fehlern `nil` und eine Meldung. Schließe jede Antwort mit `close()`.

## Daten speichern
- Einstellungen und Zustände speicherst du mit `textutils.serialize`/`textutils.unserialize` (oder `textutils.serializeJSON`) in Dateien über `fs.open`.

## Turtles
- Prüfe bei jeder Bewegung und Aktion den Rückgabewert (`local ok, grund = turtle.forward()`). Prüfe vor langen Fahrten `turtle.getFuelLevel()`. Keine Endlosschleife bei blockierten Wegen.

## Start
- Eine Datei `startup.lua` im Wurzelverzeichnis des Computers startet beim Einschalten.

## Offizielle Dokumentation
- CC: Tweaked: https://tweaked.cc (die Version für Minecraft 1.21.1 beachten)
- Advanced Peripherals: https://docs.intelligence-modding.de
- Lies zuerst die gespeicherten Seiten in docs/referenz/. Maßgeblich für meine Mod-Version ist, was `peripheral.getMethods` im Spiel ausgibt.
