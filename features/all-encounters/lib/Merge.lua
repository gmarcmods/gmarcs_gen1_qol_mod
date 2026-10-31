-- Merging the three Gen 1 encounter tables.
--
-- Every edition has the same map ids but different slots on them. "ALL" takes
-- the union, one entry per species, in the order Red, Blue, Yellow (or the
-- edition being played first, so its levels win) and redistributes the 256
-- probability buckets evenly. The engine allows a table to carry its own
-- `buckets` as long as the last one is 256 and there is one per slot.

local Merge = {}

local ORDER = { "red", "blue", "yellow" }

function Merge.valid(mode)
  return mode == "red" or mode == "blue" or mode == "yellow" or mode == "all"
end

local function orderFor(base)
  local out = { base }
  for _, name in ipairs(ORDER) do
    if name ~= base then out[#out + 1] = name end
  end
  return out
end

local function unionSlots(mapId, editions, order)
  local slots, seen, rate = {}, {}, 0
  for _, name in ipairs(order) do
    local def = editions[name] and editions[name][mapId]
    local grass = def and def.grass
    if grass then
      rate = math.max(rate, tonumber(grass.rate) or 0)
      for _, slot in ipairs(grass.slots or {}) do
        if slot and slot.species and not seen[slot.species] then
          seen[slot.species] = true
          slots[#slots + 1] = { species = slot.species, level = slot.level }
        end
      end
    end
  end
  table.sort(slots, function(a, b)
    if a.species == b.species then return (a.level or 0) < (b.level or 0) end
    return a.species < b.species
  end)
  return { rate = rate, slots = slots }
end

local function withBuckets(grass)
  if #grass.slots ~= 10 then
    local buckets = {}
    for index = 1, #grass.slots do
      buckets[index] = index == #grass.slots and 256
        or math.floor(256 * index / #grass.slots)
    end
    grass.buckets = buckets
  end
  return grass
end

-- mode is the option; base is the edition being played, used to order levels.
function Merge.table(editions, mode, base)
  if type(editions) ~= "table" then return nil end
  if not Merge.valid(mode) then mode = "all" end
  if not Merge.valid(base) then base = "red" end
  if mode ~= "all" then return editions[mode] end

  local maps = {}
  for _, name in ipairs(ORDER) do
    for id in pairs(editions[name] or {}) do maps[id] = true end
  end
  local ids = {}
  for id in pairs(maps) do ids[#ids + 1] = id end
  table.sort(ids)

  local out = {}
  local order = orderFor(base)
  for _, id in ipairs(ids) do
    local grass = unionSlots(id, editions, order)
    if #grass.slots > 0 then out[id] = { grass = withBuckets(grass) } end
  end
  return out
end

-- For the tests and for a readable summary.
function Merge.editionOf(game)
  local ok, GV = pcall(require, "src.core.GameVersion")
  if not ok then return "red" end
  if GV.isYellow and GV.isYellow() then return "yellow" end
  if GV.isBlue and GV.isBlue() then return "blue" end
  return "red"
end

return Merge
