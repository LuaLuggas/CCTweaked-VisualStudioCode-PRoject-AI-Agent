-- ============================================================================
-- BUNKER BROADCAST-HOST (ZENTRALER DURCHSAGE-SENDER FUER ATM10 / CC:TWEAKED)
-- ============================================================================
-- Sendet kontinuierlich YouTube-Audio-Streams (Durchsagen / Oberflaechen-Info)
-- an alle Bunker-Lautsprecher im Modus [ BROADCAST ].
-- WICHTIG: Der Broadcast-Host und Lautsprecher im Modus [ BROADCAST ] laufen
-- unabhaengig von Emergency / Lockdown ununterbrochen im Loop weiter!
-- ============================================================================

local dfpwm = require("cc.audio.dfpwm")

-- ==================================
-- KOMMENTAR: KONFIGURATION & PROTOKOLLE (UPVALUE-GEBUENDELT)
-- ==================================
local CFG = {
    MASTER_ID         = 24,
    PROTOCOL          = "notaus",
    LOCKDOWN_PROTOCOL = "lockdown",
    UPDATE_PROTOCOL   = "broadcast_update",
    CONFIG_PROTOCOL   = "broadcast_config",
    STREAM_PROTOCOL   = "bunker_broadcast_stream",

    MSG_ON            = "EMERGENCY_ON",
    MSG_OFF           = "EMERGENCY_OFF",
    MSG_LOCK          = "LOCKDOWN_ON",
    MSG_UNLOCK        = "LOCKDOWN_OFF",
    MSG_STATUS        = "STATUS_REQUEST",

    API_URL           = "https://ipod-2to6magyna-uc.a.run.app/",
    API_VERSION       = "2.1",
    GITHUB_URL        = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/programme/BroadcastHost/startup.lua",
    CONFIG_FILE       = "broadcast_host.cfg",
    TEMP_FILE         = "startup.update_tmp",
    BACKUP_FILE       = "startup.backup",

    CHUNK_SIZE        = 3000,    -- 3000 Bytes = 0.5s DFPWM Audio bei 48kHz
    LOG_TTL           = 4,
    MAX_LOG           = 2,
    COMPUTER_ID       = os.getComputerID()
}

-- ==================================
-- KOMMENTAR: ZUSTANDSTABELLE (UPVALUES BUNDELN)
-- ==================================
local state = {
    -- Playlist & Wiedergabe
    playlist          = {},
    curIdx            = 1,
    isPlaying         = true,
    curTitle          = "Kein Track",
    activeTargetId    = nil,
    selectedTrackIdx  = nil,
    scrollOffset      = 0,
    marqueeOffset     = 0,

    -- Studio-Lautsprecher
    volumePct         = 50,
    speakers          = {},
    decoder           = dfpwm.make_decoder(),
    pendingBuffer     = nil,

    -- Audio-Engine & HTTP-Streaming
    loadingUrl        = nil,
    streamHandle      = nil,
    isLoadingAudio    = false,
    audioError        = nil,

    -- Peripherie & Netzwerk
    modem             = nil,
    cachedPos         = "GPS n.verf.",
    updatingState     = false,

    -- Status & Logs
    lastUpdateTime    = "-",
    lastUpdateStat    = "noch keins",
    logs              = {},
    dirty             = true,

    -- Timer
    tickTimer         = nil,
    retryTimer        = nil
}

local hitboxes = {}

-- ==================================
-- KOMMENTAR: HILFSFUNKTIONEN & TITEL-VERARBEITUNG
-- ==================================
local function now()
    return os.epoch("utc") / 1000
end

