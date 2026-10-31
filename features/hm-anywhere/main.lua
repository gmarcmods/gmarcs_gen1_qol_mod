-- HM Anywhere v1.2.0 for Gen1Recomp
--
-- Owning an HM item is enough to use its field action.
--
-- v1.2:
--   * Start -> HM now exposes CUT / FLY / SURF / STR / FLSH.
--   * CTX ON/OFF toggles contextual A-button actions without disabling the
--     inventory-based HM functionality.
--   * While surfing, an NPC in front of the player (including swimmers)
--     always receives the A press before contextual SURF tries to dismount.

local PATCH_KEY = "__hm_anywhere_dispatch_v2"

local HM_BADGES = {
  CUT = "CASCADEBADGE",
  FLY = "THUNDERBADGE",
  SURF = "SOULBADGE",
  STRENGTH = "RAINBOWBADGE",
  FLASH = "BOULDERBADGE",
}

local FIELD_HMS = {
  CUT = true,
  FLY = true,
  SURF = true,
  STRENGTH = true,
  FLASH = true,
}

local HM_ORDER = { "CUT", "FLY", "SURF", "STRENGTH", "FLASH" }

local HM_LABEL = {
  CUT = "CUT",
  FLY = "FLY",
  SURF = "SURF",
  STRENGTH = "STR",
  FLASH = "FLSH",
}

local function hasCount(value)
  if type(value) == "number" then return value > 0 end
  return value == true
end

local function ownedHM(game, moveId)
  local inventory = game and game.save and game.save.inventory or {}
  local items = game and game.data and game.data.items or {}
  for itemId, count in pairs(inventory) do
    if hasCount(count) then
      local def = items[itemId]
      local machine = def and def.machine
      if machine and machine.kind == "HM" and machine.move == moveId then
        return itemId, def
      end
    end
  end
  return nil
end

local function hasAnyHM(game)
  for _, moveId in ipairs(HM_ORDER) do
    if ownedHM(game, moveId) then return true end
  end
  return false
end

local function hasBadge(game, moveId)
  local badge = HM_BADGES[moveId]
  if not badge then return true end
  local inventory = game and game.save and game.save.inventory or {}
  return hasCount(inventory[badge])
end

local function fieldHelper(game)
  local party = game and game.save and game.save.party or {}
  for _, mon in ipairs(party) do
    if (mon.hp or 0) > 0 then return mon end
  end
  return party[1]
end

local function contextualEnabled(mod)
  return mod.save:get("contextualActions", true) ~= false
end

local function setContextual(mod, enabled)
  mod.save:set("contextualActions", enabled and true or false)
end

local function pushText(game, text, onDone)
  local TextBox = require("src.render.TextBox")
  game.stack:push(TextBox.new(game, text, onDone))
end

local function textOr(game, key, fallback)
  local text = game and game.data and game.data.text
  return (text and text[key]) or fallback
end

local function badgeRequired(game)
  return textOr(game, "_NewBadgeRequiredText",
    "A new BADGE is\nrequired.")
end

local function noLandingText(game)
  return textOr(game, "_SurfingNoPlaceToGetOffText",
    "There's no place\nto get off!")
end

local function noSurfText(game)
  return textOr(game, "_NoSurfingHereText",
    "No SURFing here!")
end

local function noCutText(game)
  return textOr(game, "_NothingToCutText",
    "Nothing to CUT!")
end

local function fieldUnavailable(game, moveId, reopen)
  pushText(game, moveId .. " can't be\nused right now.", reopen)
end

-- -------------------------------------------------------------------------
-- Contextual A-button actions
-- -------------------------------------------------------------------------

local function tryStrength(game, ow)
  if not ownedHM(game, "STRENGTH") then return false end
  local Map = require("src.world.Map")
  local player = ow.player
  local fx, fy = player:facingCell()
  local npc = ow:npcAtCell(fx, fy)
  if not (npc and npc.def and Map.isPushable(npc.def)) then return false end

  if not hasBadge(game, "STRENGTH") then
    pushText(game, badgeRequired(game))
    return true
  end

  local function pushNow()
    if not (ow.map and ow.player) then return end
    ow.strengthActive = true
    -- Vanilla requires a first collision to arm BIT_TRIED_PUSH_BOULDER and a
    -- second one to move. A contextual A press performs both attempts.
    ow.boulderTried = nil
    ow:checkBoulderPush(player.facing)
    ow:checkBoulderPush(player.facing)
  end

  if not ow.strengthActive then
    ow.strengthActive = true
    pushText(game,
      "The HM device used\nSTRENGTH!\fBoulders can now\nbe moved.", pushNow)
  else
    pushNow()
  end
  return true
