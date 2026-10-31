-- Generation II-style battle EXP bar.
--
-- pret/pokecrystal's CalcExpBar measures the active Pokemon's EXP between
-- its current and next level, scales that interval to 64 pixels, and
-- PlaceExpBar writes the eight tiles from right to left.  This module keeps
-- those details while drawing through the public battle.overlay hook, so no
-- engine file or ROM-derived graphic is required.

local Growth = require("src.pokemon.Growth")

local ExpBar = {}

ExpBar.WIDTH = 64
ExpBar.BLUE = { 4 / 31, 17 / 31, 1, 1 } -- pokecrystal ExpBarPalette
ExpBar.BLUE_HIGHLIGHT = { 14 / 31, 24 / 31, 1, 1 }
ExpBar.EMPTY_BLUE = { 20 / 31, 24 / 31, 27 / 31, 1 }
ExpBar.GRAY = { 1 / 3, 1 / 3, 1 / 3, 1 }

local COLOR_MODES = {
  ogred = true, -- OG Red / Blue / Yellow colour
  gbc = true, -- SGB
  gbc_inv = true, -- SGB inverted
  redpp = true, -- Advanced
}

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

function ExpBar.isColorMode(mode)
  return COLOR_MODES[mode] == true
end

function ExpBar.colorForMode(mode)
  return ExpBar.isColorMode(mode) and ExpBar.BLUE or ExpBar.GRAY
end

-- Return Gen II's displayed pixel count. CalcExpBar calculates the EXP still
-- required, floors that fraction of 64, then subtracts it from 64. This is
-- subtly different from flooring progress directly and makes the first point
-- of EXP above a level threshold visible immediately.
function ExpBar.pixels(data, mon, expOverride, levelOverride)
  if not (data and mon) then return 0 end
  local def = data.pokemon and data.pokemon[mon.species]
  if not def then return 0 end

  local cap = (data.constants and data.constants.levelCap) or 100
  local level = clamp(math.floor(levelOverride or mon.level or 1), 1, cap)
  if level >= cap then return ExpBar.WIDTH end

  local rates = data.growth_rates
  local current = Growth.expForLevel(def.growthRate, level, rates)
  local nextLevel = Growth.expForLevel(def.growthRate, level + 1, rates)
  local span = math.max(1, nextLevel - current)
  local exp = clamp(math.floor(expOverride or mon.exp or current), current, nextLevel)
  local remaining = nextLevel - exp
  return clamp(ExpBar.WIDTH - math.floor(remaining * ExpBar.WIDTH / span),
               0, ExpBar.WIDTH)
end

-- Resolve the level belonging to an animated absolute EXP value. The live mon
-- reaches its final level before battle.exp_gained is emitted, so deriving the
-- temporary level is what lets the bar fill, wrap, and continue like Gen II.
function ExpBar.levelForExp(data, mon, exp)
  local def = data and data.pokemon and data.pokemon[mon and mon.species]
  if not def then return mon and mon.level or 1 end
  local cap = (data.constants and data.constants.levelCap) or 100
  return Growth.levelForExp(def.growthRate, exp, cap, data.growth_rates)
end

function ExpBar.displayPixels(data, mon, state, frame)
  if not (state and state.toExp and state.fromExp and state.endFrame) then
    return ExpBar.pixels(data, mon)
  end
  local duration = math.max(1, state.endFrame - state.startFrame)
  local t = clamp(((frame or state.endFrame) - state.startFrame) / duration, 0, 1)
  local exp = math.floor(state.fromExp + (state.toExp - state.fromExp) * t)
  local level = ExpBar.levelForExp(data, mon, exp)
  if t >= 1 then state.done = true end
  return ExpBar.pixels(data, mon, exp, level)
end

function ExpBar.visible(battle)
  if not (battle and battle.player and battle.player.mon) then return false end
  if battle.blankForAskName or battle.safari or battle.demo or battle.showPlayerBack then
    return false
  end
  if battle.introBalls or (battle.introSlide or 0) ~= 0 then return false end
  return true
