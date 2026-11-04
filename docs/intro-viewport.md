# Battle intro window coverage — 1.1.5

The imported intro mod treated the presence of Renderer.screenVeil as proof that the flash covered the whole window. Official gen1recomp can instead draw that veil inside a faithful-resolution game rectangle or a narrower viewport. The mod skipped its supplement in that case, leaving black bars during the white flash.

Widescreen Battle Intro 1.6.1 reads the actual frame bounds returned by Renderer.endFrame and paints only the uncovered parts. The native image is never shaded twice, and the supplementary rectangles do not overlap at corners. The wipe is extended across the display using the existing native tile grid, preserving the game anchor and tile scale. Engine source is unchanged.

Regression coverage: the old source fails five viewport assertions; the maintained source passes all 14. The existing 118-check intro suite and QoL option persistence/load tests also pass. The actual Gen 1 renderer was tested with its locked-scale path selected in an isolated desktop process: at the frozen white-flash step, the old pack has black corners and a white center, while the new pack has white at the center and all four corners. This exercises the mobile-lock compositor policy; it is not physical phone verification.

This feature affects transitions into battles. Oak's new-game speech and the opening movie are separate screens. Media: exports/media/gen1-intro-1.1.5 at workspace root. Driver: workspace/tests/qol_intro_viewport_live.lua.
