-- ============================================================================
-- KOMMENTAR: BUNKER LAUTSPRECHER & ALARM-AUDIO SYSTEM (CC:Tweaked / ATM10)
-- Streamt YouTube-Audio (auch nicht-gelistete Videos) im DFPWM-Format ueber
-- angeschlossene Speaker. Unterstuetzt Dauer-Loop, Redstone-, Spieler- und
-- Funk-Trigger sowie globale Emergency- & Lockdown-Alarme vom MasterComputer.
-- (Upvalue-optimiert fuer das Lua 5.1 Limit von max. 60 Upvalues)
-- ============================================================================

local dfpwm = require("cc.audio.dfpwm")

local CFG = {
    PROTOCOL          = "notaus",
    LOCKDOWN_PROTOCOL = "lockdown",
    UPDATE_PROTOCOL   = "speaker_update",
    CONFIG_PROTOCOL   = "speaker_config",
    TRIGGER_PROTOCOL  = "speaker_trigger",

    CONFIG_FILE = "speaker_config.txt",
    TEMP_FILE   = "startup.update_tmp",
    BACKUP_FILE = "startup.backup",
    GITHUB_URL  = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/programme/Lautsprecher/startup.lua",
    API_URL     = "https://ipod-2to6magyna-uc.a.run.app/",
    API_VERSION = "2.1",

    MASTER_ID   = 24,
    COMPUTER_ID = os.getComputerID(),

    MSG_ON     = "EMERGENCY_ON",
    MSG_OFF    = "EMERGENCY_OFF",
    MSG_LOCK   = "LOCKDOWN_ON",
    MSG_UNLOCK = "LOCKDOWN_OFF",
    MSG_STATUS = "STATUS_REQUEST",

    MODES = { "MANUELL", "REDSTONE", "SPIELER", "FUNK" },

    -- Bis zu 24 Chunks (~384 KB) im RAM cachen fuer nahtlosen Loop ohne Nachladen
    MAX_CACHE_CHUNKS = 24,
    CHUNK_SIZE       = 16 * 1024,

    MAX_LOG = 2,
    LOG_TTL = 5
}

-- ==================================
-- KOMMENTAR: ZUSTANDS-TABELLE (BUNDELT UPVALUES FUER LUA 5.1)
-- ==================================
local state = {
    -- Gespeicherte lokale Einstellungen
    localUrl        = "",
    localVideoId    = "",
    localTitle      = "Kein Video",
    volumePct       = 50,     -- 0 bis 100 (100% = 3.0 in CC:Tweaked)
    loopEnabled     = true,
    triggerMode     = 1,      -- 1=MANUELL, 2=REDSTONE, 3=SPIELER, 4=FUNK
    sensorRange     = 5,
    userPlaying     = false,  -- Ob im manuellen Modus Play aktiv war

    -- Vom Master synchronisierte Alarm-Einstellungen
    emergencyUrl    = "",
    emergencyId     = "",
    lockdownUrl     = "",
    lockdownId      = "",
    alarmVolumePct  = 100,

    -- Update-Historie
    lastUpdateTime  = "-",
    lastUpdateStat  = "noch keins",

    -- UI-Eingabefeld
    fieldUrl        = "",
    focusUrl        = false,
    freshFocus      = false,

    -- Laufzeit-Zustaende
    emergencyActive = false,
    lockdownActive  = false,
    updatingState   = false,
    rsTriggered     = false,
    playerTriggered = false,
    remoteTriggered = false,

    -- Audio-Engine & HTTP-Streaming
    speakers        = {},
    modem           = nil,
    detector        = nil,
    decoder         = dfpwm.make_decoder(),
    activeTargetId  = nil,    -- Aktuell abgespielte 11-stellige YouTube-ID
    loadingUrl      = nil,    -- Aktuell laufender HTTP-Stream-Request
    searchUrl       = nil,    -- Aktuell laufender HTTP-Such-Request
    searchTarget    = nil,    -- "local" | "emergency" | "lockdown"
    streamHandle    = nil,
    streamFirstChunk = false,
    pendingBuffer   = nil,
    isLoadingAudio  = false,
    audioError      = nil,

    -- RAM-Cache fuer kurzen/mittellangen Loop-Sound (verhindert Lade-Pause beim Loop)
    cacheId         = nil,
    cacheChunks     = {},
    cacheComplete   = false,
    cacheReadIdx    = 1,

    cachedPos       = "GPS n.verf.",
    logs            = {},
    dirty           = true,

    tickTimer       = nil,
    sensorTimer     = nil,
    retryTimer      = nil
}

local hitboxes = {
    urlField   = nil,
    clearBtn   = nil,
    saveUrlBtn = nil,
    playBtn    = nil,
    loopBtn    = nil,
    modeBtn    = nil,
    rangeDec   = nil,
    rangeInc   = nil,
    volDec     = nil,
    volBar     = nil,
    volInc     = nil
}

-- ==================================
-- KOMMENTAR: HILFSFUNKTIONEN & YOUTUBE-ID PARSER
-- ==================================
local function now()
    return os.epoch("utc") / 1000
end

