-- Useful Bag: 999-capacity bag with auto-sorted pockets.
--
-- The bag is split into six pockets -- ITEMS, MEDICINE, POKé BALLS,
-- TMs / HMs, BATTLE ITEMS and KEY ITEMS -- that the player cycles with
-- LEFT / RIGHT (wrapping at the ends).  TAB (keyboard), R3 / right stick
-- click (controller), or the touchscreen SELECT overlay opens the SORT BY
-- NAME / SORT BY COUNT prompt, and Up on the first item / Down on the last
-- item wraps around.
--
-- The in-battle bag is battle-aware: it opens on the BATTLE ITEMS pocket
-- (or the first non-empty usable pocket) and its L/R cycling skips TMs /
-- HMs and KEY ITEMS, whose items ItemEffects refuses mid-battle.
--
-- THE HIDDEN BAG: the engine's item logic (key-item flags, scripted
-- CheckItem/TakeItem/GiveItem, the CARD_KEY door, HM gates) reads the flat
-- save.inventory + Bag.order, never a menu selection.  So this mod keeps a
-- canonical "hidden bag" -- the full, unfiltered item order -- and every
-- pocket is only a *projection* of it.  Nothing is moved out of
-- save.inventory into pocket storage, so key items keep working no matter
-- which pocket the player closed the bag on: deposit a key item in the PC
-- and it leaves the hidden bag (and the KEY ITEMS pocket) because
-- Bag.remove wrote the real inventory; use a potion and the hidden count
-- matches the MEDICINE pocket because both read the same save.inventory.
--
-- The capacity half is three registry patches: the bag limit
-- (Data.constants.bagSize; Bag.capacity consults it), the per-stack limit
-- (Data.constants.itemStackCap; Bag.add and PlayerPC consult it), and the PC
-- storage cap (Data.field.pcItemCap; PlayerPC.pcFull consults it).
--
-- The pocket half rides the ui.screens registry: a registered "BagMenu"
-- wins over the builtin require fallback (src/ui/Screens.lua), so both
-- openers -- the start menu and the battle bag -- get the pocketed list.
-- The factory builds the vanilla bag (all its USE/TOSS/quantity/learn
-- flows stay engine-owned) and then decorates the returned ListMenu:
-- L/R pocket switching, pocket-safe SELECT reordering (pocket rows map
-- back onto the hidden bagOrder), a self-healing projection that re-applies
-- the pocket whenever an engine rebuild (e.g. after a toss) resets the rows
-- to the full bag, and the TAB/R3 sort prompt.  Input is wrapped at
-- game.ready so TAB (normally SELECT / swap-item) and R3 (unbound) reach
-- the bag; shift keys still do the vanilla SELECT item-swap.  The same
-- game.ready wrap catches the PC's WITHDRAW / DEPOSIT / TOSS lists where
-- they are built and restores the vanilla SELECT item-swap there too
-- (save.pcOrder for the storage lists, save.bagOrder for the deposit
-- list).
--
-- Both the bag pockets and the PC lists label machine items with their
-- full name ("TM14 BLIZZARD"); the "TM14 " part stays pinned and only the
-- move name scrolls as the horizontal ticker (the MoveRelearn pacing the
-- other option-row mods use) when it is too wide for the row window.

local Bag = require("src.inventory.Bag")
local USEFUL_STACK_CAP = 999
local nativeStackCapacity = Bag.stackCapacity

-- Older Gen 1 payloads do not expose Bag.stackCapacity to mods even though
-- the shared limit is still present in the merged constants table.  Keep the
-- shop guard compatible with both engine shapes.
local function stackCapacity(data)
  local native = type(nativeStackCapacity) == "function"
      and nativeStackCapacity(data) or nil
  local configured = data and data.constants and data.constants.itemStackCap
  if type(native) == "number" and native >= USEFUL_STACK_CAP then
    return math.floor(native)
  end
  if type(configured) == "number" and configured >= USEFUL_STACK_CAP then
    return math.floor(configured)
  end
  return USEFUL_STACK_CAP
end

