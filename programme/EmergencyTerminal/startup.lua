-- ==================================
-- PROTOKOLL- UND NETZWERK-KONFIGURATION
-- ==================================
local PROTOCOL = "notaus"
local LOCKDOWN_PROTOCOL = "lockdown"
local UPDATE_PROTOCOL = "notaus_update"

-- ==================================
-- GERAETE- UND IDENTIFIKATIONS-VARIABLEN
-- ==================================
local MASTER_ID = 24
local COMPUTER_ID = os.getComputerID()

-- ==================================
-- DEBUG- UND SKALIERUNGS-EINSTELLUNGEN
-- ==================================
local DEBUG = true
local TEXT_SCALE = 0.5

-- ==================================
-- NACHRICHTEN-KONSTANTEN FUER REDNET
-- ==================================
local MSG_ON     = "EMERGENCY_ON"
local MSG_OFF    = "EMERGENCY_OFF"
local MSG_LOCK   = "LOCKDOWN_ON"
local MSG_UNLOCK = "LOCKDOWN_OFF"
local MSG_STATUS = "STATUS_REQUEST"

-- ==================================
-- DATEIWEGE & GITHUB-URL FUER UPDATES
-- ==================================
local TEMP_FILE = "startup.update_tmp"
local BACKUP_FILE = "startup.backup"
local GITHUB_URL = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/programme/EmergencyTerminal/startup.lua"

-- ==================================
-- PERIPHERIE-ERKENNUNG (MONITOR & MODEM)
-- ==================================
local monitor = peripheral.find("monitor")
local modem = peripheral.find("modem")

if not monitor or not modem then
    print("Fehler: Monitor oder Modem fehlt!")
    return
end

local monitorName = peripheral.getName(monitor)
rednet.open(peripheral.getName(modem))
monitor.setTextScale(TEXT_SCALE)

-- ==================================
-- ZUSTANDS-VARIABLEN DES PANELS
-- ==================================
local emergencyState = false
local lockdownState = false
local updatingState = false
local customButtonText = nil

-- ==================================
-- LAYOUT-TABELLEN FUER DIE SCHALTFLAECHEN
-- ==================================
local btnAlarm = { x1 = 1, y1 = 1, x2 = 1, y2 = 1 }
local btnLock  = { x1 = 1, y1 = 1, x2 = 1, y2 = 1 }
local btnSingle = { x1 = 1, y1 = 1, x2 = 1, y2 = 1 }

-- ==================================
-- DEBUG-HILFSFUNKTION
-- ==================================
local function debug(text)
    if DEBUG then
        print(("[%s] %s"):format(os.date("%H:%M:%S"), text))
    end
end

-- ==================================
-- GPS-POSITIONSABFRAGE
-- ==================================
local function getPositionString()
    local x, y, z = gps.locate(2)
    if x and y and z then
        return string.format("%.0f, %.0f, %.0f", x, y, z)
    else
        return "GPS n.verf."
    end
end

-- ==================================
-- STATUS-BERICHT AN DEN MASTER SENDEN
-- ==================================
local function sendReport(success, details)
    local posStr = getPositionString()
    local label = os.getComputerLabel() or ("ID " .. tostring(COMPUTER_ID))
    
    pcall(function()
        rednet.send(MASTER_ID, {
            action = "log_report",
            success = success,
            details = details,
            pos = posStr,
            label = label
        }, UPDATE_PROTOCOL)
    end)
end

