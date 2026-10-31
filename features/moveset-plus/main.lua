-- Moveset Plus for Red, Blue and Yellow.
--
-- The Gen II mod of the same name compares the four moves a Pokémon knows with
-- the one it is learning: type, power, accuracy and PP side by side, and the
-- new move as a fifth row you can decline.
--
-- Gen 1 asks the same question in src/ui/MoveLearnMenu.lua ("Which move should
-- be forgotten?"), a list of the four known moves drawn by the screen itself.
-- This replaces that list with the five-row panel and keeps the engine's rules:
-- an HM cannot be forgotten, B abandons the new move, and replacing a move
-- writes the same record the native list wrote.

return function(mod)
  local Info = assert(loadstring(assert(mod:read("lib/Info.lua")),
    "@MovesetPlusGen1/Info"))()
  local Panel = assert(loadstring(assert(mod:read("lib/Panel.lua")),
    "@MovesetPlusGen1/Panel"))(Info)

  local MoveLearnMenu = require("src.ui.MoveLearnMenu")

  local HM_MOVES = { CUT = true, FLY = true, SURF = true, STRENGTH = true,
                     FLASH = true }

  local function entries(self)
    local list = {}
    for _, move in ipairs(self.mon.moves or {}) do list[#list + 1] = move end
    list[#list + 1] = self.newMoveId
    return list
  end

  local function count(self)
    return #(self.mon.moves or {}) + 1
  end

  -- Draw: only while the forget list is up. The "trying to learn" prompt is
  -- still the engine's text box, drawn by the text system before this.
  local baseDraw = MoveLearnMenu.draw
  MoveLearnMenu.draw = function(self)
    if not self.selecting then return baseDraw(self) end
    local moves = entries(self)
    if self.index > #moves then self.index = 1 end
    Panel.draw(self.game, moves, self.index, self, 160, 144)
  end

  -- Update: the native navigation plus the fifth row. Rows 1..4 replace a
  -- move, row 5 and B both mean "do not learn it".
  local baseUpdate = MoveLearnMenu.update
  MoveLearnMenu.update = function(self, dt)
    if not self.selecting then return baseUpdate(self, dt) end
    local input = self.game.input
    local total = count(self)
    if self.index > total then self.index = 1 end

    if input:wasPressed("up") then
      self.index = self.index > 1 and self.index - 1 or total
    elseif input:wasPressed("down") then
      self.index = self.index < total and self.index + 1 or 1
    elseif input:wasPressed("b") then
      self:confirmAbandon()
    elseif input:wasPressed("a") then
      if self.index > #self.mon.moves then
        self:confirmAbandon()
        return
      end
      local old = self.mon.moves[self.index]
      if HM_MOVES[old.id] then
        local TextBox = require("src.render.TextBox")
        local romText = require("src.core.RomText")
        self.selecting = false
        self.game.stack:push(TextBox.new(self.game,
          romText(self.game.data, "_HMCantDeleteText",
            "HM techniques\ncan't be deleted!"),
          function() self:askForget() end))
        return
      end
      local mdef = self.game.data.moves[self.newMoveId]
      self.mon.moves[self.index] = { id = self.newMoveId, pp = mdef.pp }
      self.forgot = self.game.data.moves[old.id].name
      self:finish(true)
    end
  end

  MoveLearnMenu.__movesetPlusGen1 = true

  mod.exports.info = Info.move
  mod.exports.cursor = function(menu) return menu.index end
end
