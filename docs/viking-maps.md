# Viking graphical maps

The **Map** tab beside Sea shows the territory map already available at
`/vik map`. The **Sea** tab (`/vik sea`) shows the voyage chart. The **War**
tab includes campaign and battle boards; `/vik war` opens the active board
in a larger popup. These consume the existing Guild.Map, Guild.Voyage,
Guild.Kingdom and Guild.War data; `vmap` remains a server command.

In native GUI mode, right-click the page body and select **Images (off =
ASCII)** on Map/Sea, or **ASCII Map (off = images)** on War. In the War
popup, right-click the header/background; right-clicking battle squares
retains the deployment/selection actions. Preferences are shared between
tabs and popups and saved by the existing page-options persistence.

TTY and headless sessions always use ASCII. Their menus omit these controls,
and `/vik set` refuses image-mode changes there. Merely having the image Lua
API is insufficient: the plugin checks `lera.display() == "gui"` as well.
Browser sessions hosted by a headless Lera therefore remain ASCII.

The original PNG files were supplied from Telegram's `images/viking_cityplan`
and `images/viking_voyage` folders. Selection rules are ported from the
supplied `guild_viking (2).lua`: N=1/E=2/S=4/W=8, terrain-specific aliases,
territory water-family joins and isolated diagonal corners, voyage feature
underlays with priority tie-breaking, and south-origin battle coordinates.
Only PNGs are bundled, not the downloaded scripts or recovery directories.

Images are loaded lazily and cached, including missing-file results until
plugin reload. Every image uses the same grid geometry as text and hit
testing, and only fully visible cells are placed inside the pane viewport.
Text remains underneath as the fallback if an image cannot be loaded.

Lera's current image API uses character-cell rectangles and covers underlying
text; it does not support MUSHclient's pixel-level text/rectangle overlays.
Tiles fit the pane width and height after reserving space for headings,
status and legends, up to two text rows high. GUI cell proportions keep
the art approximately square. Multiple boards share the height budget.
Tiles fill their cells edge-to-edge with no marker rows or letterbox gaps.
Sailed status is available on hover; selecting a unit temporarily shows its
reverse-video glyph in place. Narrow panes clip the board without changing
the PNG preference. Works and deployment cells retain their glyphs.
This preserves tactical information without claiming
pixel-identical MUSHclient overlays. A narrow pane can use `/vik war` or
`/vik map` for more space.

Validation: `LERA_ROOT=/path/to/lera ./run_tests.sh`. The tile suite covers
all 16 neighbour masks, actual bundled assets, GUI gating, cached loads,
scroll clipping, text/image hit geometry, battle orientation, both inline
war boards and the Map tab. The supplied corpus also passed a native Lera
image-load audit (858 PNGs).