-- ==================================
-- BERECHNUNG DER BUTTON-POSITIONEN (RESPONSIV)
-- ==================================
local function computeButtons()
    local mw, mh = monitor.getSize()

    if mw <= 26 and mh <= 13 then
        local btnW = math.min(15, mw - 2)
        if btnW < 5 then btnW = mw end

        local singleH = math.min(5, mh - 4)
        if singleH < 3 then singleH = 3 end
        btnSingle.x1 = math.floor((mw - btnW) / 2) + 1
        btnSingle.y1 = math.floor((mh - singleH) / 2) + 2
        btnSingle.x2 = btnSingle.x1 + btnW - 1
        btnSingle.y2 = btnSingle.y1 + singleH - 1

        local btnH = 3
        local spacing = 1
        local totalH = (btnH * 2) + spacing
        local startY = math.floor((mh - totalH) / 2) + 2
        local startX = math.floor((mw - btnW) / 2) + 1

        btnAlarm.x1 = startX
        btnAlarm.y1 = startY
        btnAlarm.x2 = startX + btnW - 1
        btnAlarm.y2 = startY + btnH - 1

        btnLock.x1 = startX
        btnLock.y1 = startY + btnH + spacing
        btnLock.x2 = startX + btnW - 1
        btnLock.y2 = btnLock.y1 + btnH - 1
    else
        local btnW = math.floor(mw * 0.7)
        if btnW < 15 then btnW = 15 end
        if btnW > mw - 4 then btnW = mw - 4 end

        local singleH = math.floor(mh * 0.5)
        if singleH < 5 then singleH = 5 end
        btnSingle.x1 = math.floor((mw - btnW) / 2) + 1
        btnSingle.y1 = math.floor((mh - singleH) / 2) + 2
        btnSingle.x2 = btnSingle.x1 + btnW - 1
        btnSingle.y2 = btnSingle.y1 + singleH - 1

        local spacing = 1
        if mh > 15 then spacing = 2 end
        
        local availableH = mh - 3
        local btnH = math.floor((availableH - spacing) / 2)
        if btnH < 3 then btnH = 3 end

        local totalH = (btnH * 2) + spacing
        local startY = math.floor((availableH - totalH) / 2) + 3
        if startY < 3 then startY = 3 end
        
        local startX = math.floor((mw - btnW) / 2) + 1

        btnAlarm.x1 = startX
        btnAlarm.y1 = startY
        btnAlarm.x2 = startX + btnW - 1
        btnAlarm.y2 = startY + btnH - 1

        btnLock.x1 = startX
        btnLock.y1 = startY + btnH + spacing
        btnLock.x2 = startX + btnW - 1
        btnLock.y2 = btnLock.y1 + btnH - 1
    end
end

-- ==================================
-- ZEICHNEN DER COMPUTER-ID IN DER ECKE
-- ==================================
local function drawID()
    local mw, _ = monitor.getSize()
    local idStr = "ID:" .. tostring(COMPUTER_ID)
    local startX = mw - #idStr + 1
    if startX < 1 then startX = 1 end
    
    monitor.setCursorPos(startX, 1)
    monitor.setTextColor(colors.lightGray)
    monitor.write(idStr)
end

