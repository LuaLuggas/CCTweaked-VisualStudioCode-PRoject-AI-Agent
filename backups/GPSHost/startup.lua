-- ============================================================================
-- GPS-HOST TERMINAL (Advanced Computer + Ender Modem, CC:Tweaked / ATM10)
-- Speichert sich selbst als startup.lua, hostet GPS, zeigt den letzten
-- Update-Status in der UI und unterstuetzt Remote-Relocate & Refresh vom Master.
-- ============================================================================

local COMPUTER_ID     = os.getComputerID()
local MASTER_ID       = 24
local CONFIG_FILE     = "gps_config.txt"
local UPDATE_PROTOCOL = "gps_update"
local CONFIG_PROTOCOL = "gps_config"
local LEGACY_PROTOCOL = "signs_update" -- Abwaertskompatibilitaet fuer Pings/Updates
local TEMP_FILE       = "startup.update_tmp"
local BACKUP_FILE     = "startup.backup"
local CHANNEL_GPS     = (gps and gps.CHANNEL_GPS) or 65534

local MAX_LOG  = 3
local LOG_TTL  = 6
local FIELD_W  = 10

-- Layout
local FIELD_X  = {2, 14, 26}
local FIELD_Y  = 8
local BTN_X, BTN_Y, BTN_W = 2, 11, 18

-- Zustand (inkl. Zeitstempel & Status des letzten Updates)
local host           = {x = 100, y = 64, z = -200}
local lastUpdateTime = "-"
local lastUpdateStat = "noch keins"
local status         = "Offline"
local requests       = 0
local modem, modemName
local fields         = {"", "", ""}
local focus          = nil
local fresh          = false
local logs           = {}
local dirty          = true
local relocTimer, tickTimer

local function now() return os.epoch("utc") / 1000 end

