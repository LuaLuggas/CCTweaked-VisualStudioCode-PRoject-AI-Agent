-- ============================================================================
-- GITHUB INSTALLER & UPDATER (CC:Tweaked / ATM10 Bunker-System)
-- Benutzung:
--   update                 -> Oeffnet das interaktive Rollen-Auswahlmenue
--   update <Rolle/Nummer>  -> Installiert die Rolle direkt als /startup.lua
-- ============================================================================

local BASE_URL    = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/"
local TEMP_FILE   = "startup.update_tmp"
local BACKUP_FILE = "startup.backup"
local COMPUTER_ID = os.getComputerID()

local ROLES = {
    { key = "1", id = "MasterComputer",    title = "1: MasterComputer",    path = "programme/MasterComputer/startup.lua" },
    { key = "2", id = "EmergencyTerminal", title = "2: EmergencyTerminal", path = "programme/EmergencyTerminal/startup.lua" },
    { key = "3", id = "Tuersensor",        title = "3: Tuersensor",        path = "programme/Tuersensor/startup.lua" },
    { key = "4", id = "TextAnzeige",       title = "4: TextAnzeige",       path = "programme/TextAnzeige/startup.lua" },
    { key = "5", id = "GPSHost",           title = "5: GPSHost",           path = "programme/GPSHost/startup.lua" }
}

local buttons = {}
local statusText = "Rolle per Klick oder Taste 1-5 waehlen"
local statusCol  = colors.lightGray

local function fetchFile(repoPath)
    if not http then
        return nil, "HTTP-API ist deaktiviert"
    end
    local url = BASE_URL .. repoPath .. "?cb=" .. string.format("%d", os.epoch("utc"))
    local res, httpErr, failResp = http.get(url)
    if not res then
        local why = tostring(httpErr)
        if failResp and failResp.getResponseCode then
            why = "HTTP " .. tostring(failResp.getResponseCode())
            pcall(failResp.close)
        end
        return nil, why
    end
    local content = res.readAll()
    res.close()

    if not content or #content == 0 then
        return nil, "Heruntergeladene Datei ist leer"
    end
    if content:match("^%s*<!DOCTYPE") or content:match("^%s*<[Hh][Tt][Mm][Ll]") then
        return nil, "GitHub lieferte HTML statt Lua-Code"
    end
    return content
end

local function installRole(roleObj)
    statusText = "Lade " .. roleObj.id .. " von GitHub..."
    statusCol  = colors.yellow

    local content, err = fetchFile(roleObj.path)
    if not content then
        statusText = "Fehler: " .. tostring(err):sub(1, 32)
        statusCol  = colors.red
        return false
    end

    if fs.exists(TEMP_FILE) then fs.delete(TEMP_FILE) end
    local tf = fs.open(TEMP_FILE, "w")
    if not tf then
        statusText = "Fehler: Temp-Datei nicht schreibbar"
        statusCol  = colors.red
        return false
    end
    tf.write(content)
    tf.close()

    local compiled, syntaxErr = loadfile(TEMP_FILE)
    fs.delete(TEMP_FILE)
    if not compiled then
        statusText = "Syntaxfehler: " .. tostring(syntaxErr):sub(1, 28)
        statusCol  = colors.red
        return false
    end

    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    if fs.exists("startup.lua") then
        pcall(fs.copy, "startup.lua", BACKUP_FILE)
    elseif fs.exists("startup") then
        pcall(fs.copy, "startup", BACKUP_FILE)
    end

    local f = fs.open("startup.lua", "w")
    if not f then
        statusText = "Fehler: startup.lua nicht schreibbar"
        statusCol  = colors.red
        return false
    end
    f.write(content)
    f.close()

    if fs.exists("startup") then fs.delete("startup") end

    -- Optional: update.lua selbst im Hintergrund aktuell halten
    local selfCode = fetchFile("update.lua")
    if selfCode then
        local sf = fs.open("update.lua", "w")
        if sf then sf.write(selfCode); sf.close() end
    end

    statusText = roleObj.id .. " installiert! Starte neu..."
    statusCol  = colors.green
    return true
end

local function findRoleByArg(arg)
    if not arg then return nil end
    local clean = tostring(arg):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    for _, r in ipairs(ROLES) do
        if r.key == clean or r.id:lower() == clean then
            return r
        end
    end
    if clean == "master" then return ROLES[1]
    elseif clean == "terminal" or clean == "notaus" or clean == "emergency" then return ROLES[2]
    elseif clean == "tuer" or clean == "tuersensor" or clean == "doors" or clean == "door" then return ROLES[3]
    elseif clean == "anzeige" or clean == "textanzeige" or clean == "signs" or clean == "sign" then return ROLES[4]
    elseif clean == "gps" or clean == "gpshost" then return ROLES[5]
    end
    return nil