-- ==================================
-- ERWEITERTES ZEICHNEN VON BUTTONS MIT SKALIERTEM TEXT
-- ==================================
local function drawButtonWithScaledText(x1, y1, x2, y2, bgCol, text)
    monitor.setBackgroundColor(bgCol)
    monitor.setTextColor(colors.white)
    
    local btnW = x2 - x1 + 1
    local btnH = y2 - y1 + 1
    local mw, mh = monitor.getSize()

    for y = y1, y2 do
        monitor.setCursorPos(x1, y)
        monitor.write(string.rep(" ", btnW))
    end

    local isLargeSquare = (mw > 26 or mh > 13) and (mw >= mh * 0.7 and mh >= mw * 0.7)

    if isLargeSquare and btnH >= 6 and #text <= btnW - 4 then
        local midY = y1 + math.floor(btnH / 2)
        local textX = x1 + math.floor((btnW - #text) / 2)
        monitor.setCursorPos(textX, midY - 1)
        monitor.write(text)
        monitor.setCursorPos(textX, midY)
        monitor.write(text)
    elseif btnH >= 5 and #text > btnW - 2 then
        local midY = y1 + math.floor(btnH / 2)
        local line1, line2 = text, ""
        local spacePos = text:find(" ")
        if spacePos and #text <= (btnW - 2) * 2 then
            line1 = text:sub(1, spacePos - 1)
            line2 = text:sub(spacePos + 1)
        end
        
        if line2 ~= "" then
            monitor.setCursorPos(x1 + math.floor((btnW - #line1) / 2), midY - 1)
            monitor.write(line1)
            monitor.setCursorPos(x1 + math.floor((btnW - #line2) / 2), midY)
            monitor.write(line2)
        else
            monitor.setCursorPos(x1 + math.floor((btnW - #text) / 2), midY)
            monitor.write(text)
        end
    else
        local midY = y1 + math.floor(btnH / 2)
        local textX = x1 + math.floor((btnW - #text) / 2)
        if textX < x1 then textX = x1 end
        monitor.setCursorPos(textX, midY)
        monitor.write(text)
    end
end

-- ==================================
-- HAUPT-ZEICHENFUNKTION FUER DAS GUI-LAYOUT
-- ==================================
local function draw()
    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    if updatingState then
        local label = customButtonText or "Updating..."
        drawButtonWithScaledText(btnSingle.x1, btnSingle.y1, btnSingle.x2, btnSingle.y2, colors.gray, label)

        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.yellow)
        monitor.setCursorPos(1, 1)
        monitor.write("STATUS:")
        monitor.setCursorPos(1, 2)
        monitor.write("WARTUNG")

    elseif lockdownState then
        drawButtonWithScaledText(btnSingle.x1, btnSingle.y1, btnSingle.x2, btnSingle.y2, colors.red, "VERRIEGELT")

        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.red)
        monitor.setCursorPos(1, 1)
        monitor.write("STATUS:")
        monitor.setCursorPos(1, 2)
        monitor.write("LOCKDOWN")

    elseif emergencyState then
        drawButtonWithScaledText(btnSingle.x1, btnSingle.y1, btnSingle.x2, btnSingle.y2, colors.red, "EMERGENCY")

        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.red)
        monitor.setCursorPos(1, 1)
        monitor.write("STATUS:")
        monitor.setCursorPos(1, 2)
        monitor.write("EMERGENCY")

    else
        drawButtonWithScaledText(btnAlarm.x1, btnAlarm.y1, btnAlarm.x2, btnAlarm.y2, colors.gray, "Alarm")
        drawButtonWithScaledText(btnLock.x1, btnLock.y1, btnLock.x2, btnLock.y2, colors.lightGray, "Verriegeln")

        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.green)
        monitor.setCursorPos(1, 1)
        monitor.write("STATUS:")
        monitor.setCursorPos(1, 2)
        monitor.write("ONLINE")
    end

    drawID()
end

-- ==================================
-- ZUSTANDSAENDERUNG: NOT-AUS
-- ==================================
local function setEmergencyState(newState, broadcast)
    if updatingState then return end
    if newState == emergencyState then return end

    emergencyState = newState
    draw()

    if broadcast then
        rednet.broadcast(
            emergencyState and MSG_ON or MSG_OFF,
            PROTOCOL
        )
    end
end

-- ==================================
-- ZUSTANDSAENDERUNG: LOCKDOWN
-- ==================================
local function setLockdownState(newState, broadcast)
    if updatingState then return end
    if newState == lockdownState then return end

    lockdownState = newState
    draw()

    if broadcast then
        rednet.broadcast(
            lockdownState and MSG_LOCK or MSG_UNLOCK,
            LOCKDOWN_PROTOCOL
        )
    end
end

-- ==================================
-- UPDATE-MECHANISMUS (GITHUB DOWNLOAD & INSTALLATION)
-- ==================================
local function applyUpdate()
    updatingState = true
    customButtonText = "Updating..."
    draw()

    local function fail(reportText)
        debug("Update fehlgeschlagen: " .. reportText)
        sendReport(false, reportText)
        if fs.exists(TEMP_FILE) then fs.delete(TEMP_FILE) end
        updatingState = false
        draw()
        return false
    end

    if not http then
        return fail("HTTP-API inaktiv")
    end

    debug("Lade Update von GitHub...")
    local url = GITHUB_URL .. "?cb=" .. string.format("%d", os.epoch("utc"))
    local response, httpErr, failResp = http.get(url)
    if not response then
        local why = tostring(httpErr)
        if failResp and failResp.getResponseCode then
            why = "HTTP " .. tostring(failResp.getResponseCode())
            pcall(failResp.close)
        end
        return fail("Download fehlgeschlagen (" .. why:sub(1, 24) .. ")")
    end

    local content = response.readAll()
    response.close()

    if not content or #content == 0 then
        return fail("Datei ist leer")
    end

    if content:match("^%s*<!DOCTYPE") or content:match("^%s*<[Hh][Tt][Mm][Ll]") then
        return fail("HTML statt Lua erhalten")
    end

    local tf = fs.open(TEMP_FILE, "w")
    if not tf then
        return fail("Temp-Datei nicht schreibbar")
    end
    tf.write(content)
    tf.close()

    local compiled, syntaxErr = loadfile(TEMP_FILE)
    fs.delete(TEMP_FILE)
    if not compiled then
        debug("Syntaxfehler im Update: " .. tostring(syntaxErr))
        return fail("Syntaxfehler im Code")
    end

    debug("Download und Syntaxpruefung erfolgreich.")

    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists("startup.lua") then
        pcall(fs.copy, "startup.lua", BACKUP_FILE)
    elseif fs.exists("startup") then
        pcall(fs.copy, "startup", BACKUP_FILE)
    end

    local newFile = fs.open("startup.lua", "w")
    if not newFile then
        return fail("Schreibfehler startup.lua")
    end
    newFile.write(content)
    newFile.close()

    if fs.exists("startup") then fs.delete("startup") end

    debug("Update installiert.")
    sendReport(true, "Update erfolgreich (GitHub)")

    customButtonText = "Neustart..."
    draw()

    sleep(2)
    os.reboot()
    return true
end

-- ==================================
-- EVENT- UND HAUPTSCHLEIFE DES PROGRAMMS
-- ==================================
local function main()
    computeButtons()
    draw()

    -- Beim Start sowohl Emergency- als auch Lockdown-Status abfragen
    rednet.broadcast(MSG_STATUS, PROTOCOL)
    rednet.broadcast(MSG_STATUS, LOCKDOWN_PROTOCOL)

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "monitor_touch" then
            if updatingState then goto continue end
            local side, x, y = p1, p2, p3

            if side == monitorName then
                if emergencyState or lockdownState then
                    if x >= btnSingle.x1 and x <= btnSingle.x2 and y >= btnSingle.y1 and y <= btnSingle.y2 then
                        if emergencyState then
                            setEmergencyState(false, true)
                        elseif lockdownState then
                            setLockdownState(false, true)
                        end
                    end
                else
                    if x >= btnAlarm.x1 and x <= btnAlarm.x2 and y >= btnAlarm.y1 and y <= btnAlarm.y2 then
                        setEmergencyState(true, true)
                    elseif x >= btnLock.x1 and x <= btnLock.x2 and y >= btnLock.y1 and y <= btnLock.y2 then
                        setLockdownState(true, true)
                    end
                end
            end

        elseif event == "monitor_resize" then
            computeButtons()
            draw()

        elseif event == "rednet_message" and not updatingState then
            local id, message, protocol = p1, p2, p3

            if protocol == PROTOCOL then
                if message == MSG_ON then
                    setEmergencyState(true, false)
                elseif message == MSG_OFF then
                    setEmergencyState(false, false)
                elseif message == MSG_STATUS then
                    rednet.send(id, emergencyState and MSG_ON or MSG_OFF, PROTOCOL)
                end
            elseif protocol == LOCKDOWN_PROTOCOL then
                if message == MSG_LOCK then
                    setLockdownState(true, false)
                elseif message == MSG_UNLOCK then
                    setLockdownState(false, false)
                elseif message == MSG_STATUS then
                    rednet.send(id, lockdownState and MSG_LOCK or MSG_UNLOCK, LOCKDOWN_PROTOCOL)
                end
            elseif protocol == UPDATE_PROTOCOL then
                if id == MASTER_ID and type(message) == "table" and message.action == "update" then
                    pcall(function() rednet.send(MASTER_ID, { action = "ping_ack" }, UPDATE_PROTOCOL) end)
                    applyUpdate(message.code)
                end
            end
        end
        ::continue::
    end
end

-- ==================================
-- SCHUTZ-WRAPPER FUER LAUFZEITFEHLER (SCHLEIFE MIT PAUSE)
-- ==================================
while true do
    local ok, err = pcall(main)
    if not ok then
        if err == "Terminated" then break end
        print("Fehler: " .. tostring(err))
        sleep(5)
    end
end