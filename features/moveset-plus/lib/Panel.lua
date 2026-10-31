-- The comparison panel: the four moves the Pokémon knows plus the one it is
-- learning, the highlighted move's type, power, accuracy and PP, and its short
-- description. 160x144, the game's own font and boxes.
--
-- Layout follows the compact mode of the Gen 2 panel so the two mods read the
-- same: title, five rows with a cursor, stats, description, footer.

local Info = ...

local Font = require("src.render.Font")

local Panel = {}

local CURSOR = 0xED

local function print(text, x, y)
  love.graphics.setColor(0, 0, 0, 1)
  Font.draw(text, x, y)
end

local function fit(text, width)
  if Font.width(text) <= width then return text end
  local out = ""
  for _, span in ipairs(Font.split(text)) do
    local next_ = out .. text:sub(span.from, span.to)
    if Font.width(next_ .. "...") > width then break end
    out = next_
  end
  return out .. "..."
end

local function wrap(text, columns, rows)
  local lines, line = {}, ""
  for word in tostring(text or ""):gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if Font.width(candidate) > columns * 8 and line ~= "" then
      lines[#lines + 1] = line
      line = word
    else
      line = candidate
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  while #lines > rows do table.remove(lines) end
  return lines
end

function Panel.draw(game, moves, focus, state, w, h)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.rectangle("fill", 0, 0, w, h)
  Font.drawBox(0, 0, w / 8, h / 8)

  local selected = Info.move(game, moves[focus] or moves[1])
  print(fit(Info.label("MOVES") .. " " .. #moves, w - 16), 8, 4)

  -- Five rows: the known moves first, the incoming one last.
  for index, entry in ipairs(moves) do
    local info = Info.move(game, entry)
    local prefix = index == #moves and (Info.label("NEW") .. " ") or (index .. " ")
    if index == focus then
      love.graphics.setColor(0, 0, 0, 1)
      Font.drawCode(CURSOR, 8, 16 + (index - 1) * 8)
    end
    print(fit(prefix .. info.name, w - 32), 24, 16 + (index - 1) * 8)
  end

  local statsY = 16 + #moves * 8 + 8
  print(fit(Info.label("TYPE") .. " " .. selected.type, w - 16), 8, statsY)
  print("PP " .. selected.pp, 8, statsY + 8)
  print(fit(Info.label("PWR") .. " " .. selected.power, w - 16), 8, statsY + 16)
  print(fit(Info.label("ACC") .. " " .. selected.accuracy, w - 16), 8, statsY + 24)

  local descriptionY = statsY + 32
  local rows = math.max(1, math.floor((h - 16 - descriptionY) / 8))
  for index, line in ipairs(wrap(selected.description, math.floor((w - 16) / 8), rows)) do
    print(line, 8, descriptionY + (index - 1) * 8)
  end

  local footer = focus == #moves
    and Info.label("A: DECLINE  B: BACK")
    or Info.label("A: REPLACE  B: BACK")
  print(fit(footer, w - 16), 8, h - 12)
end

return Panel