end

local function addButton(id, x, y, width, text, bgCol, textCol)
    bgCol   = bgCol or colors.gray
    textCol = textCol or colors.white
    term.setCursorPos(x, y)
    term.setBackgroundColor(bgCol)
    term.setTextColor(textCol)

    local cleanText = text:sub(1, width)
    local padL = math.floor((width - #cleanText) / 2)
    local padR = width - #cleanText - padL
    term.write(string.rep(" ", padL) .. cleanText .. string.rep(" ", padR))

    table.insert(buttons, { id = id, x1 = x, x2 = x + width - 1, y = y, text = cleanText })
end

local function drawMenu()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    buttons = {}

    -- Header im Bunker-Stil
    local title = "--- GITHUB INSTALLER ---"
    local startX = math.max(1, math.floor((w - #title) / 2) + 1)
    term.setCursorPos(startX, 2)
    term.setTextColor(colors.cyan)
    term.write(title:sub(1, w - 2))

    local idStr = "ID:" .. tostring(COMPUTER_ID)
    term.setCursorPos(math.max(1, w - #idStr), 1)
    term.setTextColor(colors.lightGray)
    term.write(idStr)

    local btnW = math.min(24, w - 2)
    local btnX = math.floor((w - btnW) / 2) + 1

    for i, r in ipairs(ROLES) do
        local y = 3 + (i * 2)
        addButton(r.key, btnX, y, btnW, r.title, colors.gray, colors.white)
    end

    local quitY = math.min(h - 2, 15)
    addButton("quit", btnX, quitY, btnW, "ABBRECHEN [Q]", colors.lightGray, colors.black)

    term.setBackgroundColor(colors.black)
    term.setTextColor(statusCol)
    local stText = statusText:sub(1, w - 2)
    term.setCursorPos(math.max(1, math.floor((w - #stText) / 2) + 1), h)
    term.write(stText)
end

-- 1. Direkt-Modus per Startargument (z. B. "update TextAnzeige" oder "update 4")
local args = { ... }
if args[1] then
    local roleObj = findRoleByArg(args[1])
    if not roleObj then
        printError("Unbekannte Rolle: " .. tostring(args[1]))
        print("Verfuegbar: MasterComputer, EmergencyTerminal, Tuersensor, TextAnzeige, GPSHost (oder 1-5)")
        return
    end
    print("Installiere Rolle: " .. roleObj.id .. " ...")
    if installRole(roleObj) then
        print(statusText)
        sleep(1.5)
        os.reboot()
    else
        printError(statusText)
    end
    return
end

-- 2. Interaktives Auswahlmenue im Bunker-Design
local function main()
    drawMenu()
    while true do
        local ev, p1, p2, p3 = os.pullEvent()

        if ev == "mouse_click" then
            local x, y = p2, p3
            local clicked = nil
            for _, b in ipairs(buttons) do
                if y == b.y and x >= b.x1 and x <= b.x2 then
                    clicked = b
                    break
                end
            end

            if clicked then
                -- Kurzes oranges Klick-Feedback
                local bw = clicked.x2 - clicked.x1 + 1
                local padL = math.floor((bw - #clicked.text) / 2)
                local padR = bw - #clicked.text - padL
                term.setCursorPos(clicked.x1, clicked.y)
                term.setBackgroundColor(colors.orange)
                term.setTextColor(colors.black)
                term.write(string.rep(" ", padL) .. clicked.text .. string.rep(" ", padR))
                sleep(0.15)

                if clicked.id == "quit" then
                    return
                end

                local roleObj = findRoleByArg(clicked.id)
                if roleObj then
                    drawMenu()
                    if installRole(roleObj) then
                        drawMenu()
                        sleep(1.5)
                        os.reboot()
                    else
                        drawMenu()
                    end
                end
            end

        elseif ev == "char" then
            if p1 == "q" or p1 == "Q" then
                return
            end
            local roleObj = findRoleByArg(p1)
            if roleObj then
                if installRole(roleObj) then
                    drawMenu()
                    sleep(1.5)
                    os.reboot()
                else
                    drawMenu()
                end
            end
        end
    end
end

local ok, err = pcall(main)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if not ok and not tostring(err):find("Terminated") then
    printError("Installer-Fehler: " .. tostring(err))
else
    print("Installer beendet.")
end