-- Older Gen 1 payloads may still reject an existing stack at x99 inside
-- Bag.add, even after the constants patch.  Preserve the engine's normal
-- behavior first, then repair only that narrow existing-stack rejection.
local function installStackCapacityCompatibility()
  Bag.stackCapacity = stackCapacity
  if Bag.__usefulBagStackCapacity then return end
  Bag.__usefulBagStackCapacity = true

  -- Modern inventory splits x99 stacks through addTo; guard the total at
  -- the shared insertion boundary used by both the bag and item PC.
  if type(Bag.addTo) == "function" then
    local nativeAddTo = Bag.addTo
    Bag.addTo = function(store, order, id, qty, data, ...)
      local amount = tonumber(qty) or 1
      if amount > 0 and (store[id] or 0) + amount > stackCapacity(data) then return false end
      return nativeAddTo(store, order, id, qty, data, ...)
    end
  end

  local Quantity = require("src.ui.QuantityBox")
  if not Quantity.__usefulBagDigits then
    Quantity.__usefulBagDigits = true
    local nativeNew, nativeDraw = Quantity.new, Quantity.draw
    Quantity.new = function(game, opts)
      local menu = nativeNew(game, opts)
      menu.digits = math.max(2, #tostring(math.floor(menu.max)))
      return menu
    end
    Quantity.draw = function(self)
      if (self.digits or 2) <= 2 then return nativeDraw(self) end
      local Font = require("src.render.Font")
      local width = (self.unitPrice and 13 or 5) + self.digits - 2
      local x, y = 20 - width, 9
      Font.drawBox(x, y, width, 3)
      love.graphics.setColor(0, 0, 0, 1)
      Font.draw(("×%0" .. self.digits .. "d"):format(self.qty), (x + 1) * 8, (y + 1) * 8)
      if self.unitPrice then
        local value = "¥" .. tostring(math.max(0, math.floor(self.qty * self.unitPrice)))
        Font.draw(value, (x + width - 1) * 8 - Font.width(value), (y + 1) * 8)
      end
      love.graphics.setColor(1, 1, 1, 1)
    end
  end

  if type(Bag.add) ~= "function" then return end
  local vanillaAdd = Bag.add
  Bag.__usefulBagVanillaAdd = vanillaAdd
  Bag.add = function(save, id, qty, data)
    local inventory = save and save.inventory
    local before = inventory and inventory[id]
    local amount = tonumber(qty) or 1
    if vanillaAdd(save, id, qty, data) then return true end

    -- A new stack must continue to obey the engine's distinct-slot rules.
    -- Only an unchanged, already-existing positive stack can use this
    -- compatibility path.
    if type(before) ~= "number" or before < 1 or amount < 1
        or inventory[id] ~= before then
      return false
    end
    if before + amount > stackCapacity(data) then return false end
    inventory[id] = before + amount
    return true
  end
end

local SORT_MODE_LABELS = { "SORT BY NAME", "SORT BY COUNT" }

-- ------------------------------------------------ pure layer

local POCKETS = {
  { id = "items",    label = "ITEMS" },
  { id = "medicine", label = "MEDICINE" },
  { id = "balls",    label = "POKé BALLS" },
  { id = "tms",      label = "TMs / HMs" },
  { id = "battle",   label = "BATTLE ITEMS" },
  { id = "key",      label = "KEY ITEMS" },
}

local POCKET_INDEX = {}
for i, p in ipairs(POCKETS) do POCKET_INDEX[p.id] = i end

-- a battle bag skips the pockets whose items are unusable mid-battle:
-- TMs/HMs and KEY ITEMS are refused by ItemEffects ("isn't the time to
-- use that"), so they would only waste L/R presses.  When the bag opens
-- in battle it lands on the first non-empty pocket in BATTLE_START_PRIORITY.
local BATTLE_UNUSABLE = { tms = true, key = true }
local BATTLE_START_PRIORITY = { "battle", "balls", "medicine", "items" }

-- fallback sets: the real ROM import flags key items via KeyItemFlags
-- (def.keyItem) and TMs/HMs via def.machine, so these only classify
-- fixture/mod-added items that carry no such flag.  They mirror the same
-- sets the engine hardcodes (ItemEffects.BALLS, item_effects.asm).
--
-- KEY_ITEMS is the game's own KeyItemFlags table (ROM symbols; identical
-- in pret/pokered and pret/pokeyellow data/items/key_items.asm) -- the
-- same bytes the engine's RomExtractor reads to stamp def.keyItem.  In
-- the real data def.keyItem is authoritative; this set mirrors it so
-- fixture/mod items with no flag classify the same way.  The eight badges
-- are flagged too but never appear in the bag (Bag.isBadge excludes them).
-- Note ESCAPE_ROPE and EXP_ALL are NOT key items per the game.
local KEY_ITEMS = {
  TOWN_MAP = true, BICYCLE = true, SURFBOARD = true, SAFARI_BALL = true,
  POKEDEX = true,
  BOULDERBADGE = true, CASCADEBADGE = true, THUNDERBADGE = true,
  RAINBOWBADGE = true, SOULBADGE = true, MARSHBADGE = true,
  VOLCANOBADGE = true, EARTHBADGE = true,
  OLD_AMBER = true, DOME_FOSSIL = true, HELIX_FOSSIL = true,
  SECRET_KEY = true, ITEM_2C = true, BIKE_VOUCHER = true,
  CARD_KEY = true,
  S_S_TICKET = true, GOLD_TEETH = true, COIN_CASE = true, OAKS_PARCEL = true,
  ITEMFINDER = true, SILPH_SCOPE = true, POKE_FLUTE = true, LIFT_KEY = true,
  OLD_ROD = true, GOOD_ROD = true, SUPER_ROD = true,
}

local MEDICINE = {
  POTION = true, SUPER_POTION = true, HYPER_POTION = true, MAX_POTION = true,
  FRESH_WATER = true, SODA_POP = true, LEMONADE = true,
  ANTIDOTE = true, BURN_HEAL = true, ICE_HEAL = true, AWAKENING = true,
  PARLYZ_HEAL = true, FULL_HEAL = true, FULL_RESTORE = true,
  REVIVE = true, MAX_REVIVE = true, RARE_CANDY = true,
  HP_UP = true, PROTEIN = true, IRON = true, CARBOS = true, CALCIUM = true,
  ETHER = true, MAX_ETHER = true, ELIXER = true, MAX_ELIXER = true, PP_UP = true,
}

local BATTLE_ITEMS = {
  X_ATTACK = true, X_DEFEND = true, X_SPEED = true, X_SPECIAL = true,
  X_ACCURACY = true, DIRE_HIT = true, GUARD_SPEC = true, POKE_DOLL = true,
}

local BALLS = {
  POKE_BALL = true, GREAT_BALL = true, ULTRA_BALL = true,
  MASTER_BALL = true, SAFARI_BALL = true,
}

local function isMachine(id, def)
  if def and def.machine then return true end
  local head = id:sub(1, 2)
  return head == "TM" or head == "HM"
end

-- Which pocket an item id lives in.  The Poké Flute is the contextual
-- exception: it is usable in battle, so it belongs with BATTLE ITEMS there,
-- while it remains a KEY ITEM in the overworld.  All other key items win (a
-- key item is never also a TM or ball), then TMs/HMs, balls, medicine, battle
-- items, and everything else falls into the generic ITEMS pocket.
local function classify(data, id, inBattle)
  local def = data.items and data.items[id]
  if id == "POKE_FLUTE" and inBattle then return "battle" end
  if (def and def.keyItem) or KEY_ITEMS[id] then return "key" end
  if isMachine(id, def) then return "tms" end
  if (def and def.ball) or BALLS[id] then return "balls" end
  if MEDICINE[id] then return "medicine" end
  if BATTLE_ITEMS[id] then return "battle" end
  return "items"
end

-- The ids in `order` (an array of item ids, e.g. Bag.order(save)) that
-- belong to a pocket.  Keeps the incoming order, so pockets follow the
-- bag's current sort (acquisition order, or the TAB/R3 name/count sort).
local function pocketItems(order, data, pocketId, inBattle)
  local out = {}
  for _, id in ipairs(order) do
    if classify(data, id, inBattle) == pocketId then table.insert(out, id) end
  end
  return out
end

-- THE HIDDEN BAG: the canonical flat bag, acquisition-ordered, always
-- complete.  Pockets are projections of this; engine logic reads it via
-- save.inventory.  Bag.order maintains it incrementally, so PC deposits,
-- uses and tosses all land here first.
local function hiddenOrder(save)
  return Bag.order(save)
end

-- The id of the pocket `dir` steps away from `from` (a POCKETS index),
-- wrapping around at both ends.  dir = -1 is LEFT, +1 is RIGHT.
local function adjacentPocket(from, dir)
  local n = #POCKETS
  return ((from - 1 + dir) % n) + 1
end

-- Move a pocketed list to the neighbouring pocket (wraps).  In a battle
-- bag (`list.__battle` set) the unusable pockets are skipped, so L/R
-- cycles only through the battle-usable ones.  Mutates the ListMenu in
-- place: clears any pending SELECT-swap and re-projects its rows from the
-- hidden bag.  `list.__project` is installed by decorate().
local function switchPocket(list, dir)
  list.swapIndex = nil
  local battle = list.__battle
  local i = list.__pocketIndex
  repeat
    i = adjacentPocket(i, dir)
  until (not battle or not BATTLE_UNUSABLE[POCKETS[i].id])
    or i == list.__pocketIndex -- safety: never spin forever
  list.__pocketIndex = i
  list.__project()
  list.index = 1
end

-- Pure: the sorted id list for `mode` ("name" | "count") over the hidden
-- bag.  The name sort compares item names with an id tiebreak (stable);
-- the count sort puts the biggest stacks first, id tiebreak.  Returns a
-- fresh list -- the save's bagOrder is left untouched.
local function computeOrder(save, data, mode)
  local order = {}
  for _, id in ipairs(hiddenOrder(save)) do table.insert(order, id) end
  local inv = save.inventory
  if mode == "count" then
    table.sort(order, function(a, b)
      local ca, cb = inv[a] or 0, inv[b] or 0
      if ca == cb then return a < b end
      return ca > cb
    end)
  else -- "name"
    table.sort(order, function(a, b)
      local da, db = data.items[a], data.items[b]
      local na, nb = (da and da.name) or a, (db and db.name) or b
      if na == nb then return a < b end
      return na < nb
    end)
  end
  return order
end

-- Applies a sort to the live hidden bag: Bag.order returns save.bagOrder
-- itself, so sorting it in place is the whole write.
local function applySort(save, data, mode)
  local order = hiddenOrder(save)
  if mode == "count" then
    local inv = save.inventory
    table.sort(order, function(a, b)
      local ca, cb = inv[a] or 0, inv[b] or 0
      if ca == cb then return a < b end
      return ca > cb
    end)
  else
    table.sort(order, function(a, b)
      local da, db = data.items[a], data.items[b]
      local na, nb = (da and da.name) or a, (db and db.name) or b
      if na == nb then return a < b end
      return na < nb
    end)
  end
end

-- The PC storage's acquisition order (like Bag.order): the ids of
-- save.pcItems in display order, persisted in save.pcOrder (GenSave
-- encodes/decodes it alongside pcItems).  Rebuilt sorted once for saves
-- from before the order existed, then maintained incrementally, pruning
-- stale ids (a toss or a withdraw that emptied a stack) and appending new
-- deposits at the end.
local function pcOrder(save)
  local order = save.pcOrder
  if not order then
    order = {}
    for id in pairs(save.pcItems or {}) do table.insert(order, id) end
    table.sort(order)
    save.pcOrder = order
  end
  local seen = {}
  for i = #order, 1, -1 do
    local id = order[i]
    if not save.pcItems[id] or seen[id] then
      table.remove(order, i)
    else
      seen[id] = true
    end
  end
  for id in pairs(save.pcItems or {}) do
    if not seen[id] then table.insert(order, id) end
  end
  return order
end

-- Swap two ids inside an order list (save.pcOrder / save.bagOrder); the
-- SELECT item-swap of the PC lists lands here, writing the real order the
-- engine and GenSave read.  No-op when either id is missing from the list.
local function swapOrder(order, a, b)
  if a == b then return end
  local ia, ib
  for k, id in ipairs(order) do
    if id == a then ia = k elseif id == b then ib = k end
    if ia and ib then break end
  end
  if ia and ib then order[ia], order[ib] = order[ib], order[ia] end
end

-- Re-sort a ListMenu's rows ({ value = item id, ... }) to follow `order`.
-- The rows are the current list's ids (never the hidden bag's full set),
-- so the rank lookup drives the sort; unknown ids sink to the end, id
-- tiebreak keeps it deterministic.
local function reorderItems(items, order)
  local rank = {}
  for i, id in ipairs(order) do rank[id] = i end
  table.sort(items, function(a, b)
    local ra, rb = rank[a.value], rank[b.value]
    if ra == rb then return a.value < b.value end
    return (ra or math.huge) < (rb or math.huge)
  end)
