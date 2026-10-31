-- Trade evolutions by level for Red, Blue and Yellow.
--
-- The cartridge has four Pokémon that only evolve through a link trade:
-- Kadabra, Machoke, Graveler and Haunter. Gen 1 has no held-item evolutions,
-- so there is nothing else to handle.
--
-- src/pokemon/Evolution.lua dispatches every evolution through the merged
-- `evolution_methods` registry. Patching the TRADE record's check adds the
-- level-up trigger and leaves real trades working: the original answered
-- `trigger.kind == "trade"`, and so does this one, before the new branch.
-- `describe` changes too, so a summary screen says "Level 37", not "Trade".

return function(mod)
  mod.options:define({
    {
      key = "level", label = "TRADE EVO LEVEL", type = "choice",
      choices = { { "LEVEL 30", "30" }, { "LEVEL 37", "37" },
                  { "LEVEL 40", "40" }, { "LEVEL 45", "45" },
                  { "LEVEL 50", "50" } },
      default = "37",
      help = "Kadabra, Machoke, Graveler and Haunter evolve at this level.",
    },
  })

  local function threshold()
    local value = tonumber(mod.options:get("level")) or 37
    return math.max(1, math.min(100, math.floor(value)))
  end

  mod.content.evolution_methods:patch("TRADE", {
    check = function(game, mon, evo, trigger)
      local kind = trigger and trigger.kind
      if kind == "trade" then return true end
      if kind ~= "levelup" then return false end
      if not mon then return false end
      return (mon.level or 1) >= threshold()
    end,
    describe = function()
      return "Level " .. threshold()
    end,
  })

  -- Exposed for the mod manager and for tests: the level in force.
  mod.exports.tradeLevel = threshold
end