end

local function tryCut(game, ow)
  if not ownedHM(game, "CUT") then return false end
  local reason = ow:useCutFieldMove()
  if reason ~= "ok" then return false end
  if not hasBadge(game, "CUT") then
    pushText(game, badgeRequired(game))
    return true
  end
  local fx, fy = ow.player:facingCell()
  ow:tryCut(fx, fy)
  return true
end

local function dismountSurf(game, ow)
  local player = ow.player
  player.surfing = false
  if ow.syncSurfingPikachu then ow:syncSurfingPikachu() end
  require("src.core.Music").setSurfing(game.data, false)
  local Transition = require("src.render.Transition")
  game.stack:push(Transition.whiteFlash(game, nil, function()
    ow:stepForwardOrCrossEdge(player.facing)
  end))
end

local function trySurf(game, ow)
  if not ownedHM(game, "SURF") then return false end
  local reason = ow:useSurfFieldMove()
  if reason == "no_water" or reason == "forced_bike" or reason == "current" then
    return false
  end
  if not hasBadge(game, "SURF") then
    pushText(game, badgeRequired(game))
    return true
  end
  if reason == "ok" then
    local fx, fy = ow.player:facingCell()
    ow:trySurf(fx, fy)
    return true
  elseif reason == "dismount" then
    dismountSurf(game, ow)
    return true
  elseif reason == "no_place" then
    pushText(game, noLandingText(game))
    return true
  end
  return false
end

local function directNpcAhead(ow)
  local player = ow and ow.player
  if not (player and ow.npcAtCell) then return nil end
  local fx, fy = player:facingCell()
  return ow:npcAtCell(fx, fy)
end

local function contextualInteract(game, mod, baseInteract, ow, ...)
  if not (ow and ow.player and ow.map) then return baseInteract(ow, ...) end

  -- CTX OFF means HM Anywhere keeps its inventory-based HM behavior and
  -- Start -> HM menu, but every A press is pure vanilla interaction.
  if not contextualEnabled(mod) then
    return baseInteract(ow, ...)
  end

  -- A pushable boulder is represented as an NPC object, so STRENGTH must
  -- still get first refusal.
  if tryStrength(game, ow) then return end

  -- Critical surf fix: swimmers and other NPCs must win over contextual
  -- SURF. v1.1 ran useSurfFieldMove first, so while surfing an A press toward
  -- a swimmer could resolve to "no_place" and swallow the conversation.
  -- Vanilla OverworldState:interact already owns NPC/counter dialogue, so
  -- delegate immediately when a direct NPC is in the facing cell.
  if directNpcAhead(ow) then
    return baseInteract(ow, ...)
  end

  if tryCut(game, ow) then return end
  if trySurf(game, ow) then return end

  -- NPCs across counters, signs, hidden items, scripts and bookshelves keep
  -- vanilla behavior when no contextual field action matched.
  return baseInteract(ow, ...)
end

-- -------------------------------------------------------------------------
-- Manual Start -> HM actions
-- -------------------------------------------------------------------------

local function isOutside(game, ow)
  if not (ow and ow.map and ow.map.def) then return false end
  local Map = require("src.world.Map")
  local FieldDefaults = require("src.world.FieldDefaults")
  return Map.isOutside(ow.map.def,
    FieldDefaults.field(game.data, "outsideTilesets"))
end

