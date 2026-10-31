-- Every asset a feature registers must exist inside that feature's folder.
--
-- The proxy scopes mod:read, and it has to scope mod.assets too: the engine's
-- assets:path/image close over the real mod root, so an unscoped proxy sends
-- every feature looking for art at the pack root. That failure is silent --
-- images just do not draw -- which is how the menu icons shipped broken once.
--
-- Run it against an installed copy -- the release ZIP unpacked into an engine's
-- mods directory -- from that engine's root, so the registered paths are the
-- ones the engine actually hands to love.graphics:
--   luajit mods/gmarcs_gen1_qol_mod/tests/assets.lua

package.path = './?.lua;./?/init.lua;' .. package.path
love = require('tests.love_stub')
require('src.core.GameVersion').set('red')

local script = (arg and arg[0]) or ''
local root = script:match('^(.*)/tests/[^/]+$')
assert(root and root ~= '', 'run this test from the pack directory')

local T = require('tests.modkit')
local Data = require('src.core.Data')
Data:load()

local run = T.sdk.loadMod(root, { data = Data, generation = 1 })
assert(#run.errors == 0, 'load errors: ' .. tostring(run.errors[1]))

local function exists(path)
  local handle = io.open(path, 'rb')
  if not handle then return false end
  handle:close()
  return true
end

-- Icons are the case that broke: every registered icon must point at a file
-- inside the pack.
local icons = assert(run.loader.content.icons, 'no icons registry')
local total, mine, missing, escaped = 0, 0, 0, 0
for id, value in icons:each() do
  total = total + 1
  if type(value) == 'table' and type(value.image) == 'string' then
    mine = mine + 1
    if not value.image:find('/features/unique-menu-icons/', 1, true) then
      escaped = escaped + 1
      if escaped <= 3 then print('OUTSIDE THE FEATURE FOLDER: ' .. value.image) end
    elseif not exists(value.image) then
      missing = missing + 1
      if missing <= 3 then print('MISSING: ' .. value.image) end
    end
  end
end

assert(mine > 0, 'Unique Menu Icons registered no artworks')
assert(escaped == 0, escaped .. ' icon paths resolve outside their feature folder')
assert(missing == 0, missing .. ' icon files do not exist')

io.write(('icons: %d registry entries, %d unique, all inside the pack\n'):format(
  total, mine))
print('ASSETS RESOLVE PASS')
