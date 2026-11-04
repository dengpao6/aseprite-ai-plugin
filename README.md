# Aseprite MCP Bridge

This extension and the included MCP server connect Aseprite to local AI agents
that speak the Model Context Protocol (MCP). Two agents are supported out of
the box:

- **Codex**, configured through `~/.codex/config.toml`.
- **DeepSeek Harness (DSH)**, configured through the DSH home patch
  `$DSH_HOME/cordis.patch.yml`.

The MCP server communicates with each agent over stdio. A shared local broker
relays requests between any number of MCP sessions and the Lua extension;
Aseprite connects to the broker at `ws://127.0.0.1:8765`. Codex and DSH can be
connected at the same time and share that single Aseprite connection.

## Install

1. Install Node.js 18 or newer. In `codex-aseprite/mcp-bridge`, run:

   ```powershell
   npm install
   ```

2. From the `codex-aseprite` directory, create the extension archive:

   ```powershell
   .\package.ps1
   ```

3. In Aseprite, open **Edit > Preferences > Extensions > Add Extension** and
   select the generated `codex-aseprite.aseprite-extension.zip`. Enable the
   extension if needed.
4. When enabled, the extension registers its MCP server and creates a shared
   token stored in the extension preferences. Approve Aseprite's file-access
   prompts:
   - It adds or updates `[mcp_servers.codex-aseprite]` in
     `%USERPROFILE%\.codex\config.toml` (or `$HOME/.codex/config.toml` on
     macOS/Linux).
   - When a DeepSeek Harness home directory exists (`%USERPROFILE%\.dsh`, or
     `$DSH_HOME`), it adds or updates an `mcp-aseprite` row in the home patch
     `cordis.patch.yml` inside that directory.
5. In Aseprite, choose **File > Scripts > MCP Bridge > Connect to local bridge**.
   Approve the script's WebSocket access prompt for `127.0.0.1` if shown.

The archive contains both the Lua extension and MCP bridge files. The bridge
requires Node.js to be installed and available as `node`. Dropping this source
folder at the Aseprite repository root does not load it; install the extension
archive through Preferences.

The extension menu is **File > Scripts > MCP Bridge**:

- **Connect to local bridge** starts the Aseprite WebSocket connection.
- **Disconnect** closes it.
- **Connection status** reports the bridge state and both agent registrations.
- **Register with Codex** rewrites the Codex MCP entry (for example after
  moving the extension or changing the token).
- **Register with DeepSeek Harness** rewrites the DSH MCP entry.
- **Set DeepSeek Harness home...** changes the detected DSH home folder.

Registration runs on every Aseprite start, so updating or reinstalling the
extension refreshes the server path automatically.

## DeepSeek Harness (DSH) setup

The DSH adapter uses the built-in `@deepseek-ai/dsh-mcp-client` plugin, which
ships with current DSH builds. Registration inserts one row into the DSH home
patch (`$DSH_HOME/cordis.patch.yml`, by default
`%USERPROFILE%\.dsh\cordis.patch.yml`):

```yaml
- insert:
    - id: mcp-aseprite
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: aseprite
        transport: stdio
        command: 'C:\Program Files\nodejs\node.exe'
        args:
          - 'C:\Users\you\AppData\Roaming\Aseprite\extensions\codex-aseprite\mcp-bridge\server.mjs'
        env:
          ASEPRITE_BRIDGE_TOKEN: '<shared bridge token>'
```

Notes:

- DSH must have been started at least once so its home directory exists. If the
  home is missing, start DSH once and run **Register with DeepSeek Harness**
  again, or set the home folder from the menu.
- The extension writes an absolute `node` path when it can find one on `PATH`;
  otherwise it writes `node`. DSH starts the bridge with a scrubbed environment,
  so an absolute path is the most reliable choice.
- The home patch is machine-local configuration that applies to every DSH
  profile and outranks per-profile patches. DSH's configuration editor only
  writes profile patches, so this row stays under the extension's control.
- Other rows in `cordis.patch.yml` (locale, theme, model settings) are
  preserved. Re-running registration is idempotent and replaces only the
  `mcp-aseprite` row.
- When DSH runs with hot reload (`dsh-hmr`), the new MCP server is mounted
  without a restart. Otherwise restart DSH after registering.