local function removeVanillaHMRows(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    local label = tostring(item.label or ""):upper()
    if not FIELD_HMS[label] then out[#out + 1] = item end
  end
  return out
end

local function cutFromMenu(game, reopen)
  local ow = game.overworld
  if not (ow and ow.map and ow.player) then
    fieldUnavailable(game, "CUT", reopen)
    return
  end
  if not hasBadge(game, "CUT") then
    pushText(game, badgeRequired(game), reopen)
    return
  end

  local reason = ow:useCutFieldMove()
  if reason == "ok" then
    local fx, fy = ow.player:facingCell()
    ow:tryCut(fx, fy)
    return
  end

  if reason == "no_badge" then
    pushText(game, badgeRequired(game), reopen)
  else
    pushText(game, noCutText(game), reopen)
  end
end

local function surfFromMenu(game, reopen)
  local ow = game.overworld
  if not (ow and ow.map and ow.player) then
    fieldUnavailable(game, "SURF", reopen)
    return
  end
  if not hasBadge(game, "SURF") then
    pushText(game, badgeRequired(game), reopen)
    return
  end

  local reason = ow:useSurfFieldMove()
  if reason == "ok" then
    local fx, fy = ow.player:facingCell()
    ow:trySurf(fx, fy)
    return
  elseif reason == "dismount" then
    dismountSurf(game, ow)
    return
  elseif reason == "no_place" then
    pushText(game, noLandingText(game), reopen)
    return
  elseif reason == "forced_bike" then
    pushText(game, textOr(game, "_CyclingIsFunText",
      "Cycling is fun!\nForget SURF!"), reopen)
    return
  elseif reason == "current" then
    pushText(game, textOr(game, "_CurrentTooFastText",
      "The current is much\ntoo fast!"), reopen)
    return
  elseif reason == "no_badge" then
    pushText(game, badgeRequired(game), reopen)
    return
  end

  pushText(game, noSurfText(game), reopen)
end

local function strengthFromMenu(game, reopen)
  local ow = game.overworld
  if not (ow and ow.map and ow.player) then
    fieldUnavailable(game, "STR", reopen)
    return
  end
  if not hasBadge(game, "STRENGTH") then
    pushText(game, badgeRequired(game), reopen)
    return
  end

  if ow.strengthActive then
    pushText(game, "STRENGTH is already\nbeing used.", reopen)
    return
  end

  ow.strengthActive = true
  pushText(game,
    "The HM device used\nSTRENGTH!\fBoulders can now\nbe moved.")
end

local function flashFromMenu(game, reopen)
  local ow = game.overworld
  if not (ow and ow.map and ow.player) then
    fieldUnavailable(game, "FLASH", reopen)
    return
  end
  if not hasBadge(game, "FLASH") then
    pushText(game, badgeRequired(game), reopen)
    return
  end
  if not ow.dark then
    pushText(game, "It is already\nbright here.", reopen)
    return
  end

  game.save.flashLit = true
  pushText(game,
    textOr(game, "_FlashLightsAreaText",
      "A blinding FLASH\nlights the area!"),
    function()
      local Transition = require("src.render.Transition")
      game.stack:push(Transition.whiteFlash(game, nil, function()
        if ow.setDark then ow:setDark(false) else ow.dark = false end
      end))
    end)
end

local function flyFromMenu(game, mod, reopen)
  local ow = game.overworld
  if not (ow and ow.map and ow.player) then
    fieldUnavailable(game, "FLY", reopen)
    return
  end
  if not hasBadge(game, "FLY") then
    pushText(game, badgeRequired(game), reopen)
    return
  end
  if not isOutside(game, ow) then
    pushText(game, "FLY can't be used\nhere.", reopen)
    return
  end

  local current = ow
  mod.ui.push(game, "TownMap", {
    fly = true,
    onFly = function(mapId)
      if current and current.flyTo then current:flyTo(mapId) end
    end,
  })
end

local function openHMMenu(game, mod)
  local Menu = require("src.ui.Menu")
  local Screens = require("src.ui.Screens")

  local function reopen()
    openHMMenu(game, mod)
  end

  local items = {}

  for _, moveId in ipairs(HM_ORDER) do
    if ownedHM(game, moveId) then
      if moveId == "CUT" then
        items[#items + 1] = {
          label = HM_LABEL[moveId],
          onSelect = function() cutFromMenu(game, reopen) end,
        }
      elseif moveId == "FLY" then
        items[#items + 1] = {
          label = HM_LABEL[moveId],
          onSelect = function() flyFromMenu(game, mod, reopen) end,
        }
      elseif moveId == "SURF" then
        items[#items + 1] = {
          label = HM_LABEL[moveId],
          onSelect = function() surfFromMenu(game, reopen) end,
        }
      elseif moveId == "STRENGTH" then
        items[#items + 1] = {
          label = HM_LABEL[moveId],
          onSelect = function() strengthFromMenu(game, reopen) end,
        }
      elseif moveId == "FLASH" then
        items[#items + 1] = {
          label = HM_LABEL[moveId],
          onSelect = function() flashFromMenu(game, reopen) end,
        }
      end
    end
  end

  if #items == 0 then
    pushText(game, "No usable HM is\nin the BAG.", function()
      Screens.push(game, "StartMenu")
    end)
    return
  end

  -- The toggle is deliberately inside the HM menu so players can switch
  -- contextual actions instantly, per save, without restarting or changing
  -- the core "HM in Bag = usable" behavior.
  local contextItem
  contextItem = {
    label = contextualEnabled(mod) and "CTX ON" or "CTX OFF",
    keepOpen = true,
    onSelect = function()
      local enabled = not contextualEnabled(mod)
      setContextual(mod, enabled)
      contextItem.label = enabled and "CTX ON" or "CTX OFF"
      mod.log:info("HM Anywhere contextual actions: %s",
        enabled and "ON" or "OFF")
    end,
  }
  items[#items + 1] = contextItem

  game.stack:push(Menu.new(game, items, {
    tx = 10,
    ty = 0,
    tw = 10,
    onCancel = function()
      Screens.push(game, "StartMenu")
    end,
  }))
end

return function(mod)
  mod.events:on("game.ready", function(event)
    local game = event and event.game
    local OverworldState = game and game.overworld
    if not (game and type(OverworldState) == "table") then
      mod.log:warn("HM Anywhere could not install: game.ready had no overworld; restart with the mod enabled")
      return
    end
    if type(OverworldState.interact) ~= "function"
       or type(OverworldState.partyKnows) ~= "function" then
      mod.log:warn("HM Anywhere could not find the expected overworld field-move methods; check game compatibility")
      return
    end

    local dispatch = rawget(_G, PATCH_KEY)
    if not dispatch then
      dispatch = {
        baseInteract = OverworldState.interact,
        basePartyKnows = OverworldState.partyKnows,
      }
      rawset(_G, PATCH_KEY, dispatch)

      OverworldState.interact = function(self, ...)
        local handler = dispatch.interact
        if handler then return handler(self, ...) end
        return dispatch.baseInteract(self, ...)
      end

      OverworldState.partyKnows = function(self, moveId, ...)
        local handler = dispatch.partyKnows
        if handler then
          local mon = handler(self, moveId, ...)
          if mon then return mon end
        end
        return dispatch.basePartyKnows(self, moveId, ...)
      end
    end

    dispatch.interact = function(ow, ...)
      return contextualInteract(game, mod, dispatch.baseInteract, ow, ...)
    end
    dispatch.partyKnows = function(_, moveId)
      if FIELD_HMS[moveId] and ownedHM(game, moveId) then
        return fieldHelper(game)
      end
      return nil
    end

    mod.log:info(
      "HM Anywhere installed: all owned HMs are in Start -> HM; contextual CUT/SURF/STRENGTH is %s",
      contextualEnabled(mod) and "ON" or "OFF")
  end)

  -- Remove redundant field-action rows from each Pokemon's submenu. HMs
  -- remain teachable and usable in battle; manual field use lives in Start -> HM.
  mod.hooks:wrap("ui.party.submenu", function(next_, game, items, mon, ctx)
    local out = next_(game, items, mon, ctx)
    if type(out) ~= "table" or (ctx and ctx.battle) then return out end
    return removeVanillaHMRows(out)
  end)

  -- Start -> HM now appears for ANY owned field HM, not only FLASH/FLY.
  mod.hooks:wrap("ui.start_menu.items", function(next_, game, items)
    local out = next_(game, items)
    if type(out) ~= "table" then return out end
    if not hasAnyHM(game) then return out end
    for _, item in ipairs(out) do
      if tostring(item.label):upper() == "HM" then return out end
    end
    return mod.ui.insertBefore(out, "SAVE", {
      label = "HM",
      onSelect = function()
        openHMMenu(game, mod)
      end,
    })
  end)

  mod.exports.ownedHM = function(game, moveId)
    return ownedHM(game, moveId) ~= nil
  end
  mod.exports.hasBadge = hasBadge
  mod.exports.contextualEnabled = function()
    return contextualEnabled(mod)
  end
  mod.exports.setContextual = function(enabled)
    setContextual(mod, enabled)
  end
end