local function pad(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n) end
    return s .. string.rep(" ", n - #s)
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

-- Extrahiert die 11-stellige YouTube-Video-ID aus beliebigen YouTube-Links oder direkter ID
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

local function hasPendingUrlChange()
    local trimmed = (state.fieldUrl or ""):gsub("^%s+", ""):gsub("%s+$", "")
    return trimmed ~= state.localUrl
end

-- ==================================
-- KOMMENTAR: KONFIGURATION LADEN & SPEICHERN
-- ==================================
local function saveConfig()
    local f = fs.open(CFG.CONFIG_FILE, "w")
    if not f then return false end
    f.write(textutils.serialize({
        localUrl       = state.localUrl,
        localVideoId   = state.localVideoId,
        localTitle     = state.localTitle,
        volumePct      = state.volumePct,
        loopEnabled    = state.loopEnabled,
        triggerMode    = state.triggerMode,
        sensorRange    = state.sensorRange,
        userPlaying    = state.userPlaying,
        emergencyUrl   = state.emergencyUrl,
        emergencyId    = state.emergencyId,
        lockdownUrl    = state.lockdownUrl,
        lockdownId     = state.lockdownId,
        alarmVolumePct = state.alarmVolumePct,
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
                if type(data.localUrl) == "string" then state.localUrl = data.localUrl end
                if type(data.localVideoId) == "string" then state.localVideoId = data.localVideoId end
                if type(data.localTitle) == "string" then state.localTitle = data.localTitle end
                if type(data.volumePct) == "number" then state.volumePct = math.max(0, math.min(100, data.volumePct)) end
                if type(data.loopEnabled) == "boolean" then state.loopEnabled = data.loopEnabled end
                if type(data.triggerMode) == "number" and CFG.MODES[data.triggerMode] then state.triggerMode = data.triggerMode end
                if type(data.sensorRange) == "number" then state.sensorRange = math.max(1, math.min(50, data.sensorRange)) end
                if type(data.userPlaying) == "boolean" then state.userPlaying = data.userPlaying end
                if type(data.emergencyUrl) == "string" then state.emergencyUrl = data.emergencyUrl end
                if type(data.emergencyId) == "string" then state.emergencyId = data.emergencyId end
                if type(data.lockdownUrl) == "string" then state.lockdownUrl = data.lockdownUrl end
                if type(data.lockdownId) == "string" then state.lockdownId = data.lockdownId end
                if type(data.alarmVolumePct) == "number" then state.alarmVolumePct = math.max(0, math.min(100, data.alarmVolumePct)) end
                if type(data.lastUpdateTime) == "string" then state.lastUpdateTime = data.lastUpdateTime end
                if type(data.lastUpdateStat) == "string" then state.lastUpdateStat = data.lastUpdateStat end
                state.fieldUrl = state.localUrl
                return true
            end
        end
    end
    state.fieldUrl = state.localUrl
    return false
end

-- ==================================
-- KOMMENTAR: GPS-CACHE & MASTER-REPORTING
-- ==================================
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
    local modeName = CFG.MODES[state.triggerMode] or "MANUELL"
    local idInfo = (state.localVideoId ~= "") and state.localVideoId or "Kein Link"
    if state.lockdownActive then
        return "LOCKDOWN-ALARM"
    elseif state.emergencyActive then
        return "EMERGENCY-ALARM"
    elseif state.activeTargetId then
        return "Spielt (" .. modeName .. ": " .. idInfo .. ")"
    else
        return modeName .. " (" .. idInfo .. ")"
    end
end

local function sendReport(success, details)
    if not state.modem then return end
    local label = os.getComputerLabel() or ("Speaker " .. tostring(CFG.COMPUTER_ID))
    local preview = getPreviewString()
    pcall(function()
        rednet.send(CFG.MASTER_ID, {
            action  = "log_report",
            success = success,
            details = details or ("Online: " .. preview),
            pos     = state.cachedPos,
            label   = label,
            preview = preview,
            devType = "speaker"
        }, CFG.UPDATE_PROTOCOL)
    end)
end

-- ==================================
-- KOMMENTAR: PERIPHERIE & REDSTONE PRUEFUNG
-- ==================================
local function setupPeripherals()
    state.speakers = { peripheral.find("speaker") }
    state.modem    = peripheral.find("modem")
    state.detector = peripheral.find("player_detector")

    if state.modem then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.getType(name) == "modem" then
                pcall(rednet.open, name)
            end
        end
    end
    state.dirty = true
end

local function isAnyRedstoneActive()
    for _, side in ipairs(rs.getSides()) do
        if rs.getInput(side) then
            return true
        end
    end
    return false
end

local function isPlayerInRange()
    if not state.detector then return false end
    local ok, players = pcall(function() return state.detector.getPlayersInRange(state.sensorRange) end)
    return ok and type(players) == "table" and #players > 0
end

-- ==================================
-- KOMMENTAR: AUDIO-ENGINE (NICHT-BLOCKIEREND MIT RAM-CACHE)
-- ==================================
local function closeStreamHandle()
    if state.streamHandle then
        pcall(state.streamHandle.close)
        state.streamHandle = nil
    end
end

local function stopAllSpeakers()
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

-- Ermittelt, welche Video-ID aktuell abgespielt werden soll (Prioritaet: Lockdown > Emergency > Lokal)
local function getDesiredPlayback()
    if state.updatingState then
        return nil, 0, false
    end
    if state.lockdownActive then
        if state.lockdownId ~= "" then
            return state.lockdownId, (state.alarmVolumePct / 100) * 3.0, true
        end
        return nil, 0, false
    elseif state.emergencyActive then
        if state.emergencyId ~= "" then
            return state.emergencyId, (state.alarmVolumePct / 100) * 3.0, true
        end
        return nil, 0, false
    end

    -- Normalbetrieb: Je nach gewaehltem Trigger-Modus
    local vol = (state.volumePct / 100) * 3.0
    local mode = CFG.MODES[state.triggerMode]
    local shouldPlay = false

    if mode == "MANUELL" then
        shouldPlay = state.userPlaying
    elseif mode == "REDSTONE" then
        shouldPlay = state.rsTriggered
    elseif mode == "SPIELER" then
        shouldPlay = state.playerTriggered
    elseif mode == "FUNK" then
        shouldPlay = state.remoteTriggered
    end

    if shouldPlay and state.localVideoId ~= "" then
        return state.localVideoId, vol, state.loopEnabled
    end
    return nil, 0, false
end

-- Spielt einen einzelnen Puffer auf allen angeschlossenen Speakern ab
local function pushBufferToSpeakers(pcmBuffer, vol)
    if #state.speakers == 0 or vol <= 0.001 then
        return true
    end
    local allAccepted = true
    for _, spk in ipairs(state.speakers) do
        local ok, accepted = pcall(spk.playAudio, pcmBuffer, vol)
        if ok and not accepted then
            allAccepted = false
        end
    end
    return allAccepted
end

-- Startet den Download-Stream fuer eine Video-ID
local function requestAudioStream(videoId)
    closeStreamHandle()
    state.pendingBuffer = nil

    -- Falls dieser Track bereits vollstaendig im RAM-Cache liegt, direkt aus RAM abspielen!
    if state.cacheId == videoId and state.cacheComplete and #state.cacheChunks > 0 then
        state.cacheReadIdx   = 1
        state.isLoadingAudio = false
        state.audioError     = nil
        state.decoder        = dfpwm.make_decoder()
        state.dirty          = true
        os.queueEvent("speaker_feed")
        return
    end

    if not http then
        state.audioError = "HTTP inaktiv"
        state.dirty = true
        return
    end

    state.cacheId       = videoId
    state.cacheChunks   = {}
    state.cacheComplete = false
    state.cacheReadIdx  = 1

    local url = CFG.API_URL .. "?v=" .. CFG.API_VERSION .. "&id=" .. textutils.urlEncode(videoId)
    state.loadingUrl     = url
    state.isLoadingAudio = true
    state.audioError     = nil
    state.dirty          = true
    http.request({ url = url, binary = true })
end

-- Liest den naechsten Audio-Chunk (aus RAM-Cache oder HTTP-Stream) und gibt ihn an die Speaker
local function feedNextAudioChunk()
    local targetId, vol, shouldLoop = getDesiredPlayback()
    if not targetId or targetId ~= state.activeTargetId then
        return
    end
    if state.isLoadingAudio then
        return
    end

    -- 1. Falls noch ein ungesendeter Puffer wartet (weil Speaker-Puffer voll war)
    if state.pendingBuffer then
        if pushBufferToSpeakers(state.pendingBuffer, vol) then
            state.pendingBuffer = nil
        else
            return -- Warten auf naechstes speaker_audio_empty
        end
    end

    -- 2. Aus RAM-Cache lesen (wenn bereits vollstaendig gecacht)
    if state.cacheId == targetId and state.cacheComplete and not state.streamHandle then
        local rawChunk = state.cacheChunks[state.cacheReadIdx]
        if rawChunk then
            state.cacheReadIdx = state.cacheReadIdx + 1
            local pcm = state.decoder(rawChunk)
            if not pushBufferToSpeakers(pcm, vol) then
                state.pendingBuffer = pcm
            else
                os.queueEvent("speaker_feed")
            end
            return
        else
            -- Ende des gecachten Tracks erreicht
            if shouldLoop then
                state.cacheReadIdx = 1
                state.decoder = dfpwm.make_decoder()
                os.queueEvent("speaker_feed")
            else
                -- Einmalige Wiedergabe beendet
                if CFG.MODES[state.triggerMode] == "MANUELL" then state.userPlaying = false; saveConfig() end
                state.rsTriggered     = false
                state.playerTriggered = false
                state.remoteTriggered = false
                stopAllSpeakers()
            end
            return
        end
    end

    -- 3. Aus aktivem HTTP-Stream lesen
    if state.streamHandle then
        local chunk = state.streamHandle.read(CFG.CHUNK_SIZE)
        if chunk and #chunk > 0 then
            if state.cacheId == targetId then
                if #state.cacheChunks < CFG.MAX_CACHE_CHUNKS then
                    table.insert(state.cacheChunks, chunk)
                else
                    -- Track ist zu lang fuer den kleinen RAM-Cache -> normal weiterstreamen
                    state.cacheId = nil
                    state.cacheChunks = {}
                    state.cacheComplete = false
                end
            end
            local pcm = state.decoder(chunk)
            if not pushBufferToSpeakers(pcm, vol) then
                state.pendingBuffer = pcm
            else
                os.queueEvent("speaker_feed")
            end
        else
            -- Stream ist zu Ende!
            closeStreamHandle()
            if state.cacheId == targetId and #state.cacheChunks > 0 then
                state.cacheComplete = true
            end
            if shouldLoop then
                requestAudioStream(targetId)
            else
                if CFG.MODES[state.triggerMode] == "MANUELL" then state.userPlaying = false; saveConfig() end
                state.rsTriggered     = false
                state.playerTriggered = false
                state.remoteTriggered = false
                stopAllSpeakers()
            end
        end
    end
end

-- Synchronisiert den aktuellen Audio-Zustand mit dem Soll-Zustand (Alarm / Trigger / Stop)
local function syncAudioEngine()
    local desiredId = getDesiredPlayback()
    if not desiredId then
        if state.activeTargetId or state.isLoadingAudio then
            stopAllSpeakers()
        end
        return
    end

    if state.activeTargetId ~= desiredId then
        stopAllSpeakers()
        state.activeTargetId = desiredId
        requestAudioStream(desiredId)
    elseif not state.isLoadingAudio and not state.streamHandle and not (state.cacheId == desiredId and state.cacheComplete) then
        requestAudioStream(desiredId)
    end
end

-- Falls jemand statt Link/ID einen Suchbegriff eingibt, per API nach der Video-ID suchen
local function resolveInputToVideoId(rawInput, targetType)
    local trimmed = tostring(rawInput or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return ""
    end
    local directId = extractYoutubeId(trimmed)
    if directId ~= "" then
        return directId
    end
    if http then
        local sUrl = CFG.API_URL .. "?v=" .. CFG.API_VERSION .. "&search=" .. textutils.urlEncode(trimmed)
        state.searchUrl    = sUrl
        state.searchTarget = targetType
        http.request(sUrl)
        addLog("Suche YouTube-ID fuer: " .. trimmed:sub(1, 20))
    end
    return ""
end

-- ==================================
-- KOMMENTAR: TERMINAL UI ZEICHNEN (BUNKER-STYLE)
-- ==================================
local function drawUI()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()

    hitboxes.urlField   = nil
    hitboxes.clearBtn   = nil
    hitboxes.saveUrlBtn = nil
    hitboxes.playBtn    = nil
    hitboxes.loopBtn    = nil
    hitboxes.modeBtn    = nil
    hitboxes.rangeDec   = nil
    hitboxes.rangeInc   = nil
    hitboxes.volDec     = nil
    hitboxes.volBar     = nil
    hitboxes.volInc     = nil

    -- 1. Kopfzeile
    term.setCursorPos(2, 1)
    term.setTextColor(colors.cyan)
    term.write("--- LAUTSPRECHER ---")
    local idStr = "ID:" .. tostring(CFG.COMPUTER_ID)
    term.setCursorPos(math.max(1, w - #idStr), 1)
    term.setTextColor(colors.lightGray)
    term.write(idStr)

    -- 2. Status-Zeile
    term.setCursorPos(2, 3)
    term.setTextColor(colors.white)
    term.write("Status: ")
    if state.updatingState then
        term.setTextColor(colors.yellow)
        term.write("WARTUNG / UPDATING")
    elseif #state.speakers == 0 then
        term.setTextColor(colors.red)
        term.write("FEHLER: KEIN SPEAKER!")
    elseif state.lockdownActive then
        term.setTextColor(colors.red)
        term.write("LOCKDOWN (ALARM-TON)")
    elseif state.emergencyActive then
        term.setTextColor(colors.red)
        term.write("EMERGENCY (ALARM-TON)")
    elseif state.isLoadingAudio then
        term.setTextColor(colors.yellow)
        term.write("LADE AUDIO STREAM...")
    elseif state.audioError then
        term.setTextColor(colors.red)
        term.write("FEHLER: " .. tostring(state.audioError):sub(1, w - 18))
    elseif state.activeTargetId then
        term.setTextColor(colors.lime)
        term.write("SPIELT [" .. tostring(state.activeTargetId) .. "]")
    else
        term.setTextColor(colors.green)
        term.write("BEREIT (" .. tostring(#state.speakers) .. " Speaker)")
    end

    -- 3. Eingabefeld fuer lokales YouTube-Video
    term.setCursorPos(2, 5)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    local idHint = (state.localVideoId ~= "") and (" [ID: " .. state.localVideoId .. "]") or " [Kein Video]"
    term.write("YT-Link/ID:" .. idHint)

    local clrX = w - 6
    term.setCursorPos(clrX, 5)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.write(" CLR ")
    hitboxes.clearBtn = { x1 = clrX, x2 = clrX + 4, y = 5 }

    local fieldX = 2
    local btnW   = 10
    local btnX   = w - btnW
    local fieldW = math.max(10, btnX - fieldX - 2)

    term.setCursorPos(fieldX, 6)
    if state.focusUrl then
        term.setBackgroundColor(colors.lightGray)
        term.setTextColor(colors.black)
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
    end
    local dispUrl = state.fieldUrl or ""
    if #dispUrl > fieldW then
        dispUrl = dispUrl:sub(#dispUrl - fieldW + 1)
    end
    term.write(pad(dispUrl, fieldW))
    hitboxes.urlField = { x1 = fieldX, x2 = fieldX + fieldW - 1, y = 6 }

    local isUrlDirty = hasPendingUrlChange()
    term.setCursorPos(btnX, 6)
    term.setBackgroundColor(isUrlDirty and colors.orange or colors.green)
    term.setTextColor(colors.black)
    term.write(pad("  SETZEN  ", btnW))
    hitboxes.saveUrlBtn = { x1 = btnX, x2 = btnX + btnW - 1, y = 6 }

    -- 4. Play / Stop & Loop-Schalter
    term.setCursorPos(2, 8)
    local isPlayingLocal = (state.activeTargetId ~= nil and not state.emergencyActive and not state.lockdownActive)
    if isPlayingLocal then
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        term.write("   STOP   ")
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write("   PLAY   ")
    end
    hitboxes.playBtn = { x1 = 2, x2 = 11, y = 8 }

    term.setCursorPos(14, 8)
    if state.loopEnabled then
        term.setBackgroundColor(colors.green)
        term.setTextColor(colors.black)
        term.write(" [x] LOOP AN  ")
    else
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" [ ] LOOP AUS ")
    end
    hitboxes.loopBtn = { x1 = 14, x2 = 27, y = 8 }

    -- 5. Ausloeser-Modus (MANUELL / REDSTONE / SPIELER / FUNK)
    term.setCursorPos(2, 10)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write("Modus: ")

    local modeName = CFG.MODES[state.triggerMode] or "MANUELL"
    local modeBg   = colors.gray
    local modeFg   = colors.white
    if modeName == "REDSTONE" then modeBg = colors.orange; modeFg = colors.black
    elseif modeName == "SPIELER" then modeBg = colors.cyan; modeFg = colors.black
    elseif modeName == "FUNK" then modeBg = colors.purple; modeFg = colors.white
    end

    term.setCursorPos(9, 10)
    term.setBackgroundColor(modeBg)
    term.setTextColor(modeFg)
    local mStr = " [ " .. modeName .. " ] "
    term.write(mStr)
    hitboxes.modeBtn = { x1 = 9, x2 = 9 + #mStr - 1, y = 10 }

    if modeName == "SPIELER" then
        local rX = 9 + #mStr + 2
        term.setCursorPos(rX, 10)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" - ")
        hitboxes.rangeDec = { x1 = rX, x2 = rX + 2, y = 10 }

        term.setBackgroundColor(colors.black)
        term.setTextColor( state.detector and colors.white or colors.red )
        local rTxt = string.format(" %dm ", state.sensorRange)
        term.write(rTxt)

        local incX = rX + 3 + #rTxt
        term.setCursorPos(incX, 10)
        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)
        term.write(" + ")
        hitboxes.rangeInc = { x1 = incX, x2 = incX + 2, y = 10 }
    end

    -- 6. Lautstaerke-Slider (0% - 100%)
    local volY = 12
    term.setCursorPos(2, volY)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.write(pad(string.format("Lautst.: %3d%%", state.volumePct), 14))

    local barX = 16
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

    -- 7. Master-Alarm-Info & Update-Zeitstempel
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.setCursorPos(2, 14)
    local emStat = (state.emergencyId ~= "") and state.emergencyId or "aus"
    local ldStat = (state.lockdownId ~= "") and state.lockdownId or "aus"
    local alarmInfo = string.format("Alarm-Sync: EM[%s] LD[%s] Vol:%d%%", emStat, ldStat, state.alarmVolumePct)
    term.write(alarmInfo:sub(1, w - 2))

    term.setCursorPos(2, 15)
    local updInfo = string.format("letz. Update: [%s] [%s]", tostring(state.lastUpdateTime), tostring(state.lastUpdateStat))
    term.write(updInfo:sub(1, w - 2))

    -- 8. Temporaere Debug-Logs unten
    term.setTextColor(colors.gray)
    local startRow = h - #state.logs + 1
    for i, entry in ipairs(state.logs) do
        term.setCursorPos(2, startRow + i - 1)
        term.write(pad(entry.text, w - 2))
    end

    if state.focusUrl then
        term.setBackgroundColor(colors.lightGray)
        term.setTextColor(colors.black)
        local curX = fieldX + math.min(#(state.fieldUrl or ""), fieldW - 1)
        term.setCursorPos(curX, 6)
        term.setCursorBlink(true)
    else
        term.setCursorBlink(false)
    end
end

-- ==================================
-- KOMMENTAR: AKTIONEN, TRIGGER & REMOTE-UPDATE
-- ==================================
local function applyUrlField()
    state.focusUrl = false
    local trimmed = (state.fieldUrl or ""):gsub("^%s+", ""):gsub("%s+$", "")
    state.localUrl  = trimmed
    state.fieldUrl  = trimmed

    if trimmed == "" then
        state.localVideoId = ""
        state.localTitle   = "Kein Video"
        saveConfig()
        stopAllSpeakers()
        addLog("Video-Link geleert.")
        sendReport(true, "Video geleert")
        return
    end

    local vid = resolveInputToVideoId(trimmed, "local")
    if vid ~= "" then
        state.localVideoId = vid
        state.localTitle   = vid
        saveConfig()
        addLog("Video-ID gespeichert: " .. vid)
        sendReport(true, "Video gesetzt: " .. vid)
        if state.activeTargetId and not state.emergencyActive and not state.lockdownActive then
            state.activeTargetId = nil
        end
        syncAudioEngine()
    end
    state.dirty = true
end

local function applyMasterAlarmConfig(msg, isReply)
    if type(msg) ~= "table" then return end
    if type(msg.emergencyUrl) == "string" then
        state.emergencyUrl = msg.emergencyUrl
        state.emergencyId  = extractYoutubeId(msg.emergencyUrl)
        if state.emergencyUrl ~= "" and state.emergencyId == "" then
            resolveInputToVideoId(state.emergencyUrl, "emergency")
        end
    end
    if type(msg.lockdownUrl) == "string" then
        state.lockdownUrl = msg.lockdownUrl
        state.lockdownId  = extractYoutubeId(msg.lockdownUrl)
        if state.lockdownUrl ~= "" and state.lockdownId == "" then
            resolveInputToVideoId(state.lockdownUrl, "lockdown")
        end
    end
    if type(msg.alarmVol) == "number" then
        state.alarmVolumePct = math.max(0, math.min(100, math.floor(msg.alarmVol + 0.5)))
    end
    saveConfig()
    syncAudioEngine()
    addLog(isReply and "Sync: Alarm-Daten vom Master geladen." or "Master: Alarm-Links aktualisiert!")
    sendReport(true, string.format("Alarm-Sync aktiv (Vol:%d%%)", state.alarmVolumePct))
    state.dirty = true
end

local function checkTriggers()
    local mode = CFG.MODES[state.triggerMode]
    if mode == "REDSTONE" then
        local active = isAnyRedstoneActive()
        if active and not state.rsTriggered then
            state.rsTriggered = true
            syncAudioEngine()
        elseif not active and state.rsTriggered and state.loopEnabled then
            -- Bei aktivem Loop stoppt der Ton, sobald das Redstone-Signal endet
            state.rsTriggered = false
            syncAudioEngine()
        end
    elseif mode == "SPIELER" then
        local active = isPlayerInRange()
        if active and not state.playerTriggered then
            state.playerTriggered = true
            syncAudioEngine()
        elseif not active and state.playerTriggered and state.loopEnabled then
            state.playerTriggered = false
            syncAudioEngine()
        end
    end
end

local function applyUpdate()
    state.updatingState = true
    stopAllSpeakers()
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

    if not http then
        return failUpdate("HTTP inaktiv")
    end

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
    if not content or #content == 0 then
        return failUpdate("Datei leer")
    end

    if content:match("^%s*<!DOCTYPE") or content:match("^%s*<[Hh][Tt][Mm][Ll]") then
        return failUpdate("HTML statt Code erhalten")
    end

    local tf = fs.open(CFG.TEMP_FILE, "w")
    if not tf then
        return failUpdate("Schreibfehler Temp")
    end
    tf.write(content)
    tf.close()

    local compiled = loadfile(CFG.TEMP_FILE)
    fs.delete(CFG.TEMP_FILE)
    if not compiled then
        return failUpdate("Syntaxfehler im Code")
    end

    if fs.exists(CFG.BACKUP_FILE) then fs.delete(CFG.BACKUP_FILE) end
    if fs.exists("startup.lua") then
        pcall(fs.copy, "startup.lua", CFG.BACKUP_FILE)
    elseif fs.exists("startup") then
        pcall(fs.copy, "startup", CFG.BACKUP_FILE)
    end

    local f = fs.open("startup.lua", "w")
    if not f then
        return failUpdate("Schreibfehler startup.lua")
    end
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

-- ==================================
-- KOMMENTAR: HAUPTSCHLEIFE (EVENTS)
-- ==================================
local function main()
    if state.modem then
        refreshGpsCache()
        rednet.broadcast(CFG.MSG_STATUS, CFG.PROTOCOL)
        rednet.broadcast(CFG.MSG_STATUS, CFG.LOCKDOWN_PROTOCOL)
        pcall(function()
            rednet.send(CFG.MASTER_ID, { action = "request_speaker_sync" }, CFG.CONFIG_PROTOCOL)
        end)
        sendReport(true)
    end

    state.tickTimer   = os.startTimer(0.5)
    state.sensorTimer = os.startTimer(0.5)
    checkTriggers()
    syncAudioEngine()

    while true do
        if state.dirty then
            drawUI()
            state.dirty = false
        end

        local ev, p1, p2, p3 = os.pullEvent()

        -- 1. Audio-Feeding (nicht-blockierend pro Chunk)
        if ev == "speaker_audio_empty" or ev == "speaker_feed" then
            feedNextAudioChunk()

        -- 2. HTTP-Antworten fuer Audio-Stream & YouTube-Suche
        elseif ev == "http_success" then
            local url, handle = p1, p2
            if url == state.loadingUrl then
                state.loadingUrl     = nil
                state.isLoadingAudio = false
                state.streamHandle   = handle
                state.decoder        = dfpwm.make_decoder()
                state.dirty          = true
                feedNextAudioChunk()
            elseif url == state.searchUrl then
                state.searchUrl = nil
                local body = handle.readAll()
                handle.close()
                local results = textutils.unserializeJSON(body)
                if type(results) == "table" and results[1] and type(results[1].id) == "string" then
                    local foundId = results[1].id
                    if state.searchTarget == "local" then
                        state.localVideoId = foundId
                        state.localTitle   = tostring(results[1].name or foundId)
                        saveConfig()
                        addLog("Gefunden: " .. state.localTitle:sub(1, 24))
                        sendReport(true, "Video: " .. foundId)
                        syncAudioEngine()
                    elseif state.searchTarget == "emergency" then
                        state.emergencyId = foundId
                        saveConfig()
                        syncAudioEngine()
                    elseif state.searchTarget == "lockdown" then
                        state.lockdownId = foundId
                        saveConfig()
                        syncAudioEngine()
                    end
                else
                    addLog("Kein YouTube-Treffer gefunden!")
                end
                state.dirty = true
            else
                pcall(handle.close)
            end

        elseif ev == "http_failure" then
            local url = p1
            if url == state.loadingUrl then
                state.loadingUrl     = nil
                state.isLoadingAudio = false
                state.audioError     = "Stream-Fehler"
                addLog("Audio-Stream fehlgeschlagen! Neuer Versuch in 3s...")
                state.retryTimer     = os.startTimer(3.0)
                state.dirty          = true
            elseif url == state.searchUrl then
                state.searchUrl = nil
                addLog("YouTube-Suche fehlgeschlagen!")
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
                if hitboxes.urlField and y == hitboxes.urlField.y and x >= hitboxes.urlField.x1 and x <= hitboxes.urlField.x2 then
                    state.focusUrl   = true
                    state.freshFocus = false
                    state.dirty      = true
                elseif hitboxes.clearBtn and y == hitboxes.clearBtn.y and x >= hitboxes.clearBtn.x1 and x <= hitboxes.clearBtn.x2 then
                    state.fieldUrl   = ""
                    state.focusUrl   = true
                    state.freshFocus = false
                    state.dirty      = true
                elseif hitboxes.saveUrlBtn and y == hitboxes.saveUrlBtn.y and x >= hitboxes.saveUrlBtn.x1 and x <= hitboxes.saveUrlBtn.x2 then
                    applyUrlField()
                elseif hitboxes.playBtn and y == hitboxes.playBtn.y and x >= hitboxes.playBtn.x1 and x <= hitboxes.playBtn.x2 then
                    state.focusUrl = false
                    local isPlayingLocal = (state.activeTargetId ~= nil and not state.emergencyActive and not state.lockdownActive)
                    if isPlayingLocal then
                        state.userPlaying     = false
                        state.rsTriggered     = false
                        state.playerTriggered = false
                        state.remoteTriggered = false
                        saveConfig()
                        stopAllSpeakers()
                        addLog("Wiedergabe gestoppt.")
                    else
                        if hasPendingUrlChange() then
                            applyUrlField()
                        end
                        if state.localVideoId == "" then
                            addLog("Bitte erst einen YouTube-Link setzen!")
                        else
                            if CFG.MODES[state.triggerMode] == "MANUELL" then
                                state.userPlaying = true
                                saveConfig()
                            else
                                state.remoteTriggered = true
                            end
                            syncAudioEngine()
                            addLog("Starte Wiedergabe...")
                        end
                    end
                    sendReport(true)
                    state.dirty = true
                elseif hitboxes.loopBtn and y == hitboxes.loopBtn.y and x >= hitboxes.loopBtn.x1 and x <= hitboxes.loopBtn.x2 then
                    state.focusUrl    = false
                    state.loopEnabled = not state.loopEnabled
                    saveConfig()
                    addLog(state.loopEnabled and "Loop aktiviert." or "Loop deaktiviert (1x abspielen).")
                    state.dirty = true
                elseif hitboxes.modeBtn and y == hitboxes.modeBtn.y and x >= hitboxes.modeBtn.x1 and x <= hitboxes.modeBtn.x2 then
                    state.focusUrl        = false
                    state.triggerMode     = (state.triggerMode % #CFG.MODES) + 1
                    state.rsTriggered     = false
                    state.playerTriggered = false
                    state.remoteTriggered = false
                    saveConfig()
                    checkTriggers()
                    syncAudioEngine()
                    sendReport(true, "Modus: " .. CFG.MODES[state.triggerMode])
                    addLog("Modus gewechselt: " .. CFG.MODES[state.triggerMode])
                    state.dirty = true
                elseif hitboxes.rangeDec and y == hitboxes.rangeDec.y and x >= hitboxes.rangeDec.x1 and x <= hitboxes.rangeDec.x2 then
                    state.sensorRange = math.max(1, state.sensorRange - 1)
                    saveConfig()
                    state.dirty = true
                elseif hitboxes.rangeInc and y == hitboxes.rangeInc.y and x >= hitboxes.rangeInc.x1 and x <= hitboxes.rangeInc.x2 then
                    state.sensorRange = math.min(50, state.sensorRange + 1)
                    saveConfig()
                    state.dirty = true
                else
                    state.focusUrl = false
                    state.dirty    = true
                end
            end

        -- 4. Tastatureingabe & Strg+V (Paste) fuer YouTube-Links
        elseif ev == "paste" and state.focusUrl and not state.updatingState then
            state.fieldUrl = (state.fieldUrl or "") .. tostring(p1 or "")
            state.dirty    = true

        elseif ev == "char" and state.focusUrl and not state.updatingState then
            state.fieldUrl = (state.fieldUrl or "") .. p1
            state.dirty    = true

        elseif ev == "key" and state.focusUrl and not state.updatingState then
            if p1 == keys.backspace then
                state.fieldUrl = (state.fieldUrl or ""):sub(1, -2)
                state.dirty    = true
            elseif p1 == keys.enter or p1 == keys.numPadEnter then
                applyUrlField()
            end

        -- 5. Redstone-Event fuer sofortige Trigger-Reaktion
        elseif ev == "redstone" and not state.updatingState then
            checkTriggers()

        -- 6. Rednet-Nachrichten (Emergency, Lockdown, Master-Sync, Funk-Trigger, Update)
        elseif ev == "rednet_message" then
            local senderId, message, protocol = p1, p2, p3

            if protocol == CFG.PROTOCOL and not state.updatingState then
                if message == CFG.MSG_ON and not state.emergencyActive then
                    state.emergencyActive = true
                    syncAudioEngine()
                    addLog("EMERGENCY-ALARM aktiviert!")
                elseif message == CFG.MSG_OFF and state.emergencyActive then
                    state.emergencyActive = false
                    syncAudioEngine()
                    addLog("Emergency beendet -> Vorheriger Modus.")
                end
                state.dirty = true

            elseif protocol == CFG.LOCKDOWN_PROTOCOL and not state.updatingState then
                if message == CFG.MSG_LOCK and not state.lockdownActive then
                    state.lockdownActive = true
                    syncAudioEngine()
                    addLog("LOCKDOWN-ALARM aktiviert!")
                elseif message == CFG.MSG_UNLOCK and state.lockdownActive then
                    state.lockdownActive = false
                    syncAudioEngine()
                    addLog("Lockdown beendet -> Vorheriger Modus.")
                end
                state.dirty = true

            elseif protocol == CFG.CONFIG_PROTOCOL and not state.updatingState then
                if message == CFG.MSG_STATUS then
                    sendReport(true)
                elseif type(message) == "table" and message.action == "set_alarm_config" then
                    applyMasterAlarmConfig(message, message.isReply == true)
                end

            elseif protocol == CFG.TRIGGER_PROTOCOL and not state.updatingState then
                if CFG.MODES[state.triggerMode] == "FUNK" then
                    if message == "PLAY" or (type(message) == "table" and message.action == "play") then
                        state.remoteTriggered = true
                        syncAudioEngine()
                        addLog("Funk-Trigger empfangen (Start).")
                    elseif message == "STOP" or (type(message) == "table" and message.action == "stop") then
                        state.remoteTriggered = false
                        syncAudioEngine()
                        addLog("Funk-Trigger empfangen (Stop).")
                    end
                end

            elseif protocol == CFG.UPDATE_PROTOCOL then
                if message == CFG.MSG_STATUS then
                    sendReport(true)
                elseif senderId == CFG.MASTER_ID and type(message) == "table" and message.action == "update" then
                    pcall(function() rednet.send(CFG.MASTER_ID, { action = "ping_ack" }, CFG.UPDATE_PROTOCOL) end)
                    applyUpdate()
                    state.tickTimer   = os.startTimer(0.5)
                    state.sensorTimer = os.startTimer(0.5)
                end
            end

        -- 7. Timer fuer Log-Ablauf, Spieler-Detektor und Stream-Retry
        elseif ev == "timer" then
            if p1 == state.tickTimer then
                state.tickTimer = os.startTimer(0.5)
                local t = now()
                for i = #state.logs, 1, -1 do
                    if state.logs[i].expires <= t then
                        table.remove(state.logs, i)
                        state.dirty = true
                    end
                end
            elseif p1 == state.sensorTimer then
                state.sensorTimer = os.startTimer(0.5)
                checkTriggers()
            elseif p1 == state.retryTimer then
                state.retryTimer     = nil
                state.activeTargetId = nil
                syncAudioEngine()
            end

        elseif ev == "peripheral" or ev == "peripheral_detach" then
            setupPeripherals()
            syncAudioEngine()
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
        stopAllSpeakers()
        if tostring(err):find("Terminated") then
            term.setCursorBlink(false)
            term.setBackgroundColor(colors.black)
            term.setTextColor(colors.white)
            term.clear()
            term.setCursorPos(1, 1)
            print("Lautsprecher beendet.")
            return
        end
        addLog("Fehler: " .. tostring(err))
        sleep(2)
    end
end