local function addLog(text)
    logs[#logs + 1] = {text = text, expires = now() + LOG_TTL}
    while #logs > MAX_LOG do table.remove(logs, 1) end
    dirty = true
end

-- ---------------------------------------------------------------------------
-- Selbststaendige Sicherung als startup.lua
-- ---------------------------------------------------------------------------
local function ensureStartup()
    local shellPath = shell and shell.getRunningProgram() or "startup.lua"
    if shellPath ~= "startup.lua" and shellPath ~= "startup" then
        if fs.exists("startup.lua") then fs.delete("startup.lua") end
        if fs.exists("startup") then fs.delete("startup") end
        pcall(fs.copy, shellPath, "startup.lua")
    end
end
ensureStartup()

-- ---------------------------------------------------------------------------
-- Konfiguration laden und speichern (inkl. Update-Zeitstempel & Status)
-- ---------------------------------------------------------------------------
local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        if f then
            local data = textutils.unserialize(f.readAll())
            f.close()
            if type(data) == "table" then
                host.x = tonumber(data.x) or host.x
                host.y = tonumber(data.y) or host.y
                host.z = tonumber(data.z) or host.z
                if type(data.lastUpdateTime) == "string" then
                    lastUpdateTime = data.lastUpdateTime
                end
                if type(data.lastUpdateStat) == "string" then
                    lastUpdateStat = data.lastUpdateStat
                end
                return true
            end
        end
    end
    return false
end

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    if not f then return false end
    f.write(textutils.serialize({
        x              = host.x,
        y              = host.y,
        z              = host.z,
        lastUpdateTime = lastUpdateTime,
        lastUpdateStat = lastUpdateStat
    }))
    f.close()
    return true
end

local function syncFields()
    fields = {tostring(host.x), tostring(host.y), tostring(host.z)}
end

local function parseCoord(s)
    local n = tonumber(s)
    if n and n == math.floor(n) and math.abs(n) <= 30000000 then return n end
    return nil
end

local function hasPendingChanges()
    return parseCoord(fields[1]) ~= host.x
        or parseCoord(fields[2]) ~= host.y
        or parseCoord(fields[3]) ~= host.z
end

-- ---------------------------------------------------------------------------
-- Master-Reporting
-- ---------------------------------------------------------------------------
local function getPositionString()
    return string.format("%.0f, %.0f, %.0f", host.x, host.y, host.z)
end

local function sendReport(success, details)
    if not modem then return end
    local posStr = getPositionString()
    local label = os.getComputerLabel() or ("GPS-Host " .. tostring(COMPUTER_ID))
    pcall(function()
        rednet.send(MASTER_ID, {
            action  = "log_report",
            success = success,
            details = details or string.format("Host aktiv X:%d Y:%d Z:%d", host.x, host.y, host.z),
            pos     = posStr,
            label   = label,
            preview = string.format("X:%d Y:%d Z:%d", host.x, host.y, host.z),
            devType = "gps"
        }, UPDATE_PROTOCOL)
    end)
end

-- ---------------------------------------------------------------------------
-- Modem und Rednet Initialisierung
-- ---------------------------------------------------------------------------
local function setupModem()
    if modem then
        pcall(modem.close, CHANNEL_GPS)
        pcall(rednet.close, modemName)
    end
    modem, modemName = nil, nil

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
            modem, modemName = peripheral.wrap(name), name
            break
        end
    end

    if modem then
        modem.open(CHANNEL_GPS)
        rednet.open(modemName)
        status = "Online"
        addLog("Modem '" .. modemName .. "' bereit, Kanal " .. CHANNEL_GPS .. " offen")
        sendReport(true, "GPS-Host online")
    else
        status = "Error"
        addLog("Kein kabelloses Modem gefunden!")
    end
    dirty = true
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
local function pad(s, n)
    s = tostring(s)
    if #s > n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
end

local function draw()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()

    -- Kopfzeile
    term.setCursorPos(2, 1)
    term.setTextColor(colors.cyan)
    term.write("--- GPS ANTENNE ---")
    local idStr = "ID:" .. COMPUTER_ID
    term.setCursorPos(w - #idStr, 1)
    term.setTextColor(colors.lightGray)
    term.write(idStr)

    -- Status
    term.setCursorPos(2, 3)
    term.setTextColor(colors.white)
    term.write("Status: ")
    if status == "Online" then term.setTextColor(colors.green)
    elseif status == "Relocating" then term.setTextColor(colors.yellow)
    elseif status == "Error" or status == "Offline" then term.setTextColor(colors.red)
    end
    term.write(status)

    -- Aktive Koordinaten & Ping-Zaehler
    term.setCursorPos(2, 4)
    term.setTextColor(colors.white)
    term.write(string.format("Aktuell: X:%d Y:%d Z:%d", host.x, host.y, host.z))
    term.setCursorPos(2, 5)
    term.setTextColor(colors.lightGray)
    term.write("Anfragen beantwortet: " .. requests)

    -- Eingabefelder
    local labels = {"X", "Y", "Z"}
    for i = 1, 3 do
        term.setCursorPos(FIELD_X[i], FIELD_Y - 1)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.write(labels[i] .. ":")

        term.setCursorPos(FIELD_X[i], FIELD_Y)
        if focus == i then
            term.setBackgroundColor(colors.lightGray)
            term.setTextColor(colors.black)
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.white)
        end
        term.write(pad(fields[i], FIELD_W))
    end

    -- Relocate-Button
    term.setCursorPos(BTN_X, BTN_Y)
    term.setBackgroundColor(hasPendingChanges() and colors.orange or colors.green)
    term.setTextColor(colors.black)
    local label = "RELOCATE"
    local padL = math.floor((BTN_W - #label) / 2)
    term.write(pad(string.rep(" ", padL) .. label, BTN_W))

    -- Hinweis & Update-Status-Anzeige (wie bei ID: in dezentem Grau)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, BTN_Y + 2)
    term.write("Feld anklicken | Tab/Enter: weiter")

    term.setCursorPos(2, BTN_Y + 3)
    term.setTextColor(colors.lightGray)
    local updInfo = string.format("letz. Update: [%s] [%s]", tostring(lastUpdateTime), tostring(lastUpdateStat))
    term.write(updInfo:sub(1, w - 2))

    -- Debug-Zeilen (grau, unten, verschwinden von selbst)
    term.setTextColor(colors.gray)
    local startRow = h - #logs + 1
    for i, entry in ipairs(logs) do
        term.setCursorPos(2, startRow + i - 1)
        term.write(pad(entry.text, w - 2))
    end

    if focus then
        term.setBackgroundColor(colors.lightGray)
        term.setTextColor(colors.black)
        term.setCursorPos(FIELD_X[focus] + math.min(#fields[focus], FIELD_W - 1), FIELD_Y)
        term.setCursorBlink(true)
    else
        term.setCursorBlink(false)
    end
end

-- ---------------------------------------------------------------------------
-- Aktionen (Lokales Relocate, Remote-Relocate & Update)
-- ---------------------------------------------------------------------------
local function relocate()
    local x, y, z = parseCoord(fields[1]), parseCoord(fields[2]), parseCoord(fields[3])
    if not (x and y and z) then
        addLog("Ungueltige Eingabe: nur ganze Zahlen")
        return
    end

    focus = nil
    status = "Relocating"
    addLog(string.format("Relocate -> %d, %d, %d", x, y, z))

    host.x, host.y, host.z = x, y, z
    syncFields()

    if saveConfig() then
        addLog("Konfiguration gespeichert")
        sendReport(true, string.format("GPS-Host neu positioniert (%d, %d, %d)", host.x, host.y, host.z))
    else
        addLog("Speichern fehlgeschlagen!")
    end

    relocTimer = os.startTimer(0.8)
    dirty = true
end

-- Relocate vom Master anhand der im Host gespeicherten Koordinaten
local function remoteRelocateFromSaved()
    loadConfig()
    syncFields()
    focus = nil
    status = "Relocating"

    if modem then
        pcall(modem.open, CHANNEL_GPS)
    else
        setupModem()
    end

    addLog(string.format("Master-Relocate -> %d, %d, %d", host.x, host.y, host.z))
    sendReport(true, string.format("Relocate ausgefuehrt (%d, %d, %d)", host.x, host.y, host.z))
    relocTimer = os.startTimer(0.8)
    dirty = true
end

local function answerPing(replyChannel, distance)
    if not modem or status == "Error" then return end
    modem.transmit(replyChannel, CHANNEL_GPS, {host.x, host.y, host.z})
    requests = requests + 1
end

local function focusField(i, keepText)
    focus = i
    fresh = not keepText
    dirty = true
end

local function extractPasteId(input)
    if type(input) ~= "string" then return nil end
    input = input:gsub("^%s+", ""):gsub("%s+$", "")
    input = input:gsub("[?#].*$", ""):gsub("/+$", "")

    local patterns = {
        "^([%a%d]+)$",
        "^https?://pastebin%.com/raw/([%a%d]+)$",
        "^https?://pastebin%.com/([%a%d]+)$",
        "^pastebin%.com/raw/([%a%d]+)$",
        "^pastebin%.com/([%a%d]+)$",
    }
    for _, pattern in ipairs(patterns) do
        local id = input:match(pattern)
        if id then return id end
    end
    return nil
end

local function applyUpdate(rawCode)
    addLog("Lade Update...")
    draw()

    local function failUpdate(reason)
        lastUpdateTime = os.date("%H:%M:%S")
        lastUpdateStat = "fehlgeschlagen"
        saveConfig()
        sendReport(false, reason)
        addLog("Update fehlgeschlagen: " .. reason)
        draw()
        return false
    end

    local pasteCode = extractPasteId(rawCode)
    if not pasteCode then
        return failUpdate("Ungueltiger Code")
    end

    if not http then
        return failUpdate("HTTP inaktiv")
    end

    local url = "https://pastebin.com/raw/" .. pasteCode .. "?cb=" .. string.format("%d", os.epoch("utc"))
    local res = http.get(url)
    if not res then
        return failUpdate("Download fehlgeschlagen")
    end

    local content = res.readAll()
    res.close()
    if not content or #content == 0 then
        return failUpdate("Datei leer")
    end

    -- Syntax pruefen bevor startup.lua ueberschrieben wird
    local tf = fs.open(TEMP_FILE, "w")
    if not tf then
        return failUpdate("Schreibfehler Temp")
    end
    tf.write(content)
    tf.close()

    local compiled = loadfile(TEMP_FILE)
    fs.delete(TEMP_FILE)
    if not compiled then
        return failUpdate("Syntaxfehler im Code")
    end

    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists("startup.lua") then
        pcall(fs.copy, "startup.lua", BACKUP_FILE)
    end

    local f = fs.open("startup.lua", "w")
    if not f then
        return failUpdate("Schreibfehler startup.lua")
    end
    f.write(content)
    f.close()

    if fs.exists("startup") then fs.delete("startup") end

    lastUpdateTime = os.date("%H:%M:%S")
    lastUpdateStat = "erfolgreich"
    saveConfig()

    sendReport(true, "Update erfolgreich installiert (" .. pasteCode .. ")")
    addLog("Neustart in 2s...")
    draw()
    sleep(2)
    os.reboot()
end

-- ---------------------------------------------------------------------------
-- Hauptschleife
-- ---------------------------------------------------------------------------
local function main()
    tickTimer = os.startTimer(0.5)

    while true do
        if dirty then
            draw()
            dirty = false
        end

        local ev, a, b, c, d, e = os.pullEvent()

        if ev == "modem_message" then
            if a == modemName and b == CHANNEL_GPS and d == "PING" then
                answerPing(c, e)
            end

        elseif ev == "rednet_message" then
            -- a = senderId, b = message, c = protocol
            if c == UPDATE_PROTOCOL or c == CONFIG_PROTOCOL or c == LEGACY_PROTOCOL then
                if b == "STATUS_REQUEST" then
                    sendReport(true, "GPS-Host online")
                elseif a == MASTER_ID and type(b) == "table" then
                    if b.action == "relocate" then
                        remoteRelocateFromSaved()
                    elseif b.action == "update" and c == UPDATE_PROTOCOL then
                        pcall(function() rednet.send(MASTER_ID, { action = "ping_ack" }, UPDATE_PROTOCOL) end)
                        applyUpdate(b.code)
                    elseif b.action == "update_gps" and c == LEGACY_PROTOCOL then
                        pcall(function() rednet.send(MASTER_ID, { action = "ping_ack" }, UPDATE_PROTOCOL) end)
                        applyUpdate(b.code)
                    end
                end
            end

        elseif ev == "mouse_click" then
            local x, y = b, c
            local hit = false
            for i = 1, 3 do
                if y == FIELD_Y and x >= FIELD_X[i] and x < FIELD_X[i] + FIELD_W then
                    focusField(i)
                    hit = true
                end
            end
            if not hit then
                if y == BTN_Y and x >= BTN_X and x < BTN_X + BTN_W then
                    relocate()
                else
                    focus = nil
                    dirty = true
                end
            end

        elseif ev == "char" then
            if focus and #fields[focus] < FIELD_W - 1 or (focus and fresh) then
                if a:match("^%d$") or a == "-" then
                    if fresh then fields[focus] = ""; fresh = false end
                    if a ~= "-" or #fields[focus] == 0 then
                        if #fields[focus] < FIELD_W - 1 then
                            fields[focus] = fields[focus] .. a
                        end
                    end
                    dirty = true
                end
            end

        elseif ev == "key" then
            if focus and a == keys.backspace then
                if fresh then fields[focus] = ""; fresh = false
                else fields[focus] = fields[focus]:sub(1, -2) end
                dirty = true
            elseif a == keys.tab then
                focusField(((focus or 0) % 3) + 1)
            elseif a == keys.enter or a == keys.numPadEnter then
                if focus and focus < 3 then
                    focusField(focus + 1)
                else
                    relocate()
                end
            end

        elseif ev == "timer" then
            if a == relocTimer then
                relocTimer = nil
                status = modem and "Online" or "Error"
                addLog(string.format("Hoste jetzt bei %d, %d, %d", host.x, host.y, host.z))
            elseif a == tickTimer then
                tickTimer = os.startTimer(0.5)
                local t = now()
                for i = #logs, 1, -1 do
                    if logs[i].expires <= t then
                        table.remove(logs, i)
                        dirty = true
                    end
                end
            end

        elseif ev == "peripheral" or ev == "peripheral_detach" then
            setupModem()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Start
-- ---------------------------------------------------------------------------
if loadConfig() then
    addLog("Konfiguration geladen")
else
    addLog("Keine Konfig - Standardwerte")
end
syncFields()
setupModem()

while true do
    local ok, err = pcall(main)
    if not ok then
        if tostring(err):find("Terminated") then
            term.setCursorBlink(false)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
            term.setCursorPos(1, 1)
            print("GPS-Host beendet.")
            return
        end
        addLog("Fehler: " .. tostring(err))
        sleep(2)
    end
end