end

-- Ticker pacing (the MoveRelearn name ticker): hold at each end so the
-- player can read the whole name, scroll at 16px/s (half a second per
-- glyph).  The same pacing the other option-row mods use.
local TICKER_HOLD = 1.6
local TICKER_SPEED = 16

-- Pure (mod.exports.tickerOffset for headless tests): horizontal offset
-- for an overflowing label at time t (seconds).  Cycle: hold at 0, scroll
-- out to -overflow, hold, scroll back to 0.  Labels that fit (overflow <=
-- 0) are static.
local function tickerOffset(t, overflow)
  if not (overflow and overflow > 0) then return 0 end
  local scroll = overflow / TICKER_SPEED
  local cycle = 2 * TICKER_HOLD + 2 * scroll
  local p = t % cycle
  if p < TICKER_HOLD then return 0 end
  p = p - TICKER_HOLD
  if p < scroll then return -p * TICKER_SPEED end
  p = p - scroll
  if p < TICKER_HOLD then return -overflow end
  p = p - TICKER_HOLD
  return -overflow + p * TICKER_SPEED
end

-- A list-row label for an item id: the plain name, or the full machine
-- name ("TM14 BLIZZARD") when the item is a TM/HM (def.machine) -- the
-- bag and PC otherwise show only "TM14".  Returns (label, prefixW, prefix,
-- move) where prefix is the "TM14 " part that stays pinned and move is the
-- scrollable name.
local function labelForItem(data, id)
  local def = data.items and data.items[id]
  local name = def and def.name or id
  if def and def.machine then
    local moveId = def.machine.move
    local move = moveId and data.moves and data.moves[moveId]
    local moveName = (move and move.name) or moveId or ""
    local prefix = name .. " "
    local Font = require("src.render.Font")
    return name .. " " .. moveName, Font.width(prefix), prefix, moveName
  end
  return name, 0, nil, nil
end

-- Ticker geometry for a list row: nil when the label fits the window
-- between the label start (16px) and the count value (right-aligned at
-- 152 - width(right), one glyph of gap).  The GB font is a flat 8px per
-- glyph, so the window is (128 - width(right))px.  For a machine row the
-- scrollable part is the move name only: it starts after the pinned
-- prefix (prefixW) and the overflow is the whole label's overflow (the
-- suffix's own overflow is the same number).
local function tickerFor(label, right, prefixW)
  local Font = require("src.render.Font")
  local window = 128 - Font.width(right or "")
  local w = Font.width(label)
  if w <= window then return nil end
  local prefix = prefixW or 0
  return { x = 16 + prefix, w = window - prefix, overflow = w - window }
end

-- ------------------------------------------------ runtime layer

-- TAB/R3 opens a SORT BY NAME / SORT BY COUNT prompt over the bag; both
-- options rewrite the hidden bag's order and re-project the current
-- pocket.  Defined before decorate() because the bag's update closure
-- calls it (Lua binds locals lexically at definition time).
local function openSortPrompt(list, game, session)
  session.sortOpen = true
  local Menu = require("src.ui.Menu")
  game.stack:push(Menu.new(game, {
    { label = SORT_MODE_LABELS[1], onSelect = function()
        session.sortOpen = false
        applySort(game.save, game.data, "name")
        require("src.core.Sound").play(game.data, "Swap")
        list.__project()
      end },
    { label = SORT_MODE_LABELS[2], onSelect = function()
        session.sortOpen = false
        applySort(game.save, game.data, "count")
        require("src.core.Sound").play(game.data, "Swap")
        list.__project()
      end },
  }, { tx = 10, ty = 10, onCancel = function() session.sortOpen = false end }))
end

