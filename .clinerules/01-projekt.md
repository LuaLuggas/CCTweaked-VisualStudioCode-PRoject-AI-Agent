# Projekt

Dieses Projekt enthält Lua-Programme für die Minecraft-Mod CC: Tweaked (Minecraft 1.21.1, Modpack All The Mods 10). Die Programme laufen auf Computern, Turtles und Pocket-Computern IM SPIEL, nicht auf meinem PC. Ich bin Hobbyspieler und kein Programmierer.

## Wie du mit mir sprichst
- Antworte auf Deutsch, kurz und ohne Fachjargon.
- Erkläre bei jeder Änderung in höchstens 5 Zeilen, was du geändert hast und warum.
- Kommentare im Code schreibst du auf Deutsch.

## Ordnerstruktur
- `programme/<rolle>/`: die Programme je Computer-Rolle (z. B. lager, farm).
- `lib/`: gemeinsame Module, die mehrere Programme nutzen.
- `roles/<rolle>.txt`: Liste der Dateien, die `update.lua` für diese Rolle auf den Computer lädt.
- `docs/peripherals.md`: welche Blöcke an welchen Computern hängen und welche Methoden sie haben.
- `docs/netzwerk.md`: Rednet-Protokolle, Computer-IDs und Nachrichtenformate.
- `docs/changelog.md`: kurze Liste aller Änderungen.

## Meine Base
- Computer und ihre Aufgaben: (hier eintragen, z. B. "Computer 12 = Lagerüberwachung, Monitor links")
- Verwendete Zusatzmods mit Peripherals: (z. B. Advanced Peripherals, Create, Mekanism, Applied Energistics)
