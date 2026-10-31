-- Gen 2 storage limits for a catch, in two places.
--
-- 1. The ball gate. src/ui/gen2/BattleState:useItem refuses a ball when the
--    party is full AND the box it is looking at is full -- BallBoxIsFullText,
--    exactly as item_effects.asm:217-226 does. The cart never looks for another
--    box, so with BOX 1 full and BOX 2 empty the ball is still refused. This
--    hands the throw to the next box with room instead, and only keeps the
--    refusal when every box really is full.
--
-- 2. The deposit itself. BattleState:storeCaughtMon deposits through
--    src.pokemon.Boxes, and the Gen 1 module that name usually resolves to has
--    twelve boxes. A Gold/Silver/Crystal save has fourteen. The wrap below
--    keeps the catch inside the generation's own limits even if the facade is
--    not the one in force.
--
-- Both run only while a Gen 2 game is up: Gen 1 keeps its own functions byte
-- for byte, and Gen 3 never reaches them. Nothing is evicted or reordered: a
-- full box is skipped, and the mon is appended exactly as the engine appends it.

local Gen2Deposit = {}

local DEFAULT_BOXES = 14
local DEFAULT_CAPACITY = 20
local DEFAULT_PARTY = 6

local function engineGeneration()
  local ok, version = pcall(function()
    return require("src.core.GameVersion").generation()
  end)
  if ok then return version end
  return nil
end

-- Test seam only: a harness outside a booted game has no GameVersion to read.
local generationOverride = nil
function Gen2Deposit.setGeneration(fn)
  generationOverride = fn
end

local function generation()
  if generationOverride then return generationOverride() end
  return engineGeneration()
end

local function limits()
  local ok, module = pcall(require, "src.core.gen2.Boxes")
  if ok and type(module) == "table" then
    return module.NUM_BOXES or DEFAULT_BOXES,
      module.MONS_PER_BOX or DEFAULT_CAPACITY,
      module.PARTY_SIZE or DEFAULT_PARTY
  end
  return DEFAULT_BOXES, DEFAULT_CAPACITY, DEFAULT_PARTY
end

-- First box with room, starting at `start` (or the save's current box) and
-- wrapping once. Missing box tables are created; a full box is skipped, never
-- replaced. Returns the box number, or nil when every box is full.
function Gen2Deposit.nextBox(save, count, capacity, start)
  if type(save) ~= "table" then return nil end
  count = math.max(1, math.floor(tonumber(count) or DEFAULT_BOXES))
  capacity = math.max(1, math.floor(tonumber(capacity) or DEFAULT_CAPACITY))
  save.boxes = save.boxes or {}
  local first = math.floor(tonumber(start) or tonumber(save.currentBox) or 1)
  if first < 1 or first > count then first = 1 end
  for offset = 0, count - 1 do
    local index = ((first - 1 + offset) % count) + 1
    local box = save.boxes[index]
    if box == nil then
      box = {}
      save.boxes[index] = box
    end
    if #box < capacity then return index end
  end
  return nil
end

-- Deposit into the first box with room. Returns the box number used, or nil
-- when every box is full.
function Gen2Deposit.deposit(save, mon, count, capacity)
  if type(save) ~= "table" or mon == nil then return nil end
  local index = Gen2Deposit.nextBox(save, count, capacity, save.currentBox)
  if not index then return nil end
  local box = save.boxes[index]
  box[#box + 1] = mon
  return index
end

-- The ball gate's decision. With room in the party the mon never needs a box,
-- so the throw is always allowed. With a full party, move `save.currentBox` to
-- the first box with room so the throw proceeds and the deposit lands there;
-- report false only when every box is full, which is the one case the message
-- is honest about.
function Gen2Deposit.allowBall(save, partySize, partyLimit, count, capacity)
  if type(save) ~= "table" then return false end
  partyLimit = math.max(1, math.floor(tonumber(partyLimit) or DEFAULT_PARTY))
  if (tonumber(partySize) or 0) < partyLimit then return true end
  local index = Gen2Deposit.nextBox(save, count, capacity, save.currentBox)
  if not index then return false end
  save.currentBox = index
  return true
end

-- Wraps BattleState:useItem once so a ball aimed at a full box is thrown into
-- the next box with room. Returns false when the engine method is not there to
-- wrap, or when this ran before.
function Gen2Deposit.installBallGate(BattleState)
  if type(BattleState) ~= "table" or BattleState.__gen3BoxBallGate then
    return false
  end
  local base = BattleState.useItem
  if type(base) ~= "function" then return false end
  BattleState.__gen3BoxBallGate = true
  BattleState.useItem = function(self, itemId, ...)
    if generation() == 2 and self and self.battle and self.battle.wild then
      local save = self.save
      local data = (self.game and self.game.data) or {}
      local def = data.items and data.items[itemId]
      if def and def.pocket == "BALL" then
        local count, capacity, party = limits()
        Gen2Deposit.allowBall(save, #(((save or {}).party) or {}), party,
          count, capacity)
      end
    end
    return base(self, itemId, ...)
  end
  return true
end

-- Replaces src.pokemon.Boxes.deposit once, for the deposit half above.
function Gen2Deposit.installDeposit(Boxes)
  if type(Boxes) ~= "table" or Boxes.__gen3BoxGen2Deposit then return false end
  local original = Boxes.deposit
  Boxes.__gen3BoxGen2Deposit = true
  Boxes.deposit = function(save, mon, ...)
    if generation() ~= 2 then
      if original then return original(save, mon, ...) end
      return nil
    end
    local count, capacity = limits()
    return Gen2Deposit.deposit(save, mon, count, capacity)
  end
  return true
end

return Gen2Deposit