-- Full TM/HM labels ("TM15 HYPER BEAM") can be wider than a list row's
-- label window, which the vanilla ListMenu.draw leaves unclipped (the text
-- bleeds over the count or the box edge).  Decorate the list with the
-- horizontal name ticker (the MoveRelearn pacing from the other mods):
-- rows whose label overflows get a scissored, time-driven scroll; rows
-- that fit draw exactly as before.  A machine row pins its "TM14 " prefix
-- and scrolls only the move name; every other row scrolls as a whole.
-- Geometry recomputes on every draw so rebuilds (pocket switches, tosses,
-- count changes) stay correct.  A stale blank from an interrupted draw is
-- restored first so a later frame never redraws a permanently-empty label.
local function decorateTickers(list)
  local vanillaUpdate = list.update
  list.update = function(self, dt)
    for _, it in ipairs(self.items) do
      if it.ticker then it.tick = (it.tick or 0) + (dt or 0) end
    end
    return vanillaUpdate(self, dt)
  end

  local vanillaDraw = list.draw
  list.draw = function(self, ...)
    for _, it in ipairs(self.items) do
      if it._label then
        it.label = it._label
        it._label = nil
      end
    end
    local Font = require("src.render.Font")
    local ticked = {}
    for i, it in ipairs(self.items) do
      local ticker = tickerFor(it.label, it.right, it.prefixW)
      it.ticker = ticker
      if ticker then
        it._label = it.label
        it.label = "" -- blanked for the vanilla pass
        ticked[#ticked + 1] = { item = it, index = i, prefix = it.prefix }
      end
    end
    vanillaDraw(self, ...)
    local g = love and love.graphics
    for _, e in ipairs(ticked) do
      local it = e.item
      it.label = it._label
      it._label = nil
      if g and g.setScissor then
        local slot = e.index - (self.scroll or 0)
        if slot >= 1 and slot <= (self.rows or 7) then
          local y = 8 + slot * 16
          -- the TM/number part stays pinned at the row start
          if e.prefix then Font.draw(e.prefix, 16, y) end
          g.setScissor(it.ticker.x, y, it.ticker.w, 8)
          -- scroll only the move name -- never the label again, or the
          -- pinned "TM14 " would duplicate it
          Font.draw(it.move or it.label,
                    it.ticker.x + tickerOffset(it.tick or 0, it.ticker.overflow), y)
          g.setScissor()
        end
      end
    end
  end
end

-- The screen Useful Bag presents is always the topmost state on the LIVE
-- stack that carries one of the mod's markers.  Deriving it from the stack
-- rather than trusting the value cached when a screen was built or pushed is
-- what lets an overlay disappear the same frame its state leaves the stack --
-- the engine's own B / onCancel pop, a stack clear on a save load, and an
-- item flow that closes the bag while a child is still on top all move the
-- marker with the stack.  A marker that outlived its state drew a blank
-- fullscreen panel that no input could dismiss.
local function refreshPresentation(session, game)
  local stack = game and game.stack
  local states = stack and stack.states
  local active, index
  if type(states) == "table" then
    for i = #states, 1, -1 do
      local state = states[i]
      if state and state.__usefulBagKind then
        active, index = state, i
        break
      end
    end
  end
  session.active = active
  if active then
    session.game = active.game or game or session.game
  end
  return active, index
end

-- Decorate a vanilla bag ListMenu with pockets, L/R navigation, a
-- pocket-safe SELECT reorder and the sort/wrap behavior.  `session` is the
-- shared bag-session state (one bag open at a time) that the game.ready
-- Input wraps write their TAB/R3 edges into.  `opts` is the bag's open
-- opts: a truthy `opts.battle` (BattleState) marks a battle bag, which
-- opens on BATTLE ITEMS and skips the unusable pockets when cycling.
local function decorate(list, game, session, opts)
  -- pocket view starts on ITEMS
  session.game = game
  list.__usefulBagKind = "bag"
  list.__pocketIndex = 1
  list.wrap = true -- Up on the first / Down on the last item wraps
  list.__battle = opts and opts.battle or nil -- battle bags cycle tighter

  -- Re-project the visible pocket from the hidden bag, preserving the
  -- currently selected item when it is still in this pocket.
  local function project()
    local pocket = POCKETS[list.__pocketIndex]
    local order = hiddenOrder(game.save)
    local curId = list.items[list.index] and list.items[list.index].value
    local items, ids = {}, {}
    for _, id in ipairs(order) do
      if classify(game.data, id, list.__battle and true or false) == pocket.id then
        table.insert(ids, id)
        local label, prefixW, prefix, move = labelForItem(game.data, id)
        table.insert(items, {
          value = id,
          label = label,
          prefix = prefix,
          prefixW = prefixW,
          move = move,
          right = "x" .. (game.save.inventory[id] or 0),
        })
      end
    end
    list.items, list.__pocketIds = items, ids
    list.title = pocket.label
    if curId then
      for i, id in ipairs(ids) do
        if id == curId then list.index = i break end
      end
    end
    list.index = math.max(1, math.min(list.index, #items))
  end
  list.__project = project

  -- Swap two pocket rows by translating them back onto the hidden bag's
  -- acquisition order (the engine's onSelectKey swaps `order[l.index]`
  -- directly, which only works because its rows are the full bag).
  local function swapRows(i, j)
    local a, b = list.__pocketIds[i], list.__pocketIds[j]
    if not a or not b then return end
    local order = hiddenOrder(game.save)
    local ia, ib
    for k, id in ipairs(order) do
      if id == a then ia = k elseif id == b then ib = k end
      if ia and ib then break end
    end
    if ia and ib then order[ia], order[ib] = order[ib], order[ia] end
  end

  local vanillaSelect = list.onSelectKey
  list.onSelectKey = function(item, l)
    if not item then return end
    if not l.swapIndex then
      l.swapIndex = l.index
      return
    end
    swapRows(l.swapIndex, l.index)
    l.swapIndex = nil
    require("src.core.Sound").play(game.data, "Swap")
    project()
  end

  local vanillaChoose = list.onChoose
  list.onChoose = function(item, l)
    if l.swapIndex then -- A also completes a pending swap
      swapRows(l.swapIndex, l.index)
      l.swapIndex = nil
      require("src.core.Sound").play(game.data, "Swap")
      project()
      return
    end
    return vanillaChoose(item, l)
  end

  local vanillaUpdate = list.update
  list.update = function(self, dt)
    -- L/R cycle the pockets (wraps); the vanilla list ignores L/R unless
    -- pageJump is on, so these presses are ours to claim
    local input = self.game and self.game.input
    if input and input.wasPressed then
      local left = input:wasPressed("left")
      local right = input:wasPressed("right")
      if left or right then
        switchPocket(self, left and -1 or 1)
        require("src.core.Sound").play(game.data, "Press_AB")
      end
    end
    -- the TAB/R3 sort edge waits for the bag's own update (a stale edge
    -- from a press while another screen was on top is dropped)
    if session.wantSort and session.active == self and not session.sortOpen
       and self.game.stack:top() == self then
      session.wantSort = false
      self.swapIndex = nil -- a pending SELECT-swap would go stale
      openSortPrompt(self, game, session)
    end
    -- self-heal: engine-side rebuilds (the TOSS confirm) reset the rows to
    -- the full hidden bag; re-project when the rows no longer match the
    -- current pocket so the pocket never silently widens
    local matches = #self.items == #self.__pocketIds
    if matches then
      for i = 1, #self.items do
        if self.items[i].value ~= self.__pocketIds[i] then
          matches = false
          break
        end
      end
    end
    if not matches then self.__project() end
    return vanillaUpdate(self, dt)
  end

  local vanillaClose = list.close
  list.close = function(self, ...)
    if self.__battle then
      session.lastBattlePocket = POCKETS[self.__pocketIndex].id
    end
    local result = vanillaClose(self, ...)
    -- Derive the presenter from what actually happened: ListMenu:close only
    -- pops when this list is the top state, so a close requested from under a
    -- child (an item flow) must NOT drop the overlay while the list is still
    -- on the stack.
    refreshPresentation(session, self.game or game)
    return result
  end

  -- full TM/HM labels scroll when they overflow their row window
  decorateTickers(list)

  session.active = list
  session.wantSort = false -- presses before the bag opened do not carry over
  -- A battle bag prefers the last runtime battle pocket when it still has
  -- usable items, then falls back to the normal battle priority.  Cycling
  -- skips TMs / HMs and KEY ITEMS via switchPocket.
  if list.__battle then
    local preferred = session.lastBattlePocket
    local restored = false
    if preferred and not BATTLE_UNUSABLE[preferred] then
      list.__pocketIndex = POCKET_INDEX[preferred]
      project()
      restored = #list.items > 0
    end
    if not restored then
      for _, pid in ipairs(BATTLE_START_PRIORITY) do
        list.__pocketIndex = POCKET_INDEX[pid]
        project()
        if #list.items > 0 then break end
      end
    end
  else
    project()
  end
  return list
end

-- The PC's three item lists are plain engine ListMenus (PlayerPC.lua) that
-- never pass onSelectKey, so the vanilla SELECT item-swap (DisplayListMenuID
-- watches PAD_SELECT -> HandleItemListSwapping) is missing there.  Decorate
-- the WITHDRAW / DEPOSIT / TOSS lists with it: SELECT marks a row (hollow
-- cursor), a second SELECT -- or A -- swaps it with the cursor row.
-- Withdraw and Toss reorder the PC storage (save.pcOrder); Deposit reorders
-- the bag (save.bagOrder) because that list shows the bag, matching the
-- original.  The list opens in the stored order (not the engine's
-- alphabetical sort) so a reorder persists visibly across reopening.
-- Current engines identify these lists with the localization-independent
-- `state.kind` ids documented for screen.render_visible; older Gen 1
-- payloads only carried a title, so keep both spellings.  Matching on the
-- title alone was a silent failure on a build that supplies `kind`: the
-- list was never decorated, so it lost both the fullscreen presenter and
-- the SELECT swap.
local PC_LIST_KINDS = {
  pc_item_withdraw = true,
  pc_item_deposit = true,
  pc_item_toss = true,
}
local PC_LIST_TITLES = {
  ["WITHDRAW ITEM"] = true,
  ["DEPOSIT ITEM"] = true,
  ["TOSS ITEM"] = true,
}
-- The fullscreen presenter prints a header; a kind-identified list arrives
-- with no title (the localized prompt lives in its footer), so give it the
-- same display title the older title-carrying builds had.
local PC_LIST_KIND_TITLES = {
  pc_item_withdraw = "WITHDRAW ITEM",
  pc_item_deposit = "DEPOSIT ITEM",
  pc_item_toss = "TOSS ITEM",
}

local function isPcItemList(list)
  return list and (PC_LIST_KINDS[list.kind] or PC_LIST_TITLES[list.title]) or false
end

local function isDepositList(list)
  return list and (list.kind == "pc_item_deposit"
    or list.title == "DEPOSIT ITEM")
end

local function decoratePcList(list, game, session)
  session.game = game
  session.active = list
  list.__usefulBagKind = "pc"
  list.title = list.title or PC_LIST_KIND_TITLES[list.kind] or list.kind
  local order = isDepositList(list)
    and Bag.order(game.save)   -- the deposit list shows the bag
    or pcOrder(game.save)      -- withdraw / toss show the PC storage
  list.__order = order
  reorderItems(list.items, order)

  -- the engine's buildItems labels machine items with just "TM14"; show
  -- the full "TM14 BLIZZARD" like the bag (prefix stays pinned when the
  -- move name ticks)
  for _, it in ipairs(list.items) do
    local label, prefixW, prefix, move = labelForItem(game.data, it.value)
    it.label, it.prefix, it.prefixW, it.move = label, prefix, prefixW, move
  end
  -- and let labels that overflow their row window scroll as a ticker
  decorateTickers(list)

  list.onSelectKey = function(item, l)
    if not item then return end
    if not l.swapIndex then
      l.swapIndex = l.index
      return
    end
    swapOrder(l.__order, l.items[l.swapIndex].value, l.items[l.index].value)
    l.swapIndex = nil
    require("src.core.Sound").play(game.data, "Swap")
    reorderItems(l.items, l.__order)
  end

  local vanillaChoose = list.onChoose
  list.onChoose = function(item, l)
    if l.swapIndex then -- A also completes a pending swap
      swapOrder(l.__order, l.items[l.swapIndex].value, l.items[l.index].value)
      l.swapIndex = nil
      require("src.core.Sound").play(game.data, "Swap")
      reorderItems(l.items, l.__order)
      return
    end
    return vanillaChoose(item, l)
  end
end

-- ------------------------------------------------ standalone presentation

-- Useful Bag owns its presentation so it does not need a companion UI mod.
-- The engine keeps ListMenu as the input/state owner; these hooks only hide
-- its 160x144 draw and paint the current bag state after the normal frame.
local standaloneFonts = {}
local STANDALONE_BASE_WIDTH = 640
local STANDALONE_BASE_HEIGHT = 480
local STANDALONE_TEXT_BASE_WIDTH = 320
local STANDALONE_TEXT_BASE_HEIGHT = 240
local STANDALONE_TEXT_MAX_SCALE = 3
local STANDALONE_PORTRAIT_TEXT_MAX_SCALE = 4

local function standaloneScale(width, height)
  return math.max(1, math.floor(math.min(
    width / STANDALONE_BASE_WIDTH, height / STANDALONE_BASE_HEIGHT)))
end

local function standaloneTextScale(width, height)
  -- Desktop and landscape layouts still use the fitting scale so text never
  -- grows beyond the available short axis.  Portrait layouts have a tall
  -- reading surface and a narrow width; flooring the height-limited ratio
  -- leaves phone-sized viewports at 1x even when their rows are visibly tiny.
  -- Use the width-derived integer step there, rounding up so a viewport just
  -- wider than the 320px text reference gets the next readable grid size.
  local raw
  if height > width then
    raw = math.ceil(width / STANDALONE_TEXT_BASE_WIDTH)
    return math.max(1, math.min(STANDALONE_PORTRAIT_TEXT_MAX_SCALE, raw))
  else
    raw = math.floor(math.min(
      width / STANDALONE_TEXT_BASE_WIDTH,
      height / STANDALONE_TEXT_BASE_HEIGHT))
  end
  return math.max(1, math.min(STANDALONE_TEXT_MAX_SCALE, raw))
end

local function standaloneClamp(value, lo, hi)
  return math.max(lo, math.min(hi, value))
end

local function standalonePixel(value)
  return math.floor(value + 0.5)
end

local function standaloneFontSize(size)
  local Font = require("src.render.Font")
  local em = Font.PLAINPIXEL_SIZE or 15
  return math.max(em, math.floor(size / em + 0.5) * em)
end

local function standaloneFont(size)
  size = standaloneFontSize(size)
  if standaloneFonts[size] then return standaloneFonts[size] end
  local Font = require("src.render.Font")
  local ok, font = pcall(love.graphics.newFont, Font.PLAINPIXEL, size,
    "mono", 1)
  if not ok or not font then font = love.graphics.newFont(size) end
  if font.setFilter then font:setFilter("nearest", "nearest") end
  standaloneFonts[size] = font
  return font
end

local function standaloneTitleSize(textScale)
  return standaloneFontSize(20 * textScale)
end

local function standaloneFooterText(text)
  if type(text) ~= "string" then return text end
  return (text:gsub("[\r\n]+", " "))
end

local function standaloneHeaderGap(pad)
  return math.max(2, standalonePixel(pad * 0.5))
end

local function standaloneDividerGap(pad)
  return math.max(1, standalonePixel(pad * 0.25))
end

local function standaloneHeaderHeight(titleHeight, pad)
  return standaloneHeaderGap(pad) + standalonePixel(titleHeight)
    + standaloneDividerGap(pad)
end

local function standaloneTickerOffset(time, overflow, speed)
  if overflow <= 0 then return 0 end
  local hold = 1.25
  local travel = overflow / speed
  local cycle = hold * 2 + travel * 2
  local position = time % cycle
  if position < hold then return 0 end
  position = position - hold
  if position < travel then return -math.floor(position * speed + 0.5) end
  position = position - travel
  if position < hold then return -overflow end
  return -overflow + math.floor((position - hold) * speed + 0.5)
end

local function standaloneFullscreenEnabled(mod)
  return mod.options:get("fullscreen_menu") ~= false
end

local function standaloneViewport(viewport)
  if viewport and viewport.safe then
    local safe = viewport.safe
    return safe.x or 0, safe.y or 0,
      math.max(1, safe.width or viewport.width or 1),
      math.max(1, safe.height or viewport.height or 1)
  end
  local width = viewport and viewport.width or love.graphics.getWidth()
  local height = viewport and viewport.height or love.graphics.getHeight()
  return 0, 0, math.max(1, width), math.max(1, height)
end

local function standaloneDrawText(font, text, x, y, color)
  love.graphics.setFont(font)
  love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
  love.graphics.print(tostring(text or ""), x, y)
end

local function standaloneSetScissor(transform, x, y, width, height)
  if transform then
    love.graphics.setScissor(
      standalonePixel(transform.x + x * transform.sx),
      standalonePixel(transform.y + y * transform.sy),
      math.max(1, standalonePixel(width * transform.sx)),
      math.max(1, standalonePixel(height * transform.sy)))
  else
    love.graphics.setScissor(x, y, width, height)
  end
end

local function standaloneFitFooter(font, text, maxWidth)
  if font:getWidth(text) <= maxWidth then return text end
  local suffix = ".."
  for length = #text - 1, 1, -1 do
    local candidate = text:sub(1, length) .. suffix
    if font:getWidth(candidate) <= maxWidth then return candidate end
  end
  return ""
end

local function standaloneItemIndicator(list)
  local items = list.items or {}
  local count = #items
  if count == 0 then return "0 / 0" end
  local current = math.floor(tonumber(list.index) or 1)
  current = standaloneClamp(current, 1, count)
  return ("%d / %d"):format(current, count)
end

local function standaloneListLayout(panelH, textScale, titleHeight, bodyHeight,
  footerHeight, compact)
  local pad = compact and 6 or 12 * textScale
  local titleGap = standaloneHeaderGap(pad)
  local headerH = standaloneHeaderHeight(titleHeight, pad)
  local footerH = standalonePixel(footerHeight) + pad
  local dividerSpan = math.max(1, panelH - headerH - footerH)
  local baseGap = compact and 2 or math.max(4, standalonePixel(pad * 0.35))
  local listHeight = math.max(1, dividerSpan - baseGap * 2)
  local minRowH = math.max(1, standalonePixel(bodyHeight + 2))
  return {
    pad = pad,
    titleGap = titleGap,
    headerH = headerH,
    footerH = footerH,
    dividerSpan = dividerSpan,
    baseGap = baseGap,
    listHeight = listHeight,
    minRowH = minRowH,
    fitsFour = listHeight >= minRowH * 4,
  }
end

local function standaloneTextScaleForRows(maxScale, panelH, compact, measure)
  for textScale = math.max(1, math.floor(maxScale or 1)), 1, -1 do
    local titleHeight, bodyHeight, footerHeight = measure(textScale)
    local layout = standaloneListLayout(panelH, textScale,
      titleHeight, bodyHeight, footerHeight, compact)
    if layout.fitsFour then return textScale end
  end
  return 1
end

-- The compact presenter is a 160x144 popup, so reserve four slots in its
-- native list area. Fullscreen keeps its own established responsive rhythm.
local function standaloneCompactRowLayout(listHeight)
  local visible = 4
  return {
    visible = visible,
    rowHeight = math.max(1, math.floor(listHeight / visible)),
  }
end

local function standaloneDrawBag(game, viewport, list, transform)
  local G = love.graphics
  local compact = transform and transform.compact or false
  local vx, vy, vw, vh = standaloneViewport(viewport)
  local scale = standaloneScale(vw, vh)
  local maxTextScale = standaloneTextScale(vw, vh)
  local margin = compact and 2 or 8 * scale
  local px, py = vx + margin, vy + margin
  local panelW, panelH = vw - margin * 2, vh - margin * 2
  local textScale = standaloneTextScaleForRows(maxTextScale, panelH, compact,
    function(candidate)
      local titleFont = standaloneFont(standaloneTitleSize(candidate))
      local bodyFont = standaloneFont(15 * candidate)
      local footerScale = math.max(1,
        math.floor(candidate * 2 / 3 + 0.5))
      local footerFont = standaloneFont(15 * footerScale)
      return titleFont:getHeight(), bodyFont:getHeight(), footerFont:getHeight()
    end)
  local pad = compact and 6 or 12 * textScale
  local titleSize = standaloneTitleSize(textScale)
  local bodySize = 15 * textScale
  local footerScale = math.max(1, math.floor(textScale * 2 / 3 + 0.5))
  local footerSize = 15 * footerScale
  local titleFont, bodyFont, footerFont = standaloneFont(titleSize),
    standaloneFont(bodySize), standaloneFont(footerSize)
  local layout = standaloneListLayout(panelH, textScale, titleFont:getHeight(),
    bodyFont:getHeight(), footerFont:getHeight(), compact)
  local titleGap = layout.titleGap
  local headerH = layout.headerH
  local money = ("¥%d"):format(math.max(0, math.floor(tonumber(
    game.save and game.save.money or 0) or 0)))
  local moneyW = math.floor(footerFont:getWidth(money) + 0.5)
  local footer = list.footer and standaloneFooterText(list.footer) or ""
  if type(footer) ~= "string" then footer = "" end
  -- BagMenu supplies the money as its native footer; money is rendered in the
  -- stable right column here, so use the selected-item indicator on the left.
  local controlFooter = footer == "" or footer == money
  if footer == money then footer = "" end
  local footerGap = compact and 4 or math.max(16, standalonePixel(pad * 0.75))
  if controlFooter then footer = standaloneItemIndicator(list) end
  local footerH = layout.footerH
  local dividerSpan = layout.dividerSpan
  local baseGap = layout.baseGap
  local minRowH = layout.minRowH
  local footerWidth = math.max(1,
    panelW - pad * 2 - moneyW - footerGap)

  -- The compact presenter is still drawn from the native 160x144 menu grid.
  -- A 20px row keeps the native footer and header zones intact.  On a small
  -- fullscreen viewport, text scale is lowered first so four readable rows
  -- fit without making the pixel font overlap itself.
  local listHeight = layout.listHeight
  local rowH, visible
  if compact then
    local rows = standaloneCompactRowLayout(listHeight)
    rowH, visible = rows.rowHeight, rows.visible
  else
    rowH = 24 * textScale
    if listHeight < rowH * 4 then
      rowH = math.max(minRowH, math.floor(listHeight / 4))
    end
    visible = math.max(1, math.floor(listHeight / rowH))
  end
  -- Use the same integer gap above the first row and below the last visible
  -- row.  Any odd leftover pixel is kept on the lower side of the list.
  local listGap = math.max(baseGap,
    math.floor((dividerSpan - visible * rowH) / 2))
  local count = #list.items
  local selected = standaloneClamp(list.index or 1, 1, math.max(1, count))
  local scroll = standaloneClamp(list.scroll or 0, 0,
    math.max(0, count - visible))
  if selected <= scroll then scroll = selected - 1 end
  if selected > scroll + visible then scroll = selected - visible end

  G.push("all")
  G.origin()
  -- The engine can leave a scissor set (its letterbox/playfield clip); the
  -- presenter owns the whole window, so start from an unclipped state.
  G.setScissor()
  if transform then
    G.translate(transform.x, transform.y)
    G.scale(transform.sx, transform.sy)
  end
  G.setColor(0, 0, 0, 1)
  G.rectangle("fill", vx, vy, vw, vh)
  G.setColor(1, 1, 1, 1)
  G.rectangle("fill", px, py, panelW, panelH)

  standaloneDrawText(titleFont, list.title or "ITEMS", px + pad,
    py + titleGap, { 0, 0, 0, 1 })
  G.setColor(0.72, 0.72, 0.72, 1)
  G.rectangle("fill", px + pad, py + headerH,
    math.max(1, panelW - pad * 2), 2)

  local now = love.timer and love.timer.getTime and love.timer.getTime() or os.clock()
  local rightGap = math.max(16, standalonePixel(bodySize * 0.65))
  local leftX = standalonePixel(px + pad + bodySize * 0.9)
  local listRight = standalonePixel(px + panelW - pad)
  for slot = 1, visible do
    local index = scroll + slot
    local item = list.items[index]
    if not item then break end
    local rowY = py + headerH + listGap + (slot - 1) * rowH
    local rowSelected = index == selected
    if rowSelected then
      G.setColor(0.93, 0.93, 0.93, 1)
      G.rectangle("fill", standalonePixel(px + pad * 0.55), rowY + 4,
        standalonePixel(panelW - pad * 1.1), rowH - 8)
      G.setColor(0, 0, 0, 1)
      local cursorX = standalonePixel(px + pad * 0.68)
      local cursorY = standalonePixel(rowY + rowH * 0.5)
      local arrowW = math.max(8, standalonePixel(bodySize * 0.65))
      local arrowH = math.max(6, standalonePixel(bodySize * 0.5))
      local stemH = math.max(3, standalonePixel(bodySize * 0.2))
      local headW = math.max(4, arrowW - math.floor(stemH / 2))
      local headX = cursorX + arrowW - headW
      G.rectangle("fill", cursorX, cursorY - math.floor(stemH / 2),
        math.max(1, headX - cursorX), stemH)
      -- Build the head from one-pixel horizontal steps so it stays crisp on
      -- the native grid and works with the engine's minimal graphics stub.
      local halfH = math.max(1, math.floor((arrowH + 1) / 2))
      for arrowRow = 0, arrowH - 1 do
        local distance = math.min(arrowRow + 1, arrowH - arrowRow)
        local width = math.max(1, standalonePixel(headW * distance / halfH))
        G.rectangle("fill", headX,
          cursorY - math.floor(arrowH / 2) + arrowRow, width, 1)
      end
    end

    local right = tostring(item.right or "")
    local rightW = math.floor(bodyFont:getWidth(right) + 0.5)
    local available = math.max(1,
      standalonePixel(listRight - rightW - rightGap - leftX))
    local label = tostring(item.label or item.name or "ITEM")
    local labelW = standalonePixel(bodyFont:getWidth(label))
    local textY = math.floor(rowY + (rowH - bodyFont:getHeight()) * 0.5 + 0.5)
    local textColor = { 0, 0, 0, 1 }
    if labelW <= available or not rowSelected then
      standaloneSetScissor(transform, leftX, rowY, available, rowH)
      standaloneDrawText(bodyFont, label, leftX, textY, textColor)
      G.setScissor()
    else
      local speed = math.max(24, bodySize * 0.75)
      local prefix = item.prefix
      local move = item.move
      if prefix and move then
        local prefixW = standalonePixel(bodyFont:getWidth(prefix))
        local moveArea = math.max(1, available - prefixW)
        standaloneSetScissor(transform, leftX, rowY, available, rowH)
        standaloneDrawText(bodyFont, prefix, leftX, textY, textColor)
        standaloneSetScissor(transform, leftX + prefixW, rowY, moveArea, rowH)
        standaloneDrawText(bodyFont, move,
          leftX + prefixW + standaloneTickerOffset(now, labelW - available, speed),
          textY, textColor)
        G.setScissor()
      else
        standaloneSetScissor(transform, leftX, rowY, available, rowH)
        standaloneDrawText(bodyFont, label,
          leftX + standaloneTickerOffset(now, labelW - available, speed),
          textY, textColor)
        G.setScissor()
      end
    end
    if right ~= "" then
      standaloneDrawText(bodyFont, right, listRight - rightW, textY, textColor)
    end
  end

  G.setColor(0.72, 0.72, 0.72, 1)
  G.rectangle("fill", px + pad, py + panelH - footerH,
    math.max(1, panelW - pad * 2), 2)
  local footerY = py + panelH - footerH + math.floor(pad * 0.25)
  footer = standaloneFitFooter(footerFont, footer, footerWidth)
  standaloneDrawText(footerFont, footer, px + pad, footerY,
    { 0.25, 0.25, 0.25, 1 })
  standaloneDrawText(footerFont, money, px + panelW - pad - moneyW,
    footerY,
    { 0.25, 0.25, 0.25, 1 })
  G.pop()
end

-- The bag stays on the stack while USE/TOSS, quantity, confirmation, and
-- message states sit above it.  The presenter must keep owning the bag layer
-- for those non-opaque children; checking only stack:top() exposes the
-- engine's 160x144 BagMenu as soon as one of them opens.
local function stackIndex(game, target)
  local stack = game and game.stack
  local states = stack and stack.states
  if type(states) == "table" then
    for i, state in ipairs(states) do
      if state == target then return i end
    end
    return nil
  end
  if stack and stack.top and stack:top() == target then return 1 end
  return nil
end

local function hasOpaqueChild(game, index)
  local states = game and game.stack and game.stack.states
  if type(states) ~= "table" then return false end
  for i = index + 1, #states do
    if states[i] and states[i].isOpaque then return true end
  end
  return false
end

-- render.hud runs after the normal frame has already been composed.  When a
-- non-opaque child is above the bag, redraw those child states after the
-- fullscreen bag so the USE/TOSS box remains visible instead of being covered.
local function redrawChildren(game, index, viewport)
  local states = game and game.stack and game.stack.states
  if type(states) ~= "table" or index >= #states then return end
  local G = love and love.graphics
  if not G then return end
  local sx = (viewport and viewport.gameWidth or 160) / 160
  local sy = (viewport and viewport.gameHeight or 144) / 144
  G.push("all")
  G.origin()
  G.setScissor()
  G.translate(viewport and viewport.gameX or 0, viewport and viewport.gameY or 0)
  G.scale(sx, sy)
  for i = index + 1, #states do
    local state = states[i]
    if state and state.draw then
      -- A child that throws (a missing asset, a broken mod screen) must not
      -- skip the pop below and leak this transform/scissor into the next
      -- frame: the engine's hook guard logs the throw and keeps the frame,
      -- so an unbalanced push here would outlive the error.
      local ok, err = pcall(state.draw, state)
      if not ok then
        require("src.core.Logger").warn(
          "[useful_bag] child draw failed: %s", tostring(err))
      end
    end
  end
  G.pop()
end

local function installStandalonePresentation(mod, session)
  mod.hooks:wrap("screen.render_visible", function(next, visible, state)
    local oneArgument = state == nil and type(visible) == "table"
    if oneArgument then state, visible = visible, true end
    local game = session.game or (state and state.game)
    if session.active and state == session.active and stackIndex(game, state) then
      return false
    end
    if oneArgument then return next(state) end
    return next(visible, state)
  end, 100)

  mod.hooks:wrap("render.compose", function(next, renderer, ctx)
    local handled = next(renderer, ctx)
    local game = session.game
    if handled ~= true and session.active and game and game.stack
        and game.stack:top() == session.active and ctx and ctx.uiCanvas
        and love and love.graphics then
      if standaloneFullscreenEnabled(mod) then
        love.graphics.push("all")
        love.graphics.setCanvas(ctx.uiCanvas)
        -- clear() honours the active scissor, and the engine's letterbox /
        -- playfield cutout can leave one set; without this reset only part of
        -- the canvas clears and the rest keeps its opaque white, which the
        -- presenter then shows as a blank square.
        love.graphics.setScissor()
        love.graphics.clear(0, 0, 0, 0)
        love.graphics.pop()
      end
    end
    return handled
  end, 100)

  mod.hooks:wrap("render.hud", function(next, game, viewport)
    session.game = game
    next(game, viewport)
    -- Re-derive from the live stack every frame: a state that left the stack
    -- without the event we expected must not keep its blank overlay up.
    local active, index = refreshPresentation(session, game)
    if index and not hasOpaqueChild(game, index) and love and love.graphics then
      if standaloneFullscreenEnabled(mod) then
        standaloneDrawBag(game, viewport, active)
      else
        local renderer = game.renderer
        local uiw, uih = 160, 144
        if renderer and renderer.uiSize then uiw, uih = renderer:uiSize() end
        local gameX = viewport and viewport.gameX or 0
        local gameY = viewport and viewport.gameY or 0
        local gameW = viewport and viewport.gameWidth or uiw
        local gameH = viewport and viewport.gameHeight or uih
        standaloneDrawBag(game, { width = uiw, height = uih }, active, {
          compact = true,
          x = gameX,
          y = gameY,
          sx = gameW / uiw,
          sy = gameH / uih,
        })
      end
      redrawChildren(game, index, viewport)
    end
  end, 100)

  mod.events:on("screen.popped", function(ev)
    if ev and ev.state and ev.state == session.active and ev.state.__battle then
      session.lastBattlePocket = POCKETS[ev.state.__pocketIndex].id
    end
    -- Any pop can change which marked screen is topmost, not just the pop of
    -- the currently presented one: a PC list can sit above a bag, and a
    -- stack clear unwinds several states at once.  Re-derive instead of only
    -- reacting to ev.state == session.active.
    local game = ev and ev.state and ev.state.game or session.game
    refreshPresentation(session, game)
    session.wantSort = false
    session.sortOpen = false
  end)

  mod.events:on("screen.pushed", function(ev)
    local state = ev and ev.state
    refreshPresentation(session, (state and state.game) or session.game)
  end)
end

-- ------------------------------------------------ entry chunk

return function(mod)
  mod.options:define({
    { key = "fullscreen_menu", label = "FULLSCREEN BAG MENUS",
      type = "toggle", default = true },
  })

  mod.content.constants:patch("bagSize", 999)
  mod.content.constants:patch("itemStackCap", 999)
  mod.content.field:patch("pcItemCap", 999)
  installStackCapacityCompatibility()

  -- one bag at a time; the game.ready Input wraps write TAB/R3/touch SELECT here
  local session = { active = nil, wantSort = false, sortOpen = false }
  local shopQuantityContext = nil
  installStandalonePresentation(mod, session)

  -- A registered BagMenu wins over the builtin require fallback, so the
  -- start menu and the in-battle bag both get the pocketed list.  The
  -- factory still builds the vanilla bag (item-use flows stay engine
  -- owned) and then decorates it.
  -- Useful Bag deliberately owns the bag when QoL's alternative Pack is
  -- installed too; leave QoL's EXP bar and field shortcuts active.
  local screenOp = mod.content.screens:get("BagMenu") and "override" or "register"
  mod.content.screens[screenOp](mod.content.screens, "BagMenu", {
    new = function(game, opts)
      local VanillaBagMenu = require("src.ui.BagMenu")
      return decorate(VanillaBagMenu.new(game, opts), game, session, opts)
    end,
  })

  mod.events:on("game.ready", function(ev)
    local game = ev.game
    local Input = require("src.core.Input")

    -- hot reload re-runs entry chunks: wrap each module once
    if not Input.__usefulBag then
      Input.__usefulBag = true

    local vanillaKey = Input.keypressed
    Input.keypressed = function(self, key)
      -- TAB is bound to SELECT; while the bag is open it means "sort"
      -- instead, and the press is swallowed so it cannot also swap
      if key == "tab" and session.active
          and session.active.__usefulBagKind == "bag"
          and not session.sortOpen then
        session.wantSort = true
        return
      end
      return vanillaKey(self, key)
    end

    local vanillaPad = Input.gamepadpressed
    Input.gamepadpressed = function(self, joystick, button)
      if button == "rightstick" and session.active
          and session.active.__usefulBagKind == "bag"
          and not session.sortOpen then
        session.wantSort = true
        return
      end
      return vanillaPad(self, joystick, button)
    end

    local vanillaOverlayPressed = Input.overlayPressed
    Input.overlayPressed = function(self, button)
      if button == "select" and session.active
          and session.active.__usefulBagKind == "bag"
          and not session.sortOpen then
        session.wantSort = true
        return
      end
      return vanillaOverlayPressed(self, button)
    end

    end

    -- the PC's three item lists never got the vanilla SELECT-swap; catch
    -- them where they are built (PlayerPC.lua) and decorate them
    local ListMenu = require("src.ui.ListMenu")
    if not ListMenu.__usefulBag then
      ListMenu.__usefulBag = true
      local vanillaNew = ListMenu.new
      ListMenu.new = function(game, title, items, opts)
        local list = vanillaNew(game, title, items, opts)
        if isPcItemList(list) then
          decoratePcList(list, game, session)
        end
        return list
      end
    end

    -- Some Gen 1 shop payloads still give the BUY quantity picker the old
    -- hard-coded 999 maximum.  Keep the shop UI aligned with the shared
    -- Bag.add ceiling here, in the mod, so an installed Useful Bag protects
    -- itself even when the launched engine payload is stale.
    local function shopFullText(g)
      local text = g and g.data and g.data.text
      if type(text) == "table"
          and type(text._PokemartItemBagFullText) == "string" then
        return text._PokemartItemBagFullText
      end
      return "You can't carry\nany more items."
    end

    if not ListMenu.__usefulBagShopCapacity then
      ListMenu.__usefulBagShopCapacity = true
      local vanillaShopListNew = ListMenu.new
      ListMenu.new = function(shopGame, title, items, opts)
        local list = vanillaShopListNew(shopGame, title, items, opts)
        if title ~= "BUY" or not list or not list.onChoose then
          return list
        end

        local vanillaChoose = list.onChoose
        list.onChoose = function(item, currentList)
          local itemId = item and item.value
          local inventory = shopGame.save and shopGame.save.inventory
          local current = inventory and inventory[itemId] or 0
          local capacity = stackCapacity(shopGame.data)
          local remaining = math.max(0, capacity - current)
          if remaining < 1 then
            list.footer = shopFullText(shopGame)
            return
          end

          local previous = shopQuantityContext
          shopQuantityContext = {
            game = shopGame,
            itemId = itemId,
            remaining = remaining,
          }
          local ok, result = pcall(vanillaChoose, item, currentList)
          shopQuantityContext = previous
          if not ok then error(result, 0) end
          return result
        end
        return list
      end
    end

    local QuantityBox = require("src.ui.QuantityBox")
    if not QuantityBox.__usefulBagShopCapacity then
      QuantityBox.__usefulBagShopCapacity = true
      local vanillaQuantityNew = QuantityBox.new
      QuantityBox.new = function(quantityGame, opts)
        local context = shopQuantityContext
        if context and context.game == quantityGame and opts then
          opts.max = math.min(opts.max or context.remaining, context.remaining)
        end
        return vanillaQuantityNew(quantityGame, opts)
      end
    end
  end)

  mod.exports = {
    POCKETS = POCKETS,
    stackCapacity = stackCapacity,
    classify = classify,
    pocketItems = pocketItems,
    hiddenOrder = hiddenOrder,
    adjacentPocket = adjacentPocket,
    switchPocket = switchPocket,
    computeOrder = computeOrder,
    applySort = applySort,
    pcOrder = pcOrder,
    swapOrder = swapOrder,
    reorderItems = reorderItems,
    tickerOffset = tickerOffset,
    labelForItem = labelForItem,
    tickerFor = tickerFor,
    integerScale = standaloneScale,
    fontScale = standaloneTextScale,
    fontSize = standaloneFontSize,
    titleSize = standaloneTitleSize,
    footerText = standaloneFooterText,
    itemIndicator = standaloneItemIndicator,
    textScaleForRows = standaloneTextScaleForRows,
    compactRowLayout = standaloneCompactRowLayout,
    headerHeight = standaloneHeaderHeight,
  }
end
