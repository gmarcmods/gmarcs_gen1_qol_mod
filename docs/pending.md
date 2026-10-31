# Pending work

## More widescreen screens

Widescreen Menus v1.0 covers the party list and the summary. The same seam
(screen `uiSize` + `Renderer:setUISize`) extends to the PC, bag and options
screens; each needs its own pane and hit-testing check.

## Options migration

Toggles saved under the standalone mod ids do not carry into the pack: option
keys are namespaced `<feature>.<key>`. A migration would copy the old per-mod
buckets on first load.

## On-device verification

Both packs are load-tested against the engine and their asset paths verified,
but neither has been played through on hardware. Installing a pack means
disabling the standalone mods it replaces first.
