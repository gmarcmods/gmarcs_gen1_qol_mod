local function isBoulder(npc)
  local def = npc and npc.def
  if not def then return false end
  if def.pushable ~= nil then return def.pushable == true end
  return def.sprite == "SPRITE_BOULDER"
end

local function queued(input, button)
  for _, value in ipairs((input and input.pressQueue) or {}) do
    if value == button then return true end
  end
  return false
end

local function consumeQueued(input, button)
  local found = false
  local queue = (input and input.pressQueue) or {}
  for index = #queue, 1, -1 do
    if queue[index] == button then
      table.remove(queue, index)
      found = true
    end
  end
  return found
end

local function facingCutTree(ow)
  local map, player = ow and ow.map, ow and ow.player
  if not (map and player and player.facingCell and map.cellTile) then return false end
  local x, y = player:facingCell()
  if map.inBounds and not map:inBounds(x, y) then return false end
  local tileset = map.def and map.def.tileset
  local tile = map:cellTile(x, y)
  return (tileset == "OVERWORLD" and tile == 0x3d)
    or (tileset == "GYM" and tile == 0x50)
end

return function(mod)
  -- Gold/Silver/Crystal already implement these features natively. Loading
  -- this companion there must not replace the Pack, duplicate the EXP bar,
  -- or install the Gen 1 item-capacity shim into the Gen 2 engine.
  if mod.generation == 2 then
    mod.options:define({{key='device_clock',label='DEVICE CLOCK',type='toggle',default=true}})
    local Clock=require('src.core.gen2.Clock')
    Clock._qualityOfLifeClock=mod
    if not Clock._qualityOfLifeMinutes then
      Clock._qualityOfLifeMinutes=Clock.minutes
      Clock._qualityOfLifeWeekday=Clock.weekday
      local function deviceTime()
        local current=Clock._qualityOfLifeClock
        if not current or current.options:get('device_clock')==false then return false end
        local game=current.game
        return not game or not game.mods or game.mods.exports.quality_of_life==current.exports
      end
      Clock.minutes=function(save)
        if deviceTime()then return Clock._qualityOfLifeMinutes(nil)end
        return Clock._qualityOfLifeMinutes(save)
      end
      Clock.weekday=function(save)
        if deviceTime()then return Clock._qualityOfLifeWeekday(nil)end
        return Clock._qualityOfLifeWeekday(save)
      end
    end
    mod.exports.nativeGen2 = true
    mod.log:info('Native Gen 2 Pack, EXP bar and field prompts are in use')
    return
  end
  local game
  local promptOpen = false

  local bagSource = mod:read("gen2_bag.lua")
  local bagChunk, bagError = bagSource and load(bagSource,
    "@" .. mod.path .. "/gen2_bag.lua")
  if not bagChunk then error(bagError or "gen2_bag.lua is missing") end
  local Gen2Bag = bagChunk()
  local expBarSource = mod:read("gen2_exp_bar.lua")
  local expBarChunk, expBarError = expBarSource and load(expBarSource,
    "@" .. mod.path .. "/gen2_exp_bar.lua")
  if not expBarChunk then error(expBarError or "gen2_exp_bar.lua is missing") end
  local Gen2ExpBar = expBarChunk()
  local Bag = require("src.inventory.Bag")
  local pocketLimits = { items = 20, balls = 12, key = 25, tmhm = 55 }
  local itemData
  -- The wrapper survives module caching; replace its live context on reload.
  Bag._qualityOfLifeContext={mod=mod,game=function()return game end,
    items=function()return itemData end,bag=Gen2Bag,limits=pocketLimits}

  -- Gen II counts capacity per pocket instead of applying Gen I's 20 slots to
  -- the entire Bag. Keep the existing flat save representation so old saves
  -- remain valid, but enforce the capacity of the item's logical pocket.
  if not Bag._qualityOfLifeOriginalAdd then
    Bag._qualityOfLifeOriginalAdd = Bag.add
    Bag.add = function(save, id, qty, data)
      if not save then return false end
      local context=Bag._qualityOfLifeContext
      local live=context and context.game()
      if not context or require('src.core.GameVersion').generation()~=1
          or (live and live.mods and live.mods.exports.quality_of_life~=context.mod.exports)
          or context.mod.options:get("gen2_pack") == false then
        return Bag._qualityOfLifeOriginalAdd(save, id, qty, data)
      end
      save.inventory=save.inventory or {}
      local inv, amount = save.inventory, qty or 1
      local definitions=data and data.items or context.items()
      local def = definitions and definitions[id]
      if Bag.isBadge(id) then
        inv[id] = (inv[id] or 0) + amount
        return true
      end
      local maxStack = def and def.keyItem and 1 or 99
      if def and def.keyItem and (inv[id] or 0) + amount > maxStack then return false end
      local pocket = context.bag.pocketId(id, def)
      local itemData = data or {items=definitions}
      local used = Bag.storeSlots(inv, itemData, function(owned)
        return context.bag.pocketId(owned, definitions and definitions[owned]) == pocket
      end, save.bagStacks)
      save.bagStacks = save.bagStacks or {}
      return Bag.addTo(inv, Bag.order(save, itemData), id, amount, itemData,
        used, context.limits[pocket], save.bagStacks)
    end
  end

  mod.options:define({
    { key = "cut_prompt", label = "CUT PROMPT", type = "toggle", default = true },
    { key = "surf_prompt", label = "SURF PROMPT", type = "toggle", default = true },
    { key = "strength_prompt", label = "STRENGTH PROMPT", type = "toggle", default = true },
    { key = "gen2_pack", label = "GEN II PACK", type = "toggle", default = true },
    { key = "gen2_exp_bar", label = "EXP BAR", type = "toggle", default = true },
    { key = "caught_icon", label = "CAUGHT ICON", type = "toggle", default = true,
      help = "Show a ball next to a wild Pokémon whose species you already own." },
    { key = "place_tag", label = "PLACE NAMES", type = "toggle", default = true,
      help = "Show the town or route name when you walk into it." },
  })

  -- Route and town names on entry (Gen 1 has no map sign of its own).
  do
    local source = mod:read("place_tag.lua")
    if source then
      local chunk = assert(load(source, "@" .. mod.path .. "/place_tag.lua"))
      chunk()(mod)
    end
  end

  -- Gen II marks a wild Pokémon already in the Pokédex (CheckCaughtMon). The
  -- Gen 1 battle state already knows the species is owned and then asks this
  -- hook, but nothing answered it, so the marker never drew. Answer here.
  mod.hooks:wrap("battle.caught_marker_visible", function(next_, battle)
    local generation = require("src.core.GameVersion").generation()
    if generation ~= 1 then return next_(battle) end
    return mod.options:get("caught_icon") ~= false
  end)

  mod.content.screens:register("BagMenu", {
    new = function(activeGame, opts)
      if mod.options:get("gen2_pack") == false then
        return require("src.ui.BagMenu").new(activeGame, opts)
      end
      return Gen2Bag.new(activeGame, opts)
    end,
  })

  mod.content.screens:register("PlayerPC", {
    new = function(activeGame)
      local root = require("src.ui.PlayerPC").new(activeGame)
      if mod.options:get("gen2_pack") == false then return root end
      for _, row in ipairs(root.items or {}) do
        local original, action = row.onSelect, tostring(row.label)
        if original and (action == "WITHDRAW ITEM" or action == "DEPOSIT ITEM"
            or action == "TOSS ITEM") then
          row.onSelect = function()
            original()
            local list = activeGame.stack:top()
            if not (list and list.items and list.game == activeGame) then return end
            if action == "DEPOSIT ITEM" then
              Gen2Bag.decorate(list, function(pocket)
                return Gen2Bag.entriesFor(activeGame, pocket)
              end, { allowReorder = false })
            else
              Gen2Bag.decorateStorage(list)
            end
          end
        end
      end
      return root
    end,
  })

  local function overworldReady(activeGame)
    local current = activeGame or game
    local ow = current and current.overworld
    if not (current and ow and current.stack and current.stack.top) then return nil end
    if current.stack:top() ~= ow or (ow.player and ow.player.moving) then return nil end
    return current, ow
  end

  local function ask(current, move, onYes)
    if promptOpen then return false end
    promptOpen = true
    current.stack:push(mod.ui.TextBox.new(current, "Use " .. move .. "?", nil, {
      choice = function(yes)
        promptOpen = false
        if yes then onYes() end
      end,
    }))
    return true
  end

  local function strengthText(current, ow, mon)
    if ow.useStrengthFieldMove then return ow:useStrengthFieldMove(mon) end
    ow.strengthActive = true
    local def = current.data.pokemon[mon.species] or {}
    local name = mon.nickname or def.name or mon.species
    local text = current.data.text or {}
    local used = (text._UsedStrengthText or "{RAM:wNameBuffer} used\nSTRENGTH.")
      :gsub("{RAM:wNameBuffer}", name)
    local canMove = (text._CanMoveBouldersText
      or "{RAM:wNameBuffer} can\nmove boulders.")
      :gsub("{RAM:wNameBuffer}", name)
    current.stack:push(mod.ui.TextBox.new(current, used, function()
      current.stack:push(mod.ui.TextBox.new(current, canMove))
    end))
  end

  mod.events:on("game.ready", function(payload)
    game = (payload and payload.game) or game
    itemData = game and game.data and game.data.items or itemData
  end)

  -- Cut and Surf are empty-tile interactions in the unmodified game. Waiting
  -- for world.interacted preserves NPC, sign, door, script, and hidden-object
  -- priority without rebuilding the engine's interaction dispatcher.
  mod.events:on("world.interacted", function(payload)
    if not (payload and payload.kind == "none") then return end
    local current, ow = overworldReady(game)
    if not current or not ow.map or ow.map.id ~= payload.mapId then return end

    if mod.options:get("cut_prompt") ~= false and facingCutTree(ow)
        and ow.useCutFieldMove and ow:useCutFieldMove() == "ok" then
      ask(current, "CUT", function()
        if ow:useCutFieldMove() ~= "ok" then return end
        local x, y = ow.player:facingCell()
        ow:tryCut(x, y)
      end)
      return
    end

    if mod.options:get("surf_prompt") ~= false and not ow.player.surfing
        and ow.useSurfFieldMove and ow:useSurfFieldMove() == "ok" then
      ask(current, "SURF", function()
        if ow.player.surfing or ow:useSurfFieldMove() ~= "ok" then return end
        local x, y = ow.player:facingCell()
        ow:trySurf(x, y)
      end)
    end
  end)

  -- A boulder is an NPC, so vanilla would open its STRENGTH-required text
  -- before world.interacted fires. input.step runs just before Input:step;
  -- consume only the queued A edge when a valid Strength prompt replaces it.
  mod.hooks:wrap("input.step", function(next, activeGame, dt)
    game = activeGame or game
    local current, ow = overworldReady(game)
    local input = current and current.input
    if current and mod.options:get("strength_prompt") ~= false
        and not promptOpen and not ow.strengthActive and queued(input, "a") then
      local x, y = ow.player:facingCell()
      local npc = ow.npcAtCell and ow:npcAtCell(x, y)
      local mon = isBoulder(npc) and ow.partyKnows and ow:partyKnows("STRENGTH")
      if mon then
        consumeQueued(input, "a")
        ask(current, "STRENGTH", function() strengthText(current, ow, mon) end)
      end
    end
    return next(activeGame, dt)
  end)

  -- battle.exp_gained fires after the live party mon receives its EXP. Keep
  -- the previous absolute value so the overlay can visibly fill and wrap at
  -- level boundaries instead of jumping straight to the final percentage.
  local expAnimations = setmetatable({}, { __mode = "k" })
  mod.events:on("battle.exp_gained", function(ev)
    local battle, mon = ev and ev.battle, ev and ev.mon
    if not (battle and battle.player and battle.player.mon == mon) then return end
    local gained = math.max(0, math.floor(ev.gained or 0))
    local toExp = math.max(0, math.floor(mon.exp or 0))
    local fromExp = math.max(0, toExp - gained)
    local start = battle.frame or 0
    local pending = expAnimations[battle]
    -- EXP.ALL can award the active mon once as a participant and again as a
    -- party member in the same frame. Join those awards into one continuous
    -- animation rather than replacing the first half with the second.
    if pending and pending.startFrame == start then
      fromExp = pending.fromExp
      gained = math.max(0, toExp - fromExp)
    end
    -- Gen II advances the bar in visible pixel steps. Cap unusually huge
    -- gains so an EXP.ALL battle cannot hold the screen for many seconds.
    local duration = math.max(12, math.min(120, gained))
    expAnimations[battle] = {
      fromExp = fromExp, toExp = toExp,
      startFrame = start, endFrame = start + duration,
    }
  end)

  mod.events:on("battle.ended", function(ev)
    if ev and ev.battle then expAnimations[ev.battle] = nil end
  end)

  -- Put the EXP bar in DrawPlayerHUDAndHPBar's own layer. Dramatic Shape
  -- captures that layer and moves it to the window edge; an ordinary
  -- battle.overlay is too late and would leave the bar behind at x=80 on the
  -- 160x144 canvas. QUALITY_OF_LIFE loads before DRAMATIC_SHAPE so the latter
  -- captures this wrapper along with the vanilla HUD.
  local BattleState = require("src.battle.BattleState")
  if not BattleState._qualityOfLifeExpOriginalDrawHUDs then
    BattleState._qualityOfLifeExpOriginalDrawHUDs = BattleState.drawHUDs
    BattleState.drawHUDs = function(self, slide)
      BattleState._qualityOfLifeExpOriginalDrawHUDs(self, slide)
      local bridge = BattleState._qualityOfLifeExpBridge
      if bridge then bridge(self) end
    end
  end
  BattleState._qualityOfLifeExpBridge = function(battle)
    if mod.options:get("gen2_exp_bar") == false then return end
    -- Dramatic Shape temporarily shadows colorMode while it renders the HUD
    -- texture. Its live fallback instead exposes dramaticShapeShot. Both are
    -- rendering the HUD layer itself and need a transparent backing.
    local captured = type(rawget(battle, "colorMode")) == "function"
    if not (captured or battle.dramaticShapeShot) then return end
    local palette = require("src.render.PaletteFX")
    local state = expAnimations[battle]
    Gen2ExpBar.draw(battle, state, palette.mode, true)
    if state and state.done then expAnimations[battle] = nil end
  end

  mod.hooks:wrap("battle.overlay", function(next, battle)
    next(battle)
    if mod.options:get("gen2_exp_bar") == false then return end
    -- The snapped/fallback Dramatic Shape HUD already contains the bar. Do
    -- not draw a second copy at the old Game Boy canvas coordinates.
    if battle.dramaticShapeShot then return end
    local palette = require("src.render.PaletteFX")
    local state = expAnimations[battle]
    Gen2ExpBar.draw(battle, state, palette.mode)
    if state and state.done then expAnimations[battle] = nil end
  end)

  mod.exports.isBoulder = isBoulder
  mod.exports.queued = queued
  mod.exports.consumeQueued = consumeQueued
  mod.exports.facingCutTree = facingCutTree
  mod.exports.gen2Bag = Gen2Bag
  mod.exports.gen2ExpBar = Gen2ExpBar
  mod.exports.pocketLimits = pocketLimits
end
