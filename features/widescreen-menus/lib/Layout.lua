-- Widescreen layout rules and the detail panes.
--
-- Gen 1 draws every menu on a fixed 160x144 playfield. The renderer can hand a
-- screen a wider native surface (that is how the wide battle layout works:
-- Renderer:setUISize + a screen's uiSize), so a menu only has to ask for the
-- extra width and draw something useful in it. The native screen keeps its own
-- coordinates on the left; the pane goes to the right.

local Layout = {}

Layout.NATIVE = 160
Layout.HEIGHT = 144
Layout.MIN_WIDE = 240
Layout.MAX_WIDE = 400

-- Width in native pixels for a window of this size, rounded to the font's tile
-- grid. A 4:3 window gets the classic 160 and the mod does nothing.
function Layout.uiWidth(windowWidth, windowHeight)
  windowWidth = tonumber(windowWidth) or 0
  windowHeight = tonumber(windowHeight) or 0
  if windowWidth <= 0 or windowHeight <= 0 then return Layout.NATIVE end
  local scale = math.max(1, math.floor(windowHeight / Layout.HEIGHT))
  local tiles = math.floor(windowWidth / scale / 8)
  local width = tiles * 8
  if width < Layout.MIN_WIDE then return Layout.NATIVE end
  return math.min(Layout.MAX_WIDE, width)
end

local function statName(key)
  return ({ attack = "ATTACK", defense = "DEFENSE", speed = "SPEED",
            special = "SPECIAL", hp = "HP" })[key] or key:upper()
end

-- The party pane: who is selected and what they can do.
function Layout.partyLines(mon, data)
  if type(mon) ~= "table" then return {} end
  local def = data and data.pokemon and data.pokemon[mon.species] or {}
  local name = mon.nickname or def.name or "POKéMON"
  local stats = mon.stats or {}
  local lines = {
    name,
    "LV " .. tostring(mon.level or 1),
    "HP " .. tostring(mon.hp or 0) .. "/" .. tostring(stats.hp or 0),
    "",
  }
  for _, key in ipairs({ "attack", "defense", "speed", "special" }) do
    lines[#lines + 1] = statName(key):sub(1, 3) .. " " .. tostring(stats[key] or 0)
  end
  local moves = mon.moves or {}
  if #moves > 0 then
    lines[#lines + 1] = ""
    for _, move in ipairs(moves) do
      local mdef = (data and data.moves or {})[move.id] or {}
      local pp = move.pp or mdef.pp or 0
      lines[#lines + 1] = (mdef.name or tostring(move.id)):sub(1, 10) ..
        " " .. tostring(pp) .. "/" .. tostring(mdef.pp or pp)
    end
  end
  return lines
end

-- The summary pane: its four moves, which the native screen cannot fit beside
-- the stat block.
function Layout.summaryLines(mon, data)
  if type(mon) ~= "table" then return {} end
  local lines = { "MOVES", "" }
  for _, move in ipairs(mon.moves or {}) do
    local mdef = (data and data.moves or {})[move.id] or {}
    lines[#lines + 1] = (mdef.name or tostring(move.id)):sub(1, 11)
    lines[#lines + 1] = "  PP " .. tostring(move.pp or mdef.pp or 0) ..
      "/" .. tostring(mdef.pp or 0)
  end
  return lines
end

return Layout
