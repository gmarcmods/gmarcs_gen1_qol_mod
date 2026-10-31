-- Gen II-style Pack presentation layered over the stock BagMenu. The stock
-- screen still owns every USE/TOSS/battle callback; this module supplies the
-- four-pocket model, navigation, ordering and drawing.

local Bag = require("src.inventory.Bag")
local Font = require("src.render.Font")
local Sound = require("src.core.Sound")
local Strings = require("src.core.Strings")
local Theme = require("src.ui.Theme")
local VanillaBagMenu = require("src.ui.BagMenu")

local Gen2Bag = {}

local BALLS = {
  MASTER_BALL = true, ULTRA_BALL = true, GREAT_BALL = true,
  POKE_BALL = true, SAFARI_BALL = true,
}

local POCKETS = {
  { id = "items", name = "ITEM" },
  { id = "balls", name = "BALL" },
  { id = "key", name = "KEY" },
  { id = "tmhm", name = "TM/HM" },
}

local DESCRIPTIONS = {
  BICYCLE = "A folding bicycle that enables fast movement.",
  ESCAPE_ROPE = "Use it to escape instantly from a cave.",
  ITEMFINDER = "Checks the area for hidden items.",
  POKE_FLUTE = "A sweet flute that awakens sleeping POKeMON.",
  TOWN_MAP = "A map that shows where you are in KANTO.",
  OLD_ROD = "Use by water to fish for POKeMON.",
  GOOD_ROD = "A good rod for catching water POKeMON.",
  SUPER_ROD = "The best rod for catching water POKeMON.",
  RARE_CANDY = "Raises the level of a POKeMON by one.",
  PP_UP = "Raises the maximum PP of one move.",
  ETHER = "Restores 10 PP to one move.",
  MAX_ETHER = "Fully restores the PP of one move.",
  ELIXER = "Restores 10 PP to every move.",
  MAX_ELIXER = "Fully restores the PP of every move.",
  REVIVE = "Revives a fainted POKeMON with half its HP.",
  MAX_REVIVE = "Fully revives a fainted POKeMON.",
}

local function pocketId(id, def)
  if def and def.machine then return "tmhm" end
  if BALLS[id] then return "balls" end
  if def and def.keyItem then return "key" end
  return "items"
end

local function entryFor(game, id, stack)
  local def = game.data.items[id] or {}
  local pocket = pocketId(id, def)
  local label, right = def.name or id
  if def.machine then
    local move = game.data.moves[def.machine.move] or {}
    local number = def.machine.number or 0
    label = (def.machine.kind == "HM" and ("H" .. number)
      or string.format("%02d", number)) .. " " ..
      (move.name or def.machine.move)
    if def.machine.kind ~= "HM" then right = "x" .. stack.count end
  elseif pocket ~= "key" then
    right = "x" .. stack.count
  end
  return { value = id, label = label, right = right, pocket = pocket,
    slot = stack.slot, stack = stack.count,
    count = pocket~='key'and not(id:match('^HM_'))and stack.count or nil }
end

