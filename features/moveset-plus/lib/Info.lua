-- Move facts for the comparison panel, read straight from the game data.
-- Gen 1 has no move description in the extracted data beyond the short line
-- the summary screen prints, so that is what the panel shows.

local Types = require("src.battle.TypeChart")
local Strings = require("src.core.Strings")

local Info = {}

local MOD = "moveset_plus_gen1"

function Info.label(key)
  return Strings(key, MOD)
end

function Info.clean(text)
  return tostring(text or "")
    :gsub("<NEXT>", " "):gsub("{NEXT}", " ")
    :gsub("{DONE}", ""):gsub("{PROMPT}", "")
    :gsub("%s+", " "):match("^%s*(.-)%s*$")
end

-- entry is the mon's own move record ({ id=, pp= }) or the incoming id.
function Info.move(game, entry)
  local data = game and game.data or {}
  local id = type(entry) == "table" and entry.id or entry
  local def = (data.moves or {})[id] or {}
  local maximum = tonumber(def.pp) or 0
  local current = type(entry) == "table" and tonumber(entry.pp) or maximum
  local power = tonumber(def.power) or 0
  local accuracy = tonumber(def.accuracy)
  if accuracy == nil and tonumber(def.accuracyRaw) then
    accuracy = math.floor(def.accuracyRaw * 100 / 255 + 0.5)
  end
  return {
    id = id,
    name = def.name or id or "---",
    type = def.type and Types.displayName(def.type, data) or "---",
    pp = (current or maximum) .. "/" .. maximum,
    power = power >= 2 and tostring(power) or "---",
    accuracy = accuracy and (tostring(accuracy) .. "/100") or "---",
    description = Info.clean(def.description),
  }
end

return Info