local function pad(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
end

local function getMarqueeText(str, maxLen, offset)
    local s = tostring(str or "")
    if s == "" then return "" end
    if #s <= maxLen then
        return s .. string.rep(" ", maxLen - #s)
    end
    local spacer = "   ---   "
    local full = s .. spacer
    local fullLen = #full
    local startIdx = ((offset or 0) % fullLen) + 1
    local repeated = full .. full
    return repeated:sub(startIdx, startIdx + maxLen - 1)
end

state.cleanTitle = function(raw)
    local s = tostring(raw or "")
    s = s:gsub("\195\164", "ae"):gsub("\195\182", "oe"):gsub("\195\188", "ue")
    s = s:gsub("\195\132", "Ae"):gsub("\195\150", "Oe"):gsub("\195\156", "Ue"):gsub("\195\159", "ss")
    s = s:gsub("\226\128\147", "-"):gsub("\226\128\148", "-")
    s = s:gsub("[^\32-\126]", "")
    s = s:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

state.isBadTitle = function(t, id)
    local s = tostring(t or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or s == "Kein Video" then return true end
    if id and s == tostring(id) then return true end
    local low = s:lower()
    if low:find("help me keep") or low:find("hosting is expensive") or low:find("patreon") then return true end
    if low:find("http://") or low:find("https://") or low:find("youtu%.be") or low:find("youtube%.com") then return true end
    return false
end

local function extractYoutubeId(input)
    if type(input) ~= "string" then return "" end
    local s = input:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return "" end

    local patterns = {
        "[?&]v=([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])",
        "youtu%.be/([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])",
        "youtube%.com/shorts/([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])",
        "youtube%.com/embed/([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])",
        "^([%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-][%w_%-])$"
    }
    for _, pat in ipairs(patterns) do
        local id = s:match(pat)
        if id and #id == 11 then
            return id
        end
    end
    return ""
end

state.fetchVideoInfo = function(input)
    local trimmed = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return "", "" end
    local vid = extractYoutubeId(trimmed)

    if vid ~= "" and http then
        local oUrl = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=" .. vid .. "&format=json"
        local res = http.get(oUrl)
        if res then
            local body = res.readAll()
            res.close()
            local data = textutils.unserializeJSON(body)
            if type(data) == "table" and type(data.title) == "string" and #data.title > 0 then
                local clean = state.cleanTitle(data.title)
                if clean ~= "" then return vid, clean end
            end
        end
    end

    if http then
        local q = (vid ~= "") and vid or trimmed
        local sUrl = CFG.API_URL .. "?v=" .. CFG.API_VERSION .. "&search=" .. textutils.urlEncode(q)
        local res = http.get(sUrl)
        if res then
            local body = res.readAll()
            res.close()
            local list = textutils.unserializeJSON(body)
            if type(list) == "table" then
                for _, item in ipairs(list) do
                    if type(item) == "table" and type(item.id) == "string" and item.id ~= "9Se1cKmJ_Ik" then
                        local nameClean = state.cleanTitle(item.name)
                        if not state.isBadTitle(nameClean, item.id) then
                            if vid == "" or item.id == vid then
                                return item.id, nameClean
                            end
                        end
                    end
                end
            end
        end
    end

    if vid ~= "" then
        return vid, "YouTube-Video"
    end
    return "", ""
end

local function addLog(text)
    local w = term.getSize()
    local maxW = math.max(1, w - 2)
    table.insert(state.logs, { text = tostring(text):sub(1, maxW), expires = now() + CFG.LOG_TTL })
    while #state.logs > CFG.MAX_LOG do
        table.remove(state.logs, 1)
    end
    state.dirty = true
end

-- ==================================
-- KOMMENTAR: KONFIGURATION & MASTER-REPORTING
-- ==================================
local function saveConfig()
    local f = fs.open(CFG.CONFIG_FILE, "w")
    if not f then return false end
    f.write(textutils.serialize({
        playlist       = state.playlist,
        curIdx         = state.curIdx,
        isPlaying      = state.isPlaying,
        volumePct      = state.volumePct,
        lastUpdateTime = state.lastUpdateTime,
        lastUpdateStat = state.lastUpdateStat
    }))
    f.close()
    return true
end

local function loadConfig()
    if fs.exists(CFG.CONFIG_FILE) then
        local f = fs.open(CFG.CONFIG_FILE, "r")
        if f then
            local data = textutils.unserialize(f.readAll())
            f.close()
            if type(data) == "table" then
                if type(data.playlist) == "table" then
                    state.playlist = {}
                    for _, t in ipairs(data.playlist) do
                        if type(t) == "table" and t.id then
                            table.insert(state.playlist, { id = tostring(t.id), title = state.cleanTitle(t.title or "YouTube-Video") })
                        end
                    end
                end
                if type(data.curIdx) == "number" then state.curIdx = math.max(1, data.curIdx) end
                if type(data.isPlaying) == "boolean" then state.isPlaying = data.isPlaying end
                if type(data.volumePct) == "number" then state.volumePct = math.max(0, math.min(100, data.volumePct)) end
                if type(data.lastUpdateTime) == "string" then state.lastUpdateTime = data.lastUpdateTime end
                if type(data.lastUpdateStat) == "string" then state.lastUpdateStat = data.lastUpdateStat end
                return true
            end
        end
    end
    return false
end

local function refreshGpsCache()
    if not state.modem then
        state.cachedPos = "GPS n.verf."
        return
    end
    local x, y, z = gps.locate(1.5)
    if x and y and z then
        state.cachedPos = string.format("%.0f, %.0f, %.0f", x, y, z)
    end
end

local function getPreviewString()
    local status = state.isPlaying and "ON AIR" or "PAUSIERT"
    local tName = (state.curTitle ~= "" and state.curTitle ~= "Kein Track") and state.curTitle or "Kein Track"
    return status .. " (" .. tName:sub(1, 16) .. ")"
end

local function sendReport(success, details)
    if not state.modem then return end
    local label = os.getComputerLabel() or ("BroadcastHost " .. tostring(CFG.COMPUTER_ID))
    local preview = getPreviewString()
    pcall(function()
        rednet.send(CFG.MASTER_ID, {
            action  = "log_report",
            success = success,
            details = details or ("Online: " .. preview),
            pos     = state.cachedPos,
            label   = label,
            preview = preview,
            devType = "broadcast"
        }, CFG.UPDATE_PROTOCOL)
    end)
end

-- ==================================
-- KOMMENTAR: AUDIO-ENGINE & STREAM-BROADCAST (UNABHAENGIG VON ALARM!)
-- ==================================
local function closeStreamHandle()
    if state.streamHandle then
        pcall(state.streamHandle.close)
        state.streamHandle = nil
    end
end

local function stopPlayback()
    closeStreamHandle()
    state.pendingBuffer  = nil
    state.activeTargetId = nil
    state.loadingUrl     = nil
    state.isLoadingAudio = false
    for _, spk in ipairs(state.speakers) do
        pcall(spk.stop)
    end
    state.dirty = true
end

local function getCurrentTrack()
    if #state.playlist == 0 then return nil end
    local idx = math.max(1, math.min(#state.playlist, state.curIdx or 1))
    return state.playlist[idx], idx
end

local function requestAudioStream(videoId)
    closeStreamHandle()
    state.pendingBuffer = nil

    if not http then
        state.audioError = "HTTP inaktiv"
        state.dirty = true
        return
    end

    local url = CFG.API_URL .. "?v=" .. CFG.API_VERSION .. "&id=" .. textutils.urlEncode(videoId)
    state.loadingUrl     = url
    state.isLoadingAudio = true
    state.audioError     = nil
    state.dirty          = true
    http.request({ url = url, binary = true })
end

local function advanceToNextTrack()
    if #state.playlist == 0 then
        stopPlayback()
        state.curTitle = "Kein Track"
        state.dirty    = true
        return
    end
    state.curIdx = (state.curIdx % #state.playlist) + 1
    saveConfig()
    local trk = state.playlist[state.curIdx]
    if trk and trk.id then
        state.activeTargetId = trk.id
        state.curTitle       = (trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "YouTube-Video"
        requestAudioStream(trk.id)
    else
        stopPlayback()
    end
    state.dirty = true
end

local function pushChunkToStudioSpeakers(chunk)
    if #state.speakers == 0 then return true end
    local vol = (state.volumePct / 100) * 3.0
    if vol <= 0.001 then return true end
    local pcm = state.decoder(chunk)
    local allAccepted = true
    for _, spk in ipairs(state.speakers) do
        local ok, accepted = pcall(spk.playAudio, pcm, vol)
        if ok and not accepted then
            allAccepted = false
        end
    end
    return allAccepted
end

local function feedNextStreamChunk()
    if not state.isPlaying or state.isLoadingAudio then return end
    local trk = getCurrentTrack()
    if not trk or trk.id ~= state.activeTargetId then return end

    if state.streamHandle then
        local chunk = state.streamHandle.read(CFG.CHUNK_SIZE)
        if chunk and #chunk > 0 then
            -- 1. Per Rednet an alle Lautsprecher im Modus [ BROADCAST ] senden
            if state.modem then
                rednet.broadcast({
                    action     = "broadcast_chunk",
                    chunk      = chunk,
                    trackIdx   = state.curIdx,
                    trackTitle = state.curTitle
                }, CFG.STREAM_PROTOCOL)
            end

            -- 2. Auf lokalen Studio-Lautsprechern abspielen (falls vorhanden)
            if #state.speakers > 0 then
                if not pushChunkToStudioSpeakers(chunk) then
                    return
                else
                    os.queueEvent("broadcast_feed")
                end
            else
                -- Keine Studio-Speaker angeschlossen: Gleichmaessiger Sendetakt via Timer (3000 Bytes = 0.5s Audio)
                state.paceTimer = os.startTimer(0.48)
            end
        else
            -- Track zu Ende -> Naechsten Track starten
            closeStreamHandle()
            advanceToNextTrack()
        end
    end
end

local function syncPlaybackEngine()
    if not state.isPlaying or #state.playlist == 0 then
        if state.activeTargetId or state.streamHandle then
            stopPlayback()
        end
        return
    end

    local trk, idx = getCurrentTrack()
    if not trk or not trk.id then
        stopPlayback()
        return
    end

    state.curTitle = (trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "YouTube-Video"

    if state.activeTargetId ~= trk.id then
        stopPlayback()
        state.activeTargetId = trk.id
        requestAudioStream(trk.id)
    elseif not state.isLoadingAudio and not state.streamHandle then
        requestAudioStream(trk.id)
    end
end

-- ==================================
-- KOMMENTAR: TERMINAL UI (51x19 ADVANCED COMPUTER)
-- ==================================
local function drawUI()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()

    hitboxes = {}

    -- 1. Kopfzeile
    term.setCursorPos(2, 1)
    term.setTextColor(colors.magenta)
    term.write("--- BUNKER BROADCAST HOST ---")
    local idStr = "ID:" .. tostring(CFG.COMPUTER_ID)
    term.setCursorPos(math.max(1, w - #idStr), 1)
    term.setTextColor(colors.lightGray)
    term.write(idStr)

    -- 2. Status-Pill (ON AIR / PAUSIERT) & Speaker-Info
    term.setCursorPos(2, 2)
    if state.isPlaying and #state.playlist > 0 then
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" [ ON AIR ] ")
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" [ PAUSIERT ] ")
    end
    hitboxes.toggleAirBtn = { x1 = 2, x2 = 15, y = 2 }

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    local spkInfo = string.format(" Studio: %d Speaker (24/7 Loop)", #state.speakers)
    term.write(spkInfo)

    -- 3. Aktueller Track-Titel (Marquee-Laufschrift)
    term.setCursorPos(2, 4)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.cyan)
    term.write("Aktuelle Durchsage / Track:")

    term.setCursorPos(2, 5)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    local dispTitle = (state.curTitle ~= "" and state.curTitle ~= "Kein Track") and state.curTitle or "Keine Wiedergabe aktiv"
    local marquee = getMarqueeText(dispTitle, w - 4, state.marqueeOffset)
    term.write(" " .. pad(marquee, w - 4) .. " ")

    -- 4. Steuerung & Track hinzufuegen (Zeile 7)
    local btnY = 7
    term.setCursorPos(2, btnY)
    term.setBackgroundColor(state.isPlaying and colors.orange or colors.green)
    term.setTextColor(colors.black)
    local playLabel = state.isPlaying and " [ PAUSE ] " or " [ PLAY ] "
    term.write(playLabel)
    hitboxes.playBtn = { x1 = 2, x2 = 2 + #playLabel - 1, y = btnY }

    local skipX = 2 + #playLabel + 2
    term.setCursorPos(skipX, btnY)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(" [ >> SKIP ] ")
    hitboxes.skipBtn = { x1 = skipX, x2 = skipX + 12, y = btnY }

    local addX = w - 17
    term.setCursorPos(addX, btnY)
    term.setBackgroundColor(colors.green)
    term.setTextColor(colors.black)
    term.write(" [+] TRACK HINZU ")
    hitboxes.addBtn = { x1 = addX, x2 = addX + 16, y = btnY }

    -- 5. Playlist-Tabelle (Zeilen 9 bis 13)
    term.setCursorPos(2, 9)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.magenta)
    term.write(string.format("PLAYLIST (%d Tracks):", #state.playlist))

    local maxVis = 4
    local startIdx = (state.scrollOffset or 0) + 1
    local endIdx = math.min(#state.playlist, startIdx + maxVis - 1)

    if #state.playlist > maxVis then
        if (state.scrollOffset or 0) > 0 then
            term.setCursorPos(w - 5, 9)
            term.setBackgroundColor(colors.lightGray)
            term.setTextColor(colors.black)
            term.write(" ^ ")
            hitboxes.scrollUp = { x1 = w - 5, x2 = w - 3, y = 9 }
        end
        if endIdx < #state.playlist then
            term.setCursorPos(w - 2, 9)
            term.setBackgroundColor(colors.lightGray)
            term.setTextColor(colors.black)
            term.write(" v ")
            hitboxes.scrollDn = { x1 = w - 2, x2 = w, y = 9 }
        end
    end

    local listY = 10
    for i = startIdx, endIdx do
        local trk = state.playlist[i]
        local isCur = (state.curIdx == i and state.isPlaying)
        local isSel = (state.selectedTrackIdx == i)

        term.setCursorPos(2, listY)
        local bg = isSel and colors.cyan or (isCur and colors.blue or colors.gray)
        local fg = (isSel or isCur) and colors.black or colors.white
        term.setBackgroundColor(bg)
        term.setTextColor(fg)

        local prefix = isCur and "> " or string.format("%d. ", i)
        local tName  = (trk.title and not state.isBadTitle(trk.title, trk.id)) and trk.title or "YouTube-Video"
        local rowStr = getMarqueeText(prefix .. tName, w - 4, isSel and state.marqueeOffset or 0)
        term.write(" " .. pad(rowStr, w - 4) .. " ")

        hitboxes["track_" .. i] = { x1 = 2, x2 = w - 2, y = listY, idx = i }
        listY = listY + 1
    end

    if #state.playlist == 0 then
        term.setCursorPos(2, 10)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        term.write("Keine Tracks in der Playlist. Klicke auf [+] TRACK HINZU.")
    end

    -- 6. Track-Aktionen (Zeile 14)
    local actY = 14
    if state.selectedTrackIdx and state.playlist[state.selectedTrackIdx] then
        term.setCursorPos(2, actY)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" [^ HOCH] ")
        hitboxes.moveUp = { x1 = 2, x2 = 11, y = actY }

        term.setCursorPos(13, actY)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" [v RUNTER] ")
        hitboxes.moveDn = { x1 = 13, x2 = 24, y = actY }

        term.setCursorPos(26, actY)
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write(" [X LOESCHEN] ")
        hitboxes.delTrack = { x1 = 26, x2 = 39, y = actY }
    else
        term.setCursorPos(2, actY)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.gray)
        term.write("[ Track in der Liste anklicken zum Sortieren/Loeschen ]")
    end

    -- 7. Studio-Lautstaerke Slider (Zeile 15)
    local volY = 15
    term.setCursorPos(2, volY)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write(pad(string.format("Studio-Lautst.: %3d%%", state.volumePct), 20))

    local barX = 24
    local bW   = math.max(6, w - barX - 6)
    term.setCursorPos(barX, volY)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(" < ")

    local knobPos = math.floor((state.volumePct / 100) * (bW - 1) + 0.5) + 1
    knobPos = math.max(1, math.min(bW, knobPos))

    for i = 1, bW do
        term.setCursorPos(barX + 2 + i, volY)
        if i == knobPos then
            term.setBackgroundColor(colors.orange)
            term.setTextColor(colors.black)
            term.write("O")
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.lightGray)
            term.write("-")
        end
    end

    term.setCursorPos(barX + 3 + bW, volY)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(" > ")

    hitboxes.volDec = { x1 = barX, x2 = barX + 2, y = volY }
    hitboxes.volBar = { x1 = barX + 3, x2 = barX + 2 + bW, y = volY, width = bW }
    hitboxes.volInc = { x1 = barX + 3 + bW, x2 = barX + 5 + bW, y = volY }

    -- 8. Master-Sync-Info & Logs (Zeilen 17–19)
    term.setCursorPos(2, 17)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    local updInfo = string.format("Master-Sync: [%s] | Update: [%s]", tostring(state.cachedPos), tostring(state.lastUpdateTime))
    term.write(updInfo:sub(1, w - 2))

    local startRow = h - #state.logs + 1
    term.setTextColor(colors.gray)
    for i, entry in ipairs(state.logs) do
        term.setCursorPos(2, startRow + i - 1)
        term.write(pad(entry.text, w - 2))
    end
end

-- ==================================
-- KOMMENTAR: INTERAKTIVE EINGABEN & AKTIONEN
-- ==================================
local function editInput(prompt)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(2, 2)
    term.write(prompt)
    term.setCursorPos(2, 4)
    term.write("> ")
    term.setCursorBlink(true)
    local input = read()
    term.setCursorBlink(false)
    if input and #input > 0 then
        return input:gsub("^%s+", ""):gsub("%s+$", "")
    end
    return nil
end

local function applyUpdate()
    state.updatingState = true
    stopPlayback()
    addLog("Lade Update von GitHub...")
    drawUI()

    local function failUpdate(reason)
        state.lastUpdateTime = os.date("%H:%M:%S")
        state.lastUpdateStat = "fehlgeschlagen"
        state.updatingState  = false
        saveConfig()
        sendReport(false, reason)
        addLog("Update fehlgeschlagen: " .. reason)
        drawUI()
        return false
    end

    if not http then return failUpdate("HTTP inaktiv") end

    local url = CFG.GITHUB_URL .. "?cb=" .. string.format("%d", os.epoch("utc"))
    local res, httpErr, failResp = http.get(url)
    if not res then
        local why = tostring(httpErr)
        if failResp and failResp.getResponseCode then
            why = "HTTP " .. tostring(failResp.getResponseCode())
            pcall(failResp.close)
        end
        return failUpdate("Download (" .. why:sub(1, 20) .. ")")
    end

    local content = res.readAll()
    res.close()
    if not content or #content == 0 then return failUpdate("Datei leer") end
    if content:match("^%s*<!DOCTYPE") or content:match("^%s*<[Hh][Tt][Mm][Ll]") then
        return failUpdate("HTML statt Code erhalten")
    end

    local tf = fs.open(CFG.TEMP_FILE, "w")
    if not tf then return failUpdate("Schreibfehler Temp") end
    tf.write(content)
    tf.close()

    local compiled = loadfile(CFG.TEMP_FILE)
    fs.delete(CFG.TEMP_FILE)
    if not compiled then return failUpdate("Syntaxfehler im Code") end

    if fs.exists(CFG.BACKUP_FILE) then fs.delete(CFG.BACKUP_FILE) end
    if fs.exists("startup.lua") then
        pcall(fs.copy, "startup.lua", CFG.BACKUP_FILE)
    elseif fs.exists("startup") then
        pcall(fs.copy, "startup", CFG.BACKUP_FILE)
    end

    local f = fs.open("startup.lua", "w")
    if not f then return failUpdate("Schreibfehler startup.lua") end
    f.write(content)
    f.close()

    if fs.exists("startup") then fs.delete("startup") end

    state.lastUpdateTime = os.date("%H:%M:%S")
    state.lastUpdateStat = "erfolgreich"
    saveConfig()
    sendReport(true, "Update erfolgreich (GitHub)")
    addLog("Update installiert! Neustart...")
    drawUI()
    sleep(2)
    os.reboot()
end

local function setupPeripherals()
    state.speakers = { peripheral.find("speaker") }
    state.modem    = peripheral.find("modem")

    if state.modem then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" then
                pcall(rednet.open, name)
            end
        end
    end
    state.dirty = true
end

-- ==================================
-- KOMMENTAR: HAUPTSCHLEIFE (EVENTS)
-- ==================================
local function main()
    setupPeripherals()
    if state.modem then
        refreshGpsCache()
        pcall(function()
            rednet.send(CFG.MASTER_ID, { action = "request_broadcast_sync" }, CFG.CONFIG_PROTOCOL)
        end)
        sendReport(true)
    end

    state.tickTimer = os.startTimer(0.5)
    syncPlaybackEngine()

    while true do
        if state.dirty then
            drawUI()
            state.dirty = false
        end

        local ev, p1, p2, p3 = os.pullEvent()

        -- 1. Audio-Feeding fuer Stream & Studio-Lautsprecher
        if ev == "broadcast_feed" or ev == "speaker_audio_empty" then
            feedNextStreamChunk()

        -- 2. HTTP-Antworten fuer Stream-Download
        elseif ev == "http_success" then
            local url, handle = p1, p2
            if url == state.loadingUrl then
                state.loadingUrl     = nil
                state.isLoadingAudio = false
                state.streamHandle   = handle
                state.decoder        = dfpwm.make_decoder()
                state.dirty          = true
                feedNextStreamChunk()
            else
                pcall(handle.close)
            end

        elseif ev == "http_failure" then
            local url = p1
            if url == state.loadingUrl then
                state.loadingUrl     = nil
                state.isLoadingAudio = false
                state.audioError     = "Stream-Fehler"
                addLog("Stream fehlgeschlagen! Naechster Track in 3s...")
                state.retryTimer     = os.startTimer(3.0)
                state.dirty          = true
            end

        -- 3. Mausklicks & Lautstaerke-Slider
        elseif (ev == "mouse_click" or ev == "mouse_drag") and not state.updatingState then
            local x, y = p2, p3
            local handled = false

            if hitboxes.volBar and y == hitboxes.volBar.y and x >= hitboxes.volBar.x1 and x <= hitboxes.volBar.x2 then
                local rel = (x - hitboxes.volBar.x1) / math.max(1, hitboxes.volBar.width - 1)
                state.volumePct = math.max(0, math.min(100, math.floor((rel * 20) + 0.5) * 5))
                saveConfig()
                state.dirty = true
                handled = true
            elseif ev == "mouse_click" and hitboxes.volDec and y == hitboxes.volDec.y and x >= hitboxes.volDec.x1 and x <= hitboxes.volDec.x2 then
                state.volumePct = math.max(0, state.volumePct - 5)
                saveConfig()
                state.dirty = true
                handled = true
            elseif ev == "mouse_click" and hitboxes.volInc and y == hitboxes.volInc.y and x >= hitboxes.volInc.x1 and x <= hitboxes.volInc.x2 then
                state.volumePct = math.min(100, state.volumePct + 5)
                saveConfig()
                state.dirty = true
                handled = true
            end

            if ev == "mouse_click" and not handled then
                if hitboxes.toggleAirBtn and y == hitboxes.toggleAirBtn.y and x >= hitboxes.toggleAirBtn.x1 and x <= hitboxes.toggleAirBtn.x2 then
                    state.isPlaying = not state.isPlaying
                    saveConfig()
                    syncPlaybackEngine()
                    sendReport(true)
                    state.dirty = true
                elseif hitboxes.playBtn and y == hitboxes.playBtn.y and x >= hitboxes.playBtn.x1 and x <= hitboxes.playBtn.x2 then
                    state.isPlaying = not state.isPlaying
                    saveConfig()
                    syncPlaybackEngine()
                    sendReport(true)
                    state.dirty = true
                elseif hitboxes.skipBtn and y == hitboxes.skipBtn.y and x >= hitboxes.skipBtn.x1 and x <= hitboxes.skipBtn.x2 then
                    advanceToNextTrack()
                    sendReport(true)
                elseif hitboxes.addBtn and y == hitboxes.addBtn.y and x >= hitboxes.addBtn.x1 and x <= hitboxes.addBtn.x2 then
                    local input = editInput("YouTube-Link / ID einfuegen:")
                    if input and #input > 0 then
                        addLog("Lade Videotitel...")
                        drawUI()
                        local vid, title = state.fetchVideoInfo(input)
                        if vid ~= "" then
                            table.insert(state.playlist, { id = vid, title = title })
                            state.selectedTrackIdx = #state.playlist
                            saveConfig()
                            addLog("Track zugefuegt: " .. title:sub(1, 20))
                            if not state.activeTargetId then
                                syncPlaybackEngine()
                            end
                        else
                            addLog("Fehler: Kein Video gefunden!")
                        end
                    end
                    state.dirty = true
                elseif hitboxes.moveUp and y == hitboxes.moveUp.y and x >= hitboxes.moveUp.x1 and x <= hitboxes.moveUp.x2 then
                    local sel = state.selectedTrackIdx
                    if sel and sel > 1 then
                        local tmp = state.playlist[sel]
                        state.playlist[sel] = state.playlist[sel - 1]
                        state.playlist[sel - 1] = tmp
                        state.selectedTrackIdx = sel - 1
                        saveConfig()
                        state.dirty = true
                    end
                elseif hitboxes.moveDn and y == hitboxes.moveDn.y and x >= hitboxes.moveDn.x1 and x <= hitboxes.moveDn.x2 then
                    local sel = state.selectedTrackIdx
                    if sel and sel < #state.playlist then
                        local tmp = state.playlist[sel]
                        state.playlist[sel] = state.playlist[sel + 1]
                        state.playlist[sel + 1] = tmp
                        state.selectedTrackIdx = sel + 1
                        saveConfig()
                        state.dirty = true
                    end
                elseif hitboxes.delTrack and y == hitboxes.delTrack.y and x >= hitboxes.delTrack.x1 and x <= hitboxes.delTrack.x2 then
                    local sel = state.selectedTrackIdx
                    if sel and state.playlist[sel] then
                        table.remove(state.playlist, sel)
                        state.selectedTrackIdx = nil
                        saveConfig()
                        if state.curIdx > #state.playlist then
                            state.curIdx = 1
                        end
                        syncPlaybackEngine()
                        state.dirty = true
                    end
                elseif hitboxes.scrollUp and y == hitboxes.scrollUp.y and x >= hitboxes.scrollUp.x1 and x <= hitboxes.scrollUp.x2 then
                    state.scrollOffset = math.max(0, (state.scrollOffset or 0) - 1)
                    state.dirty = true
                elseif hitboxes.scrollDn and y == hitboxes.scrollDn.y and x >= hitboxes.scrollDn.x1 and x <= hitboxes.scrollDn.x2 then
                    local maxOff = math.max(0, #state.playlist - 4)
                    state.scrollOffset = math.min(maxOff, (state.scrollOffset or 0) + 1)
                    state.dirty = true
                else
                    -- Pruefen, ob ein Track in der Liste angeklickt wurde
                    local clickedTrack = false
                    for k, hb in pairs(hitboxes) do
                        if k:match("^track_") and y == hb.y and x >= hb.x1 and x <= hb.x2 then
                            if state.selectedTrackIdx == hb.idx then
                                state.selectedTrackIdx = nil
                            else
                                state.selectedTrackIdx = hb.idx
                            end
                            clickedTrack = true
                            state.dirty = true
                            break
                        end
                    end
                    if not clickedTrack then
                        state.selectedTrackIdx = nil
                        state.dirty = true
                    end
                end
            end

        -- 4. Rednet-Nachrichten (Master-Steuerung, Sync & Remote-Update)
        -- HINWEIS: Emergency / Lockdown wird im BroadcastHost absichtlich ignoriert!
        elseif ev == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3

            if protocol == CFG.CONFIG_PROTOCOL and not state.updatingState then
                if message == CFG.MSG_STATUS then
                    sendReport(true)
                elseif type(message) == "table" then
                    if message.action == "set_broadcast_playlist" and type(message.playlist) == "table" then
                        state.playlist = {}
                        for _, t in ipairs(message.playlist) do
                            if type(t) == "table" and t.id then
                                table.insert(state.playlist, { id = tostring(t.id), title = state.cleanTitle(t.title or "YouTube-Video") })
                            end
                        end
                        state.curIdx = 1
                        saveConfig()
                        addLog("Playlist aktualisiert (" .. tostring(#state.playlist) .. " Tracks)")
                        syncPlaybackEngine()
                        sendReport(true)
                        state.dirty = true
                    elseif message.action == "play" then
                        state.isPlaying = true
                        saveConfig()
                        syncPlaybackEngine()
                        sendReport(true)
                        state.dirty = true
                    elseif message.action == "stop" then
                        state.isPlaying = false
                        saveConfig()
                        stopPlayback()
                        sendReport(true)
                        state.dirty = true
                    elseif message.action == "skip" then
                        advanceToNextTrack()
                        sendReport(true)
                    elseif message.action == "request_broadcast_sync" then
                        rednet.send(senderId, {
                            action     = "set_broadcast_playlist",
                            playlist   = state.playlist,
                            curIdx     = state.curIdx,
                            isPlaying  = state.isPlaying,
                            isReply    = true
                        }, CFG.CONFIG_PROTOCOL)
                    end
                end

            elseif protocol == CFG.UPDATE_PROTOCOL then
                if message == CFG.MSG_STATUS then
                    sendReport(true)
                elseif senderId == CFG.MASTER_ID and type(message) == "table" and message.action == "update" then
                    pcall(function() rednet.send(CFG.MASTER_ID, { action = "ping_ack" }, CFG.UPDATE_PROTOCOL) end)
                    applyUpdate()
                    state.tickTimer = os.startTimer(0.5)
                end
            end

        -- 5. Timer fuer Logs & Lauftext
        elseif ev == "timer" then
            if p1 == state.tickTimer then
                state.tickTimer = os.startTimer(0.5)
                state.marqueeOffset = (state.marqueeOffset or 0) + 1
                state.dirty = true
                local t = now()
                for i = #state.logs, 1, -1 do
                    if state.logs[i].expires <= t then
                        table.remove(state.logs, i)
                    end
                end
            elseif p1 == state.retryTimer then
                state.retryTimer = nil
                advanceToNextTrack()
            elseif p1 == state.paceTimer then
                state.paceTimer = nil
                feedNextStreamChunk()
            end

        elseif ev == "peripheral" or ev == "peripheral_detach" then
            setupPeripherals()
            state.dirty = true
        end
    end
end

-- ==================================
-- KOMMENTAR: PROGRAMMSTART & FEHLERSCHUTZ
-- ==================================
loadConfig()
setupPeripherals()

while true do
    local ok, err = pcall(main)
    if not ok then
        stopPlayback()
        if tostring(err):find("Terminated") then
            term.setCursorBlink(false)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
            term.setCursorPos(1, 1)
            print("BroadcastHost beendet.")
            return
        end
        addLog("Fehler: " .. tostring(err))
        sleep(2)
    end
end
