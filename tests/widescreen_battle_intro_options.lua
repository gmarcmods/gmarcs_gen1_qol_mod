-- Exercise the vendored intro toggles through the assembled pack, including
-- the persisted product bucket and the transition.style constructor hook.
-- Run from a gen1recomp checkout with the pack in mods/:
--   luajit mods/gmarcs_gen1_qol_mod/tests/widescreen_battle_intro_options.lua

package.path = './?.lua;./?/init.lua;' .. package.path
love = require('tests.love_stub')
require('src.core.GameVersion').set('red')

local script = (arg and arg[0]) or ''
local root = script:match('^(.*)/tests/[^/]+$')
assert(root and root ~= '', 'run this test from the pack directory')
local T = require('tests.modkit')
local Game = require('src.core.Game')
local run = T.sdk.loadMod(root, { generation = 1 })
assert(#run.errors == 0, 'load errors: ' .. tostring(run.errors[1]))
Game.mods = run.loader
Game.save = { options = {} }
local writes = 0
Game.writeOptions = function() writes = writes + 1 end

local Runtime = require('src.mods.Runtime')
local rows = Runtime.call('ui.options.rows', function(_, current) return current end,
                          Game, {})
local flashless, outro
for _, row in ipairs(rows) do
  if row.id == 'flashless_intros' then flashless = row end
  if row.label == 'BLACK OUTRO' then outro = row end
end
assert(flashless and outro, 'both intro options appear in the pack menu')
assert(flashless.value() == 'OFF', 'flashless intro defaults off')
flashless.step()
local options = run.loader.modOptions.gmarcs_gen1_qol_mod
assert(options and options['widescreen-battle-intro.flashless_intros'] == true,
       'flashless toggle persists under its namespaced pack key')
assert(Game.save.options.modOptions.gmarcs_gen1_qol_mod[
         'widescreen-battle-intro.flashless_intros'] == true,
       'flashless toggle mirrors into save options')
assert(writes == 1, 'toggle writes options.lua')

local style = Runtime.call('transition.style', function() return 'vanilla' end, {})
assert(style == 'spiralout', 'battle transition constructor sees the persisted toggle')

outro.step()
assert(options['widescreen-battle-intro.black_outro'] == false,
       'black outro toggle persists under its namespaced pack key')
assert(writes == 2, 'both toggles write options.lua')
run.release()
print('WIDESCREEN BATTLE INTRO OPTIONS PASS')