Tool names are namespaced by the configured `serverName`, for example
`mcp__aseprite__get_active_sprite` or `mcp__aseprite__draw_stroke`.

## Codex setup

Registration writes this entry to `~/.codex/config.toml`:

```toml
[mcp_servers.codex-aseprite]
command = "node"
args = ["C:\\path\\to\\codex-aseprite\\mcp-bridge\\server.mjs"]
env = { ASEPRITE_BRIDGE_TOKEN = "<shared bridge token>" }
```

Restart Codex after the entry is created or updated.

## MCP tools

Codex and DSH get the same 42 tools from the MCP server.

### Generate images

- **Configure the API once**: File > Scripts > MCP Bridge > Configure image API...
  Fill in a Base URL (default `https://api.openai.com/v1`), an API key, a model
  name (for example `gpt-image-1`), and an optional size such as `1024x1024`.
  The settings are written to `image-api.json` inside the extension folder and
  mirrored to `codex-aseprite-image.json` in Aseprite's user config folder. The
  API key is stored in plain text; leave Base URL/Model editable so any
  OpenAI-compatible provider works.
- `generate_image`: calls the configured API to generate a new image, or to use
  a reference image when `referenceImage` is passed. Without a reference image
  it posts JSON to `/images/generations`. With one it first tries OpenAI's
  multipart `/images/edits`; if that endpoint is missing (404/405), it retries
  `/images/generations` with an `image` field containing a base64 data URL,
  which is how providers such as Qwen's OpenAI-compatible mode implement
  image-to-image. Responses may use `b64_json` or `url`; results are saved under
  `%TEMP%\aseprite-mcp-gen` and returned as local paths that any agent can read,
  inspect, and pass to `stamp_image`. The result's `transport` field reports
  `generations`, `multipart`, or `image-field`.
- `get_image_api_status`: reports whether the API is configured, the base URL,
  model, size, and whether a key is set, without returning the key itself.

Both tools run inside the shared MCP server, so Codex and DSH get them equally;
nothing is tied to DSH.

### Look at the result

- `export_preview`: renders the active sprite with every visible layer
  flattened, writes a PNG under the system temp folder
  (`%TEMP%\aseprite-mcp-previews` on Windows) and returns its path, size, and
  byte count. Read that path to actually see the artwork between edits.
- `export_animation`: exports the whole animation as an animated GIF, a numbered
  PNG sequence, or a horizontal sprite sheet, and returns the output path(s).
  GIF output is produced by saving a temporary `.aseprite` copy and running
  Aseprite's own CLI on it in batch mode, because saving a GIF directly from a
  GUI script deadlocks the save job inside Aseprite; expect it to take a second
  or two longer than the PNG outputs.
- `sample_color`: returns the composited color of one pixel as `#RRGGBBAA`.
- `read_pixels`: returns a rectangle of composited pixels as rows of
  `#RRGGBBAA` values (at most 4096 pixels per call).

### Inspect

- `ping`: checks that the Aseprite extension is reachable.
- `get_connection_status`: reports the extension's WebSocket connection state.
- `get_active_sprite`: returns the filename, modified state, dimensions, frame
  count and per-frame durations, active frame and layer (with its stable id),
  color mode, palette (index colors are included for indexed sprites), animation
  tags, selection bounds, selected tool, and foreground/background colors.
- `list_layers`: lists image, group, and tilemap layers with their stable ids,
  nesting depth, parent name, stack order, visibility, editability, and opacity.
- `list_cels`: reports which layers hold a cel on a frame (defaults to the
  active frame); `allFrames: true` returns the cel occupancy and duration of
  every frame.
- `list_documents`: lists every open document with its index, filename, size,
  frame count, modified state, and active flag.

### Documents

- `create_sprite`: creates a new document with the requested width, height, and
  color mode (`rgb`, `grayscale`, or `indexed`).
- `open_sprite`: opens a sprite file and makes it active.
- `activate_document` / `close_document`: switch or close a document by index
  or filename. A modified document is only closed when `force` is true.
- `resize_sprite`: resizes the canvas; existing content keeps its top-left
  origin.
- `save_sprite`: saves the current sprite to its existing filename, or to a new
  path when `filename` is provided.

### Layers and cels

