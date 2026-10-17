# Peripherals & Hardware im Bunker (ATM10 / MC 1.21.1)

Diese Datei listet alle aktuell in den Skripten verwendeten sowie für den weiteren Ausbau geplanten Peripherals und Mod-Blöcke auf.
**Goldene Regel:** Es dürfen im Code nur Methoden verwendet werden, die hier als bestätigt eingetragen sind!

---

## 1. Aktuell im Einsatz (Bestätigt & Produktiv)

### 1.1 CC:Tweaked Standard-Hardware
| Peripheral-Typ | Erkennung im Code | Verwendet in | Bestätigte Methoden & Events |
| :--- | :--- | :--- | :--- |
| **`modem`** (Wireless / Ender Modem) | `peripheral.find("modem")` / `peripheral.call(name, "isWireless")` | Alle Skripte | `rednet.open(name)`, `rednet.close(name)`, `modem.open(channel)`, `modem.close(channel)`, `modem.transmit(replyCh, ch, payload)`<br>Events: `rednet_message`, `modem_message` |
| **`monitor`** (Advanced Monitor) | `peripheral.find("monitor")` | `EmergencyTerminal`, `TextAnzeige` | `setTextScale(scale)`, `getSize()`, `setCursorPos(x, y)`, `setBackgroundColor(col)`, `setTextColor(col)`, `clear()`, `write(text)`, `setPaletteColor(col, r, g, b)`<br>Events: `monitor_touch`, `monitor_resize` |
| **`speaker`** (CC:Tweaked Speaker) | `peripheral.find("speaker")` | `Lautsprecher`, `RadioHost` (Studio-Playback) | `playAudio(pcmBuffer, volume)` (gibt `true` zurück wenn akzeptiert, `false` wenn Puffer voll; `volume` von `0.0` bis `3.0`), `stop()`<br>Audio-Dekodierung: `require("cc.audio.dfpwm").make_decoder()`<br>Event: `speaker_audio_empty` |
| **Redstone (Intern)** | `rs` / `redstone` API | `Tuersensor`, `Lautsprecher` | `rs.setOutput("top", true/false)` (`Tuersensor`), `rs.getSides()`, `rs.getInput(side)` (`Lautsprecher` im Modus `REDSTONE`)<br>Event: `redstone` |

### 1.2 Advanced Peripherals (Bereits aktiv)
| Peripheral-Typ | Erkennung im Code | Verwendet in | Bestätigte Methoden |
| :--- | :--- | :--- | :--- |
| **`player_detector`** (`playerDetector`) | `peripheral.find("player_detector")` | `Tuersensor`, `Lautsprecher` | `getPlayersInRange(range)` $\rightarrow$ gibt Array-Tabelle mit Spielernamen im Umkreis (`range` in Blöcken) zurück. *(Immer in `pcall` kapseln!)* |

---

## 2. Geplante Erweiterungen im Bunker (ATM10)

Für folgende Systeme im Bunker sind Erweiterungen vorgesehen. Bevor ein neues Peripheral programmiert wird, prüfen wir bei Bedarf mit dem Ingame-Scanner (siehe Abschnitt 3) die exakten Methodennamen der installierten ATM10-Version.

### 2.1 Advanced Peripherals (Weitere Blöcke)
- **`environment_detector` (`environmentDetector`)**: Strahlungs-/Umweltmessung, Biohazard-Überwachung, Dimension/Wetter/Zeit-Checks.
  - Typische Methoden (vor Nutzung im Spiel verifizieren): `getRadiation()`, `getRadiationRaw()`, `isSlimeChunk()`, `getBiome()`, `getDimension()`.
- **`energy_detector` (`energyDetector`)**: Durchfluss-Messung und Begrenzung von Stromleitungen.
  - Typische Methoden: `getTransferRate()`, `getTransferRateLimit()`, `setTransferRateLimit(rate)`.
- **`redstone_integrator` (`redstoneIntegrator`)**: Zusätzliche Redstone-Ausgänge für komplexe Schleusen, Sequenzen und Warnlichter.
  - Typische Methoden: `setOutput(side, bool)`, `getInput(side)`, `setAnalogOutput(side, val)`.
- **`chat_box` (`chatBox`)**: Automatische Bunker-Durchsagen im Chat bei Alarm, Lockdown oder Reaktor-Warnungen.
  - Typische Methoden: `sendMessage(msg, prefix, brackets, color)`, `sendMessageToPlayer(msg, player, ...)`.

### 2.2 Mekanism (Energie, Reaktoren, Biohazard/Strahlung)
- **Einsatzgebiete:** Fissions-/Fusionsreaktor-Überwachung, Induction Matrix (Energiespeicher), Turbinen, Gas-/Abwasser-Tanks.
- **Wichtig:** Mekanism-Blöcke stellen in CC:Tweaked je nach Block eigene Peripheral-Typen bereit (z. B. `inductionPort`, `fissionReactorLogicAdapter`, `spsPort`, `dynamicValve`). Vor dem Bau eines neuen Skripts einmal `peripheral.getMethods()` am jeweiligen Port ausführen!

### 2.3 Applied Energistics 2 (AE2 Lager & Crafting über `me_bridge` / `meBridge`)
- **Einsatzgebiete:** Lagerbestände auf Bunker-Monitoren anzeigen, kritische Ressourcen überwachen, Auto-Crafting auslösen.
- **Typische Methoden (`meBridge`):** `listItems()`, `getItem({name=...})`, `craftItem({name=..., count=...})`, `getEnergyUsage()`, `getEnergyStorage()`, `getTotalItemStorage()`, `getUsedItemStorage()`.

### 2.4 Mystical Agriculture Farmen
- **Einsatzgebiete:** Dokumentation aktuell gepflanzter Seeds, Status-Anzeigen der Farm-Etagen, ggf. automatisierter Seed-Wechsel / Bestandsabgleich über angeschlossene Inventare, Turtles, Redstone oder AE2-Schnittstellen.

### 2.5 Reine CC:Tweaked Systeme
- **Mehrteilige Schleusen & Dekontaminations-Kammern:** Zeitgesteuerte Tür-/Partikel-/Sound-Sequenzen beim Betreten und Verlassen des Bunkers.

---

## 3. Ingame-Hilfsbefehl zum Auslesen neuer Blöcke

Wenn du im Bunker einen neuen Block (z. B. von Mekanism oder Advanced Peripherals) neben einen Computer stellst oder per Wired Modem verbindest, kannst du diesen Einzeiler in die Lua-Konsole (`lua` eingeben) kopieren, um alle Namen und Methoden anzuzeigen:

```lua
for _, n in ipairs(peripheral.getNames()) do print(n, peripheral.getType(n)) end
```

Und um alle Methoden eines bestimmten Blocks (z. B. `"back"` oder `"meBridge_0"`) in eine Datei `methods.txt` zu schreiben:

```lua
local f = fs.open("methods.txt", "w") f.write(textutils.serialize(peripheral.getMethods("NAME_HIER"))) f.close()
```
*(Den Inhalt kannst du mir dann einfach kurz nennen oder reinkopieren, damit ich keinen einzigen Methodennamen raten muss!)*
