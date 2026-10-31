-- Widescreen menus for Red, Blue and Yellow.
--
-- Gen 1 menus are drawn on a fixed 160x144 playfield. The renderer can give a
-- screen a wider native surface (Renderer:setUISize, asked for by a screen's
-- uiSize) -- that is how the wide battle layout works -- so a menu can keep its
-- own coordinates on the left and use the extra width for a detail pane.
--
-- v1.0 covers the two screens that always needed one: the party list (stats and
-- moves of the selected Pokémon) and the summary (the moves beside the stats).
-- The seam is the same for the rest.

return function(mod)
  local Layout = assert(loadstring(assert(mod:read("lib/Layout.lua")),
    "@WidescreenMenusGen1/Layout"))()
  local Font = require("src.render.Font")

  local function wideWidth()
    local ok, w, h = pcall(function()
      return love.graphics.getDimensions()
    end)
    if not ok then return Layout.NATIVE end
    return Layout.uiWidth(w, h)
  end

  local function drawPane(lines, x, width)
    if width - x < 48 then return end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", x, 0, width - x, Layout.HEIGHT)
    Font.drawBox(x / 8, 0, (width - x) / 8, Layout.HEIGHT / 8)
    love.graphics.setColor(0, 0, 0, 1)
    local y = 8
    for _, line in ipairs(lines) do
      if y > Layout.HEIGHT - 16 then break end
      Font.draw(line:sub(1, math.max(1, math.floor((width - x - 16) / 8))), x + 8, y)
      y = y + 8
    end
  end

  local function widen(screen, linesFor)
    local baseSize = screen.uiSize
    screen.uiSize = function(self)
      local width = wideWidth()
      if width <= Layout.NATIVE then
        if baseSize then return baseSize(self) end
        return nil
      end
      return width, Layout.HEIGHT
    end
    local baseDraw = screen.draw
    screen.draw = function(self, ...)
      local width = (self:uiSize())
      if not width or width <= Layout.NATIVE then return baseDraw(self, ...) end
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.rectangle("fill", Layout.NATIVE, 0, width - Layout.NATIVE, Layout.HEIGHT)
      local result = baseDraw(self, ...)
      drawPane(linesFor(self), Layout.NATIVE, width)
      return result
    end
  end

  local PartyMenu = require("src.ui.PartyMenu")
  widen(PartyMenu, function(self)
    local party = self.party or (self.game and self.game.save and self.game.save.party) or {}
    return Layout.partyLines(party[self.index or 1], self.game and self.game.data)
  end)

  local SummaryMenu = require("src.ui.SummaryMenu")
  widen(SummaryMenu, function(self)
    return Layout.summaryLines(self.mon, self.game and self.game.data)
  end)

  mod.exports.uiWidth = wideWidth
  mod.exports.partyLines = Layout.partyLines
  mod.exports.summaryLines = Layout.summaryLines
end