- `new_layer` / `new_group`: add an image layer or group.
- `set_active_layer`: selects a layer by name or by its stable `layerId`.
- `set_layer_properties`: renames a layer or changes its visibility,
  editability, or opacity (0-255).
- `delete_layer`: removes a layer by name or id. The last layer is protected.
- `duplicate_layer`: duplicates a layer above its source.
- `merge_down_layer`: merges a layer into the one below it.
- `flatten_sprite`: flattens all layers into one.
- `new_cel`: creates or replaces the cel of one layer on one frame, optionally
  copying the cel content (and position) from another frame to start from an
  existing keyframe.
- `delete_cel`: removes the cel of one layer on one frame without deleting the
  frame itself.

### Frames and tags

- `set_active_frame`: selects a 1-based frame number.
- `add_frame`: appends a copied frame or an empty frame.
- `duplicate_frame`: inserts a copy of a frame right after it and selects the
  copy, so a keyframe can be duplicated and then edited in place.
- `delete_frame`: removes a frame. The last frame is protected.
- `set_frame_duration`: sets a frame's display duration in milliseconds.
- `new_tag`: creates an animation tag over a frame range with an optional
  direction (`forward`, `reverse`, `ping-pong`, `ping-pong-reverse`) and repeat
  count.
- `edit_tag`: renames a tag or changes its frame range, direction, or repeat
  count.
- `delete_tag`: removes an animation tag by name.

### Drawing

- `set_colors`: sets foreground and/or background color using `#RRGGBB` or
  `#RRGGBBAA`.
- `set_active_tool`: selects an installed Aseprite tool by id.
- `draw_stroke`: sends integer canvas coordinates to any installed Aseprite
  tool by its tool id (for example `pencil`, `eraser`, `line`, or
  `paint_bucket`). Optional parameters are `tool`, `color` (`#RRGGBB` or
  `#RRGGBBAA`), `frame` (1-based), and the target `layer` / `layerId`. A stroke
  is one undoable transaction, refreshes the display when it completes, and is
  limited to 2048 points. Drawing on a frame that has no cel creates it.
- `undo` / `redo`: step through the shared Aseprite undo history.

Edits are no longer saved automatically: document changes stay unsaved until
you call `save_sprite`, so a mistake can be undone without touching the file.
`get_active_sprite` reports `isModified` so an agent can tell whether a save is
needed.

Some Aseprite tools require a particular number or arrangement of points.
Their behavior follows Aseprite's own `app.useTool()` API; unsupported tool ids
or point arrangements return an operation error. Layer, frame, and tool
selection are limited to the active sprite; use `get_active_sprite` and
`list_layers` to inspect it first.

Layers can be addressed by `layer` (name) or `layerId`. When two layers share a
name, name lookup fails with an error that lists the candidate ids instead of
silently editing the first match; use `layerId` from `list_layers` in that case.

Preview PNGs accumulate in the temp folder; deleting that folder is safe.

The Lua script's remaining functions are internal helpers or local extension
lifecycle actions, not remote operations. For example, the bridge connection
is started or stopped from Aseprite's **File > Scripts > MCP Bridge** menu.

The extension automatically creates and shares the MCP authentication token.
Each agent session can start its own stdio MCP process; those processes connect
to one shared local broker on `127.0.0.1:8766`, which forwards their requests
over the single Aseprite connection. The broker starts automatically with the
first MCP process and runs independently so it can be reused by later
sessions. Its WebSocket endpoints bind only to loopback. Do not expose them on
a network interface.

## Troubleshooting

- **Agent tools disappeared after reinstalling or updating the extension.**
  A fresh install can regenerate the shared token, while an already running
  broker and agent still hold the previous one; the new MCP process is then
  rejected at authentication. Restart Aseprite so it loads the new extension
  and token, then restart the agent (Codex or DSH) so it reconnects with the
  current configuration.
- **DSH does not list the Aseprite tools.** Restart DSH; DSH usually reloads
  `cordis.patch.yml` through HMR, but a failed mount needs a restart. Check the
  `mcp-aseprite` row and re-run **Register with DeepSeek Harness** if the file
  was edited or moved.
- **Tool calls report "Aseprite is not connected".** Click **File > Scripts >
  MCP Bridge > Connect to local bridge** in Aseprite.
- **`Unknown method` errors after updating.** The installed Aseprite is still
  running the previous `main.lua`; restart Aseprite.