end

function ExpBar.position(battle)
  if battle and battle.wideLayout and battle:wideLayout() then
    -- WideBattle's player panel is (184,56), 120x40. Anchor to its left
    -- content inset and use the available width instead of right-aligning a
    -- loose 64px strip. This keeps it attached to the HUD at every window
    -- size because the whole 304x144 surface is scaled as one unit.
    -- The box's right border begins at x=296, leaving 104 content pixels.
    return 192, 88, 104
  end
  -- The classic player HUD occupies (72,56), 88x40. This is the same
  -- hlcoord 10,11 origin used by Gen II, expressed relative to that panel.
  -- The right-corner tile's vertical stroke begins at x=147. Start at x=79
  -- to cover the one-pixel join with the arrow and stop at x=146 so both the
  -- track and baseline meet the two HUD ends exactly.
  return 79, 88, 68
end

-- Replace only the straight run of Gen I's player-HUD underline.  The arrow
-- at x=72 and the corner at x=144 remain the HUD's own tiles, so the EXP bar
-- is part of that chrome rather than a second box floating below it.  This is
-- the same eight-tile, right-to-left arrangement used by Gen II.
--
-- When Dramatic Shape captures the HUD, transparentBacking is true.  Its HUD
-- texture sits over frosted glass, so erase the old rule to transparency
-- instead of painting an opaque white slab into that texture.
function ExpBar.draw(battle, state, mode, transparentBacking)
  if not ExpBar.visible(battle) then return false end
  local g = love and love.graphics
  if not (g and g.rectangle and g.setColor) then return false end

  local x, y, width = ExpBar.position(battle)
  local pixels = ExpBar.displayPixels(battle.data, battle.player.mon,
                                      state, battle.frame or 0)
  local color = ExpBar.colorForMode(mode)
  local colorized = ExpBar.isColorMode(mode)
  local filled = pixels > 0
    and math.max(1, math.floor((pixels * width + ExpBar.WIDTH - 1)
                              / ExpBar.WIDTH)) or 0

  if transparentBacking and g.getBlendMode and g.setBlendMode then
    local oldMode, oldAlpha = g.getBlendMode()
    g.setBlendMode("replace")
    g.setColor(0, 0, 0, 0)
    g.rectangle("fill", x, y, width, 8)
    g.setBlendMode(oldMode or "alpha", oldAlpha)
  else
    g.setColor(1, 1, 1, 1)
    g.rectangle("fill", x, y, width, 8)
  end

  -- The track starts on row 1, flush with the upper-right tip of the HUD's
  -- left arrow. Starting it lower leaves a long white ledge between the tip
  -- and the fill once Dramatic Shape flips the HUD chrome.
  g.setColor(colorized and ExpBar.EMPTY_BLUE or { 3 / 4, 3 / 4, 3 / 4, 1 })
  g.rectangle("fill", x, y + 1, width, 2)

  if filled > 0 then
    local fillX = x + width - filled
    g.setColor(color)
    g.rectangle("fill", fillX, y + 1, filled, 2)
    if colorized then
      g.setColor(ExpBar.BLUE_HIGHLIGHT)
      g.rectangle("fill", fillX, y + 1, filled, 1)
    end
  end
  -- Continue the HUD chrome directly under the fill. Dramatic Shape flips
  -- this black rule to white on a dark panel. The two-pixel fill plus this
  -- rule fits between the arrow's upper tip and the right corner's elbow.
  -- Overlap the arrow by three pixels at the lower join and continue into the
  -- right-corner tile far enough to close the scaled seam without covering
  -- its outer edge.
  g.setColor(0, 0, 0, 1)
  g.rectangle("fill", x - 3, y + 3, width + 5, 2)
  g.setColor(1, 1, 1, 1)
  return true
end

return ExpBar
