-- Route and town names when you walk into one, the way Gen II shows its map
-- sign. Gen 1 never had this; the cartridge only names places on the Town Map.
--
-- The banner is drawn after the overworld frame. The engine's font is used, so
-- it reads like the game's own text: a white box, a black border, black caps.
--
-- Only OVERWORLD-tileset maps announce themselves -- towns and routes. Walking
-- into a house, a cave or a gate changes the map without flashing a name, which
-- is what the cartridge's sign does too.

local HOLD_SECONDS = 2.5
local BOX_X, BOX_Y = 8, 8
local PAD = 4

local function locationName(game, mapId)
  local data = game and game.data
  local def = data and data.maps and data.maps[mapId]
  if type(def) ~= "table" or def.tileset ~= "OVERWORLD" then return nil end
  local field = data.field
  local townMap = field and field.townMap
  local locations = townMap and (townMap.locations or townMap)
  local entry = type(locations) == "table" and locations[mapId]
  if type(entry) == "table" then
    local text = entry.name or entry.label
    if type(text) == "string" and text ~= "" then
      return (text:gsub("<PK><MN>", "POKéMON"))
    end
  end
  if type(def.label) == "string" and def.label ~= "" then
    return (def.label:gsub("(%l)(%u)", "%1 %2")):upper()
  end
  return nil
end

return function(mod)
  local okFont, Font = pcall(require, "src.render.Font")
  local okWorld, World = pcall(require, "src.world.OverworldController")
  if not (okFont and okWorld and type(World) == "table") then return end
  if type(World.draw) ~= "function" or World.__qualityOfLifePlaceTag then return end
  World.__qualityOfLifePlaceTag = true

  local lastMapId, shownName, shownUntil = nil, nil, 0

  local function banner(state)
    local game = state and state.game
    local map = state and (state.map or (game and game.world and game.world.map))
    local mapId = map and map.id
    local now = love.timer and love.timer.getTime and love.timer.getTime() or 0

    if mapId and mapId ~= lastMapId then
      lastMapId = mapId
      local text = locationName(game, mapId)
      if text then
        shownName, shownUntil = text, now + HOLD_SECONDS
      end
    end

    if not shownName or now > shownUntil then
      if shownName and now > shownUntil then shownName = nil end
      return
    end

    local width = (Font.width and Font.width(shownName) or #shownName * 8) + PAD * 2
    local height = 16

    love.graphics.push()
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", BOX_X, BOX_Y, width, height)
    love.graphics.setColor(0, 0, 0, 1)
    love.graphics.rectangle("line", BOX_X + 0.5, BOX_Y + 0.5, width - 1, height - 1)
    Font.draw(shownName, BOX_X + PAD, BOX_Y + PAD)
    love.graphics.pop()
  end

  local base = World.draw
  World.draw = function(self, ...)
    base(self, ...)
    local generation = require("src.core.GameVersion").generation()
    if generation ~= 1 then return end
    if mod.options:get("place_tag") == false then return end
    local ok, err = pcall(banner, self)
    if not ok then mod.log:warn("place tag failed: %s", tostring(err)) end
  end

  -- Exposed for the tests: the name a map would announce, or nil.
  mod.exports.placeTagName = locationName
end
