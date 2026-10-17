# Arbeitsweise

## Vor jeder Änderung
1. Lies die betroffenen Programme und die Dateien in `docs/`, bevor du etwas änderst.
2. Ist meine Bitte unklar, stelle höchstens zwei kurze Fragen. Sonst entscheide selbst und nenne deine Annahme in einem Satz.
3. Bei neuen Ideen schlage erst einen kurzen Plan vor: welche Dateien ändern sich, was kann schiefgehen. Warte auf mein OK.

## Beim Ändern
- Mache die kleinste Änderung, die funktioniert. Schreibe keine Dateien komplett neu, benenne nichts um und entferne keine Funktionen, die ich nicht erwähnt habe. Bestehendes, das läuft, bleibt wie es ist.
- Jede Programmdatei beginnt mit einem Kommentarkopf: Zweck, Rolle (Computer), Abhängigkeiten.
- Halte Code lesbar: sprechende Namen, kurze Funktionen, Einstellungen als Konstanten am Dateianfang.
- Bleibe im Projektordner. Lösche keine Dateien ohne Rückfrage. Führe keine Terminalbefehle aus, außer ich bitte darum.

## Nach jeder Änderung
- Sage mir, was ich im Spiel tun muss (z. B. `update lager` ausführen oder Datei auf Computer X kopieren und neu starten).
- Nenne 2–3 konkrete Testschritte im Spiel und was ich sehen sollte.
- Trage die Änderung in `docs/changelog.md` ein (Datum, Datei, ein Satz).
- Ändern sich Protokolle oder Nachrichten, aktualisiere `docs/netzwerk.md`. Kommen neue Dateien dazu, aktualisiere `roles/<rolle>.txt`.

## Ehrlichkeit
- Wenn du dir bei einer CC: Tweaked-Funktion nicht sicher bist, sage es und schlage ein kleines Testprogramm vor, statt zu raten.
- Weise mich auf Risiken hin (z. B. Endlosschleife, Chunk-Loading, viel Netzwerkverkehr), auch wenn ich nicht danach gefragt habe.