local function entriesFor(game, pocket)
  local out = {}
  for _, stack in ipairs(Bag.rows(game.save,game.data)) do
    local id=stack.id
    local def = game.data.items[id]
    if pocketId(id, def) == pocket and not Bag.isBadge(id) then
      out[#out + 1] = entryFor(game, id, stack)
    end
  end
  return out
end

local function description(game, row)
  if not row then return "There are no items in this pocket." end
  local id, def = row.value, game.data.items[row.value] or {}
  if def.description then return Strings(def.description) end
  if DESCRIPTIONS[id] then return Strings(DESCRIPTIONS[id]) end
  if def.machine then
    local move = game.data.moves[def.machine.move] or {}
    return Strings("Teaches %s to a compatible POKeMON.",
      move.name or def.machine.move)
  end
  if BALLS[id] then return Strings("A BALL used to catch wild POKeMON.") end
  if def.keyItem then return Strings("An important item for your adventure.") end
  if id:find("HEAL", 1, true) or id == "ANTIDOTE" or id == "AWAKENING"
      or id == "PARLYZ_HEAL" or id == "ICE_HEAL" or id == "FULL_RESTORE" then
    return Strings("A medicine that treats a POKeMON.")
  end
  if id:find("STONE", 1, true) then
    return Strings("A peculiar stone that evolves some POKeMON.")
  end
  return Strings("An item carried in the PACK.")
end

local function splitLines(text, width, limit)
  text = tostring(text or ""):gsub("\n", " ")
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if line ~= "" and Font.width(candidate) > width then
      lines[#lines + 1], line = line, word
      if #lines == limit then break end
    else
      line = candidate
    end
  end
  if #lines < limit and line ~= "" then lines[#lines + 1] = line end
  return lines
end

local function fitted(text, width)
  local spans = Font.split(text)
  local count = Font.spansFitting(spans, width)
  if count >= #spans then return text end
  if count <= 0 then return "" end
  return text:sub(1, spans[count].to)
end

local function sync(screen)
  local state = screen.gen2
  local old = screen.items[screen.index]
  local oldId = old and old.value
  local pockets = state.pockets or POCKETS
  screen.items = state.entries(pockets[state.pocket].id)
  local wanted
  for i, row in ipairs(screen.items) do
    if row.value == oldId then wanted = i break end
  end
  screen.index = wanted or math.max(1, math.min(state.cursor[state.pocket] or 1,
    #screen.items))
  if #screen.items == 0 then screen.index = 1 end
  screen.scroll = math.max(0, math.min(state.scroll[state.pocket] or 0,
    math.max(0, #screen.items - 5)))
  if screen.index <= screen.scroll then screen.scroll = screen.index - 1 end
  if screen.index > screen.scroll + 5 then screen.scroll = screen.index - 5 end
  state.cursor[state.pocket], state.scroll[state.pocket] = screen.index, screen.scroll
end

local function changePocket(screen, delta)
  local state = screen.gen2
  local pockets = state.pockets or POCKETS
  state.cursor[state.pocket], state.scroll[state.pocket] = screen.index, screen.scroll
  state.pocket = ((state.pocket - 1 + delta) % #pockets) + 1
  state.swapId, screen.swapIndex = nil, nil
  screen.items, screen.index, screen.scroll = {}, 1, 0
  sync(screen)
  Sound.play(screen.game.data, "Swap")
end

local function swapRows(screen, firstId, secondId)
  if not firstId or not secondId or firstId == secondId then return end
  local order, a, b = Bag.order(screen.game.save)
  for i, id in ipairs(order) do
    if id == firstId then a = i elseif id == secondId then b = i end
  end
  if a and b then
    order[a], order[b] = order[b], order[a]
    Sound.play(screen.game.data, "Swap")
  end
end

local function update(screen)
  sync(screen)
  local input, state = screen.game.input, screen.gen2
  if input:wasPressed("left") then
    screen.footer = nil
    changePocket(screen, -1)
    return
  end
  if input:wasPressed("right") then
    screen.footer = nil
    changePocket(screen, 1)
    return
  end
  if input:wasPressed("b") then
    if state.swapId then
      state.swapId, screen.swapIndex = nil, nil
    else
      screen.game.stack:pop()
      if screen.gen2OnCancel then screen.gen2OnCancel() end
    end
    return
  end
  if #screen.items == 0 then return end
  if input:wasPressed("up") then
    screen.footer = nil
    screen.index = screen.index > 1 and screen.index - 1 or #screen.items
  elseif input:wasPressed("down") then
    screen.footer = nil
    screen.index = screen.index < #screen.items and screen.index + 1 or 1
  elseif state.allowReorder and input:wasPressed("select") then
    local row = screen.items[screen.index]
    if not state.swapId then
      state.swapId, screen.swapIndex = row.value, screen.index
    else
      swapRows(screen, state.swapId, row.value)
      state.swapId, screen.swapIndex = nil, nil
      sync(screen)
    end
  elseif input:wasPressed("a") then
    local row = screen.items[screen.index]
    if state.swapId then
      swapRows(screen, state.swapId, row.value)
      state.swapId, screen.swapIndex = nil, nil
      sync(screen)
    elseif screen.gen2Choose then
      screen.gen2Choose(row, screen)
    end
    return
  end
  if screen.index <= screen.scroll then screen.scroll = screen.index - 1 end
  if screen.index > screen.scroll + 5 then screen.scroll = screen.index - 5 end
  state.cursor[state.pocket], state.scroll[state.pocket] = screen.index, screen.scroll
end

local MINI = {
  A={"010","101","111","101","101"}, B={"110","101","110","101","110"},
  C={"011","100","100","100","011"}, E={"111","100","110","100","111"},
  H={"101","101","111","101","101"}, I={"111","010","010","010","111"},
  K={"101","101","110","101","101"}, L={"100","100","100","100","111"},
  M={"10001","11011","10101","10101","10101"}, O={"010","101","101","101","010"},
  P={"110","101","110","100","100"}, S={"011","100","010","001","110"},
  T={"111","010","010","010","010"}, Y={"101","101","010","010","010"},
  ["/"]={"001","001","010","100","100"}, [" "]={"0","0","0","0","0"},
}

local function miniWidth(text)
  local width = 0
  for ch in text:gmatch(".") do
    local glyph = MINI[ch] or MINI[" "]
    width = width + #glyph[1] + 1
  end
  return math.max(0, width - 1)
end

local function miniTextAt(text, x, y)
  for ch in text:gmatch(".") do
    local glyph = MINI[ch] or MINI[" "]
    for row, bits in ipairs(glyph) do
      for col = 1, #bits do
        if bits:sub(col, col) == "1" then
          love.graphics.rectangle("fill", x + col - 1, y + (row - 1) * 2, 1, 2)
        end
      end
    end
    x = x + #glyph[1] + 1
  end
end

local function miniText(text, y)
  miniTextAt(text, math.floor((40 - miniWidth(text)) / 2), y)
end

local function drawBackpack(index)
  -- Original pixel art made for this mod: one compact backpack silhouette,
  -- with a small pocket marker instead of unrelated oversized object icons.
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", 15, 20, 10, 2) -- handle
  love.graphics.rectangle("fill", 12, 22, 3, 3)
  love.graphics.rectangle("fill", 25, 22, 3, 3)
  love.graphics.rectangle("fill", 9, 25, 3, 21)
  love.graphics.rectangle("fill", 28, 25, 3, 21)
  love.graphics.rectangle("fill", 12, 23, 16, 3)
  love.graphics.rectangle("fill", 12, 44, 16, 3)
  love.graphics.rectangle("fill", 12, 31, 16, 2) -- flap
  love.graphics.rectangle("fill", 14, 33, 12, 2)
  love.graphics.rectangle("fill", 18, 35, 4, 2)
  love.graphics.rectangle("fill", 7, 29, 2, 13)  -- straps
  love.graphics.rectangle("fill", 31, 29, 2, 13)
  if index == 1 then
    love.graphics.rectangle("fill", 18, 38, 4, 4)
  elseif index == 2 then
    love.graphics.rectangle("line", 17, 37, 6, 6)
    love.graphics.line(17, 40, 23, 40)
  elseif index == 3 then
    love.graphics.rectangle("fill", 16, 39, 6, 2)
    love.graphics.rectangle("fill", 21, 37, 2, 5)
    love.graphics.rectangle("fill", 23, 37, 2, 2)
  else
    miniText("TM", 36)
  end
end

local function draw(screen)
  sync(screen)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  love.graphics.setColor(0, 0, 0, 1)

  local pocket = (screen.gen2.pockets or POCKETS)[screen.gen2.pocket]
  -- Gen II's fixed header: pocket-switch arrows on the left and list arrows
  -- on the right. Triangles avoid relying on optional font glyphs.
  love.graphics.polygon("fill", 1, 4, 5, 1, 5, 7)
  love.graphics.polygon("fill", 10, 1, 14, 4, 10, 7)
  Font.draw("POCKET", 16, 0)
  love.graphics.polygon("fill", 106, 1, 112, 1, 109, 5)
  love.graphics.polygon("fill", 116, 6, 122, 6, 119, 2)
  miniTextAt("ITEMS", 130, 0)
  love.graphics.rectangle("fill", 0, 11, 160, 1)

  drawBackpack(screen.gen2.pocket)
  local pocketLabel = pocket.id == "key" and "KEY ITEM" or
    (pocket.id == "tmhm" and "TM/HM" or pocket.name .. "S")
  miniText(pocketLabel, 59)
  miniText("POCKET", 72)

  love.graphics.setColor(0, 0, 0, 1)
  for row = 1, 5 do
    local i = screen.scroll + row
    local item = screen.items[i]
    if not item then break end
    local y = 16 + (row - 1) * 16
    local marker = screen.gen2.swapId == item.value and Theme.cursorHollow
      or (i == screen.index and Theme.cursor or nil)
    if marker then Font.drawCode(marker, 48, y) end
    local rightX = item.right and (152 - Font.width(item.right)) or 152
    Font.draw(fitted(item.label, rightX - 56 - (item.right and 8 or 0)), 56, y)
    if item.right then Font.draw(item.right, rightX, y) end
  end
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local body = screen.footer or description(screen.game, screen.items[screen.index])
  local desc = tostring(body):upper()
  local lines = splitLines(desc, 144, 2)
  for i, line in ipairs(lines) do Font.draw(line, 8, 104 + (i - 1) * 16) end
  love.graphics.setColor(1, 1, 1, 1)
end

function Gen2Bag.decorate(screen, entries, opts)
  opts = opts or {}
  screen.gen2Choose = screen.onChoose
  screen.gen2OnCancel = screen.onCancel
  screen.gen2 = { pocket = 1, cursor = { 1, 1, 1, 1 },
                  scroll = { 0, 0, 0, 0 }, entries = entries,
                  allowReorder = opts.allowReorder ~= false }
  screen.rows, screen.items = 5, {}
  screen.onChoose, screen.onCancel, screen.onSelectKey = nil, nil, nil
  screen.update = update
  screen.draw = draw
  sync(screen)
  return screen
end

function Gen2Bag.new(game, opts)
  opts = opts or {}
  local screen = VanillaBagMenu.new(game, opts)
  return Gen2Bag.decorate(screen, function(pocket)
    return entriesFor(game, pocket)
  end)
end

local function storageDraw(screen)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, 160, 144)
  Font.drawBox(0, 0, 20, 12)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(tostring(screen.title or "PC ITEMS"):upper(), 8, 8)
  for row = 1, 4 do
    local i = screen.scroll + row
    local item = screen.items[i]
    if not item then break end
    local y = 24 + (row - 1) * 16
    if i == screen.index then Font.drawCode(Theme.cursor, 16, y) end
    local rightX = item.right and (144 - Font.width(item.right)) or 144
    Font.draw(fitted(item.label, rightX - 32 - (item.right and 8 or 0)), 32, y)
    if item.right then Font.draw(item.right, rightX, y) end
  end
  Font.drawBox(0, 12, 20, 6)
  love.graphics.setColor(0, 0, 0, 1)
  local row = screen.items[screen.index]
  local body = screen.footer or description(screen.game, row)
  for i, line in ipairs(splitLines(tostring(body):upper(), 144, 2)) do
    Font.draw(line, 8, 104 + (i - 1) * 16)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

function Gen2Bag.decorateStorage(screen)
  screen.rows = 4
  local originalUpdate = screen.update
  screen.update = function(self, dt)
    local input = self.game.input
    if input:wasPressed("up") or input:wasPressed("down") then self.footer = nil end
    return originalUpdate(self, dt)
  end
  screen.draw = storageDraw
  return screen
end

Gen2Bag.pocketId = pocketId
Gen2Bag.pockets = POCKETS
Gen2Bag.entriesFor = entriesFor
Gen2Bag.miniWidth = miniWidth

return Gen2Bag
