-- All encounters for every Gen 1 game.
--
-- The three cartridges share map ids but not their wild tables: Red gets
-- Ekans and Growlithe, Blue gets Sandshrew and Vulpix, Yellow shuffles the
-- levels and adds Pikachu routes. This replaces game.data.encounters with one
-- of those tables, or with the union of all three, chosen in OPTIONS.
--
-- The tables come from data/encounters.lua, generated from the player's own
-- decoded cartridges (tools/build.lua). No ROM is shipped.

return function(mod)
  local Merge = assert(loadstring(assert(mod:read("lib/Merge.lua")),
    "@AllEncounters/Merge"))()
  local editions = assert(loadstring(assert(mod:read("data/encounters.lua")),
    "@AllEncounters/data"))()

  mod.options:define({
    {
      key = "editions", label = "WILD ENCOUNTERS", type = "choice",
      default = "all",
      choices = { { "RED", "red" }, { "BLUE", "blue" },
                  { "YELLOW", "yellow" }, { "ALL", "all" } },
      help = "Which game's wild Pokémon appear on each route.",
    },
  })

  local function chosen()
    local mode = mod.options:get("editions")
    return Merge.valid(mode) and mode or "all"
  end

  local function apply(game)
    if not game or not game.data then return end
    local mode = chosen()
    local table_ = Merge.table(editions, mode, Merge.editionOf(game))
    if table_ then game.data.encounters = table_ end
  end

  mod.events:on("game.ready", function(event)
    apply(event and event.game)
  end)

  mod.events:on("mod.options_changed", function(payload)
    if payload and payload.mod and payload.mod ~= mod.id then return end
    if not payload or payload.key ~= "editions" then return end
    apply(mod.game)
  end)

  mod.exports.apply = apply
  mod.exports.table = function(mode)
    return Merge.table(editions, mode, "red")
  end
  mod.exports.editions = function() return editions end
end
