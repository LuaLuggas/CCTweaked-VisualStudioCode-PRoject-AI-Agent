-- update.lua: laedt alle Dateien einer Rolle aus deinem GitHub-Repo auf diesen Computer.
-- Benutzung:  update <rolle>      (liest roles/<rolle>.txt aus dem Repo)
-- Beispiel:   update notaus
--
-- WICHTIG: BASE unten einmal auf dein Repo anpassen.

local BASE = "https://raw.githubusercontent.com/LuaLuggas/CCTweaked-VisualStudioCode-PRoject-AI-Agent/main/"

local args = { ... }
local rolle = args[1]
if not rolle then
  print("Benutzung: update <rolle>")
  return
end

if not http then
  printError("HTTP ist in dieser Welt/auf diesem Server deaktiviert.")
  return
end

-- Holt eine Datei als String. Der Zeitstempel am Ende umgeht den Cache von GitHub.
local function fetch(pfad)
  local url = BASE .. pfad .. "?nocache=" .. os.epoch("utc")
  local res, err = http.get({ url = url, binary = true })
  if not res then
    return nil, err
  end
  local daten = res.readAll()
  res.close()
  return daten
end

local manifest, err = fetch("roles/" .. rolle .. ".txt")
if not manifest then
  printError("Manifest roles/" .. rolle .. ".txt nicht gefunden: " .. tostring(err))
  return
end

local ok, fehler = 0, 0
for zeile in manifest:gmatch("[^\r\n]+") do
  -- Leerzeilen und Kommentare (# ...) ueberspringen
  local pfad = zeile:match("^%s*(.-)%s*$")
  if pfad ~= "" and pfad:sub(1, 1) ~= "#" then
    local daten, e = fetch(pfad)
    if daten then
      local ordner = fs.getDir(pfad)
      if ordner ~= "" and not fs.exists(ordner) then
        fs.makeDir(ordner)
      end
      local f = fs.open(pfad, "wb")
      f.write(daten)
      f.close()
      print("OK     " .. pfad)
      ok = ok + 1
    else
      printError("FEHLER " .. pfad .. ": " .. tostring(e))
      fehler = fehler + 1
    end
  end
end

print(("Fertig: %d aktualisiert, %d Fehler."):format(ok, fehler))
