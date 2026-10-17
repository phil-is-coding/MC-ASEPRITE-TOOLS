# SCOPE — MC-ASEPRITE-TOOLS

## Responsibilities

Minecraft texture tools for Aseprite. Each tool previews the texture being edited as it
appears in the game and updates during painting.

- **Skin viewer** (available): 3D preview of a 64x64 player skin on the classic or slim
  model. Creates new skins from the default Steve or Alex skin, a UV guide, or a blank
  canvas.
- **Block and item viewer** (planned): preview of block and item textures for resource
  packs.

Design constraints:

- Runs entirely inside Aseprite, in Lua, on Aseprite's scripting API. No browser, helper
  process, or bundled third-party code.
- Negligible cost when idle. A viewer redraws only when the texture or the view changes.

## Non-goals

- Distributing Mojang's textures. None are committed to this repository or included in
  the package.
- Painting on the 3D model. Editing stays in Aseprite's canvas.
- Building, validating, or packaging resource packs.
- Posing or animating the player model.
- Capes, elytra, armor, and HD skins.
- GPU rendering. All rendering is done on the CPU.
- Minecraft account integration, including skin upload.

## Related

- [Aseprite scripting API](https://www.aseprite.org/api/): defines what an extension can
  do. It provides no hover tooltips, no separate OS window per extension, and delivers
  key presses only to the focused widget.
- Viewer settings are stored in Aseprite's per-extension preferences.

## Legal

This software is not an official Minecraft product. It is not approved by or associated
with Mojang or Microsoft. "Minecraft" is a trademark of Mojang Synergies AB.
