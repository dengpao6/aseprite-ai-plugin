local websocketUrl = "ws://127.0.0.1:8765"
local bridgeToken = nil
local maxStrokePoints = 2048
local dshServerId = "mcp-aseprite"
local dshServerName = "aseprite"
local dshMcpClientPackage = "@deepseek-ai/dsh-mcp-client"

local connection = nil
local connectionState = "disconnected"
local parseColor

local function sendResponse(socket, response)
  local ok, message = pcall(function()
    socket:sendText(json.encode(response))
  end)

  if not ok then
    print("Aseprite MCP: failed to send response: " .. tostring(message))
  end
end

local function constantTimeEquals(a, b)
  if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
    return false
  end

  local difference = 0
  for i = 1, #a do
    if a:byte(i) ~= b:byte(i) then
      difference = difference + 1
    end
  end
  return difference == 0
end

local function requireObject(value, name)
  if type(value) ~= "userdata" and type(value) ~= "table" then
    error(name .. " must be a JSON object")
  end
end

local function requireInteger(value, name)
  if type(value) ~= "number" or value ~= value or
     value == math.huge or value == -math.huge or value % 1 ~= 0 then
    error(name .. " must be an integer")
  end
  return value
end

local function requireSprite()
  local sprite = app.activeSprite
  if not sprite then
    error("No sprite is currently open")
  end
  return sprite
end

local function colorModeName(mode)
  if mode == ColorMode.INDEXED then
    return "indexed"
  elseif mode == ColorMode.GRAYSCALE then
    return "grayscale"
  elseif mode == ColorMode.TILEMAP then
    return "tilemap"
  end
  return "rgb"
end

local function parseColorMode(value, name)
  if value == nil then
    return ColorMode.RGB
  end
  if type(value) ~= "string" then
    error(name .. " must be one of: rgb, grayscale, indexed")
  end
  local mode = value:lower()
  if mode == "rgb" then
    return ColorMode.RGB
  elseif mode == "grayscale" or mode == "gray" then
    return ColorMode.GRAYSCALE
  elseif mode == "indexed" then
    return ColorMode.INDEXED
  end
  error(name .. " must be one of: rgb, grayscale, indexed")
end

local function parseAniDir(value)
  if value == nil then
    return nil
  end
  if type(value) ~= "string" then
    error("aniDir must be forward, reverse, ping-pong, or ping-pong-reverse")
  end
  local direction = value:lower()
  if direction == "forward" then
    return AniDir.FORWARD
  elseif direction == "reverse" then
    return AniDir.REVERSE
  elseif direction == "ping-pong" or direction == "pingpong" then
    return AniDir.PING_PONG
  elseif direction == "ping-pong-reverse" or direction == "pingpongreverse" then
    return AniDir.PING_PONG_REVERSE
  end
  error("aniDir must be forward, reverse, ping-pong, or ping-pong-reverse")
end

local function aniDirName(direction)
  if direction == AniDir.REVERSE then
    return "reverse"
  elseif direction == AniDir.PING_PONG then
    return "ping-pong"
  elseif direction == AniDir.PING_PONG_REVERSE then
    return "ping-pong-reverse"
  end
  return "forward"
end

local function colorToHex(color)
  return string.format("#%02X%02X%02X%02X",
    color.red, color.green, color.blue, color.alpha)
end

-- Aseprite RGBA pixels pack red in the lowest byte: 0xAABBGGRR.
local function pixelToHex(pixel)
  return string.format("#%02X%02X%02X%02X",
    pixel & 0xff, (pixel >> 8) & 0xff,
    (pixel >> 16) & 0xff, (pixel >> 24) & 0xff)
end

local function allLayers(sprite)
  local list = {}
  local function walk(layers)
    for _, layer in ipairs(layers) do
      list[#list + 1] = layer
      if layer.isGroup then
        walk(layer.layers)
      end
    end
  end
  walk(sprite.layers)
  return list
end

-- Resolves a layer from `layer` (name) or `layerId`. Duplicate names are an
-- error so a request never silently edits the wrong layer.
local function findLayerByParams(sprite, params)
  requireObject(params, "params")
  if params.layerId ~= nil then
    local layerId = requireInteger(params.layerId, "layerId")
    for _, layer in ipairs(allLayers(sprite)) do
      if layer.id == layerId then
        return layer
      end
    end
    error("Layer id not found: " .. layerId)
  end
  if type(params.layer) ~= "string" or params.layer == "" then
    error("Provide layer (name) or layerId")
  end
  local matches = {}
  for _, layer in ipairs(allLayers(sprite)) do
    if layer.name == params.layer then
      matches[#matches + 1] = layer
    end
  end
  if #matches == 0 then
    error("Layer not found: " .. params.layer)
  end
  if #matches > 1 then
    local ids = {}
    for _, layer in ipairs(matches) do
      ids[#ids + 1] = tostring(layer.id)
    end
    error("Layer name is ambiguous: " .. params.layer ..
          " matches layer ids " .. table.concat(ids, ", ") ..
          ". Use layerId instead.")
  end
  return matches[1]
end

local function resolveLayerOrActive(sprite, params)
  if params.layer ~= nil or params.layerId ~= nil then
    return findLayerByParams(sprite, params)
  end
  local layer = app.activeLayer
  if not layer then
    error("No active layer is selected")
  end
  return layer
end

local function frameDurations(sprite)
  local durations = {}
  for i = 1, #sprite.frames do
    durations[i] = math.floor(sprite.frames[i].duration * 1000 + 0.5)
  end
  return durations
end

local function tagInfo(tag)
  return {
    name = tag.name,
    from = tag.fromFrame.frameNumber,
    to = tag.toFrame.frameNumber,
    frames = tag.frames,
    aniDir = aniDirName(tag.aniDir),
    repeats = tag.repeats
  }
end

local function paletteInfo(sprite)
  local info = { count = #sprite.palettes }
  if #sprite.palettes > 0 then
    local palette = sprite.palettes[1]
    info.size = #palette
    if sprite.colorMode == ColorMode.INDEXED then
      local colors = {}
      for i = 0, #palette - 1 do
        colors[#colors + 1] = colorToHex(palette:getColor(i))
      end
      info.colors = colors
    end
  end
  return info
end

local function selectionInfo(sprite)
  local selection = sprite.selection
  if not selection or selection.isEmpty then
    return nil
  end
  local bounds = selection.bounds
  return {
    x = bounds.x,
    y = bounds.y,
    width = bounds.width,
    height = bounds.height
  }
end

local function spriteSummary(sprite)
  local layer = app.activeLayer
  local tool = app.activeTool
  local tags = {}
  for i = 1, #sprite.tags do
    tags[i] = tagInfo(sprite.tags[i])
  end
  return {
    filename = sprite.filename,
    isModified = sprite.isModified,
    width = sprite.width,
    height = sprite.height,
    frames = #sprite.frames,
    frame = app.activeFrame and app.activeFrame.frameNumber or 1,
    frameDurations = frameDurations(sprite),
    layer = layer and layer.name or nil,
    layerId = layer and layer.id or nil,
    tool = tool and tool.id or nil,
    colorMode = colorModeName(sprite.colorMode),
    palette = paletteInfo(sprite),
    tags = tags,
    selection = selectionInfo(sprite),
    foregroundColor = {
      red = app.fgColor.red,
      green = app.fgColor.green,
      blue = app.fgColor.blue,
      alpha = app.fgColor.alpha
    },
    backgroundColor = {
      red = app.bgColor.red,
      green = app.bgColor.green,
      blue = app.bgColor.blue,
      alpha = app.bgColor.alpha
    }
  }
end

-- Renders one frame with every visible layer composited into an RGB image,
-- so previews and pixel reads always observe the final look.
local function renderFrameToRgb(sprite, frame)
  local image = Image {
    width = sprite.width,
    height = sprite.height,
    colorMode = ColorMode.RGB
  }
  image:drawSprite(sprite, frame, Point(0, 0))
  return image
end

local previewCounter = 0

local function previewDirectory()
  local temp = os.getenv("TEMP")
  if not temp or temp == "" then
    temp = os.getenv("TMP")
  end
  if not temp or temp == "" then
    temp = os.getenv("TMPDIR")
  end
  if not temp or temp == "" then
    temp = "/tmp"
  end
  return app.fs.joinPath(temp, "aseprite-mcp-previews")
end

local function nextOutputPath(prefix, extension)
  local directory = previewDirectory()
  if not app.fs.makeAllDirectories(directory) then
    error("Could not create the preview directory: " .. directory)
  end
  previewCounter = previewCounter + 1
  return app.fs.joinPath(directory,
    string.format("%s-%d-%d.%s", prefix, os.time(), previewCounter, extension))
end

local function nextPreviewPath()
  return nextOutputPath("preview", "png")
end

local function saveImageForSprite(image, path, sprite)
  if sprite.colorMode == ColorMode.INDEXED then
    return image:saveAs { filename = path, palette = sprite.palettes[1] }
  end
  return image:saveAs(path)
end

local function getActiveSpriteInfo()
  return spriteSummary(requireSprite())
end

local function listLayers()
  local sprite = requireSprite()

  local layers = {}
  local function appendLayers(items, depth, parent)
    for _, layer in ipairs(items) do
      local item = {
        id = layer.id,
        name = layer.name,
        stackIndex = layer.stackIndex,
        depth = depth,
        parent = parent,
        visible = layer.isVisible,
        editable = layer.isEditable,
        group = layer.isGroup,
        image = layer.isImage,
        tilemap = layer.isTilemap,
        background = layer.isBackground
      }
      if layer.opacity ~= nil then
        item.opacity = layer.opacity
      end
      layers[#layers + 1] = item
      if layer.isGroup then
        appendLayers(layer.layers, depth + 1, layer.name)
      end
    end
  end
  appendLayers(sprite.layers, 0, nil)
  return { layers = layers }
end

local function setActiveTool(params)
  requireObject(params, "params")
  if type(params.tool) ~= "string" or params.tool == "" then
    error("tool must be a non-empty Aseprite tool id")
  end
  app.activeTool = params.tool
  local tool = app.activeTool
  if not tool or tool.id ~= params.tool then
    error("Aseprite tool not found: " .. params.tool)
  end
  return { tool = tool.id }
end

local function setActiveLayer(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local layer = findLayerByParams(sprite, params)
  app.activeLayer = layer
  return { layer = layer.name, layerId = layer.id }
end

local function createLayer(params, group)
  requireObject(params, "params")
  if params.name ~= nil and
     (type(params.name) ~= "string" or params.name == "") then
    error("name must be a non-empty string")
  end
  local sprite = app.activeSprite
  if not sprite then
    error("No sprite is currently open")
  end

  local layer
  if group then
    layer = sprite:newGroup()
  else
    layer = sprite:newLayer()
  end
  if params.name then
    layer.name = params.name
  end
  if not group then
    app.activeLayer = layer
  end
  return {
    name = layer.name,
    group = layer.isGroup
  }
end

local function addFrame(params)
  requireObject(params, "params")
  if params.empty ~= nil and type(params.empty) ~= "boolean" then
    error("empty must be a boolean")
  end
  local sprite = app.activeSprite
  if not sprite then
    error("No sprite is currently open")
  end
  local frame
  if params.empty then
    frame = sprite:newEmptyFrame()
  else
    frame = sprite:newFrame()
  end
  app.activeFrame = frame.frameNumber
  app.refresh()
  return { frame = frame.frameNumber, empty = params.empty == true }
end

local function deleteFrame(params)
  requireObject(params, "params")
  local sprite = app.activeSprite
  if not sprite then
    error("No sprite is currently open")
  end
  local frame = requireInteger(params.frame, "frame")
  if frame < 1 or frame > #sprite.frames then
    error("frame is outside the sprite's frame range")
  end
  if #sprite.frames <= 1 then
    error("Cannot delete the only frame in a sprite")
  end
  sprite:deleteFrame(frame)
  app.refresh()
  return { deletedFrame = frame, frames = #sprite.frames }
end

local function countLayers(layers)
  local count = 0
  for _, layer in ipairs(layers) do
    count = count + 1
    if layer.isGroup then
      count = count + countLayers(layer.layers)
    end
  end
  return count
end

local function deleteLayer(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local layer = findLayerByParams(sprite, params)
  if countLayers(sprite.layers) <= 1 then
    error("Cannot delete the only layer in a sprite")
  end
  local deletedName = layer.name
  local deletedId = layer.id
  local wasActive = app.activeLayer == layer
  sprite:deleteLayer(layer)
  if wasActive then
    app.activeLayer = sprite.layers[1]
  end
  app.refresh()
  return { deletedLayer = deletedName, deletedLayerId = deletedId }
end

local function setActiveFrame(params)
  requireObject(params, "params")
  local sprite = app.activeSprite
  if not sprite then
    error("No sprite is currently open")
  end
  local frame = requireInteger(params.frame, "frame")
  if frame < 1 or frame > #sprite.frames then
    error("frame is outside the sprite's frame range")
  end
  app.activeFrame = frame
  return { frame = app.activeFrame.frameNumber }
end

local function setColors(params)
  requireObject(params, "params")
  if params.foreground == nil and params.background == nil then
    error("at least one of foreground or background must be provided")
  end
  local foreground = parseColor(params.foreground)
  local background = parseColor(params.background)
  if foreground then
    app.fgColor = foreground
  end
  if background then
    app.bgColor = background
  end
  app.refresh()
  return {
    foreground = {
      red = app.fgColor.red,
      green = app.fgColor.green,
      blue = app.fgColor.blue,
      alpha = app.fgColor.alpha
    },
    background = {
      red = app.bgColor.red,
      green = app.bgColor.green,
      blue = app.bgColor.blue,
      alpha = app.bgColor.alpha
    }
  }
end

local function setLayerProperties(params)
  requireObject(params, "params")
  if params.name == nil and params.visible == nil and
     params.opacity == nil and params.editable == nil then
    error("provide at least one layer property to change")
  end
  if params.name ~= nil and
     (type(params.name) ~= "string" or params.name == "") then
    error("name must be a non-empty string")
  end
  if params.visible ~= nil and type(params.visible) ~= "boolean" then
    error("visible must be a boolean")
  end
  if params.editable ~= nil and type(params.editable) ~= "boolean" then
    error("editable must be a boolean")
  end
  if params.opacity ~= nil then
    params.opacity = requireInteger(params.opacity, "opacity")
    if params.opacity < 0 or params.opacity > 255 then
      error("opacity must be between 0 and 255")
    end
  end

  local sprite = requireSprite()
  local layer = findLayerByParams(sprite, params)
  if params.opacity ~= nil and not layer.isImage and not layer.isGroup then
    error("opacity can only be set on image or group layers")
  end
  if params.name ~= nil then
    layer.name = params.name
  end
  if params.visible ~= nil then
    layer.isVisible = params.visible
  end
  if params.editable ~= nil then
    layer.isEditable = params.editable
  end
  if params.opacity ~= nil then
    layer.opacity = params.opacity
  end
  app.refresh()

  return {
    name = layer.name,
    layerId = layer.id,
    visible = layer.isVisible,
    editable = layer.isEditable,
    opacity = layer.opacity
  }
end

parseColor = function(value)
  if value == nil then
    return nil
  end
  if type(value) ~= "string" then
    error("color must be a #RRGGBB or #RRGGBBAA string")
  end

  local red, green, blue, alpha = value:match("^#(%x%x)(%x%x)(%x%x)(%x%x)$")
  if not red then
    red, green, blue = value:match("^#(%x%x)(%x%x)(%x%x)$")
    alpha = nil
  end
  if not red then
    error("color must be a #RRGGBB or #RRGGBBAA string")
  end

  return Color(tonumber(red, 16),
               tonumber(green, 16),
               tonumber(blue, 16),
               alpha and tonumber(alpha, 16) or 255)
end

local function tomlString(value)
  return '"' .. value:gsub("\\", "\\\\")
                    :gsub('"', '\\"')
                    :gsub("\r", "\\r")
                    :gsub("\n", "\\n") .. '"'
end

local function userHomeDirectory()
  local home = os.getenv("USERPROFILE")
  if not home or home == "" then
    home = os.getenv("HOME")
  end
  if not home or home == "" then
    error("Could not locate the user home directory")
  end
  return home
end

local function readTextFile(path)
  local input, readError = io.open(path, "r")
  if not input then
    error("Could not read " .. path .. ": " .. tostring(readError))
  end
  local contents = input:read("*a")
  input:close()
  return contents
end

local function writeTextFile(path, contents)
  local output, writeError = io.open(path, "w")
  if not output then
    error("Could not write " .. path .. ": " .. tostring(writeError))
  end
  local wrote, writeFailure = output:write(contents)
  local closed, closeFailure = output:close()
  if not wrote then
    error("Could not save " .. path .. ": " .. tostring(writeFailure))
  end
  if not closed then
    error("Could not close " .. path .. ": " .. tostring(closeFailure))
  end
end

local function alertLines(lines)
  app.alert { text = lines }
end

local function tokenFilePath()
  local configPath = app.fs.userConfigPath
  if not configPath or configPath == "" then
    return nil
  end
  return app.fs.joinPath(configPath, "codex-aseprite-token.txt")
end

local function readStoredToken()
  local path = tokenFilePath()
  if not path or not app.fs.isFile(path) then
    return nil
  end
  local readOk, contents = pcall(readTextFile, path)
  if not readOk or type(contents) ~= "string" then
    return nil
  end
  contents = contents:gsub("%s+$", "")
  if #contents < 32 then
    return nil
  end
  return contents
end

local function writeStoredToken(token)
  local path = tokenFilePath()
  if not path then
    return
  end
  pcall(writeTextFile, path, token .. "\n")
end

local imageApiConfigFilename = "image-api.json"
local imageApiBackupFilename = "codex-aseprite-image.json"

local function imageApiConfigPath(plugin)
  return app.fs.joinPath(plugin.path, imageApiConfigFilename)
end

local function imageApiBackupPath()
  local configPath = app.fs.userConfigPath
  if type(configPath) ~= "string" or configPath == "" then
    return nil
  end
  return app.fs.joinPath(configPath, imageApiBackupFilename)
end

local function readImageApiConfig(plugin)
  local candidates = { imageApiConfigPath(plugin) }
  local backup = imageApiBackupPath()
  if backup then
    candidates[#candidates + 1] = backup
  end
  for _, candidate in ipairs(candidates) do
    if app.fs.isFile(candidate) then
      local readOk, contents = pcall(readTextFile, candidate)
      if readOk then
        local decodedOk, decoded = pcall(json.decode, contents)
        if decodedOk and type(decoded) == "userdata" then
          return decoded
        end
      end
    end
  end
  return nil
end

local function writeImageApiConfig(plugin, baseUrl, apiKey, model, size)
  local config = {
    baseUrl = baseUrl,
    apiKey = apiKey,
    model = model
  }
  if size ~= "" then
    config.size = size
  end
  local contents = json.encode(config)
  writeTextFile(imageApiConfigPath(plugin), contents)
  local backup = imageApiBackupPath()
  if backup then
    pcall(writeTextFile, backup, contents)
  end
end

local function ensureBridgeToken(plugin)
  local token = plugin.preferences.bridgeToken
  if type(token) ~= "string" or #token < 32 then
    -- Extension preferences live inside the extension folder and disappear
    -- when the extension is reinstalled. Reuse the copy kept in Aseprite's
    -- user config so reinstalling does not rotate the token while the broker
    -- and agents are still running.
    token = readStoredToken()
    if not token then
      token = tostring(Uuid()) .. tostring(Uuid())
    end
    plugin.preferences.bridgeToken = token
  end
  bridgeToken = token
  if readStoredToken() ~= token then
    writeStoredToken(token)
  end
  return token
end

local function yamlString(value)
  return "'" .. value:gsub("'", "''") .. "'"
end

local function patternLiteral(value)
  return (value:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

local dshEntryIdPattern =
  "^id:%s*" .. patternLiteral(dshServerId) .. "%s*$"

local function isWindows()
  return package.config:sub(1, 1) == "\\"
end

local function findNodeExecutable()
  local executable = isWindows() and "node.exe" or "node"
  local separator = isWindows() and ";" or ":"
  local searchPath = os.getenv("PATH") or ""
  for directory in searchPath:gmatch("([^" .. separator .. "]+)") do
    directory = directory:gsub('^"(.*)"$', "%1")
    if directory ~= "" then
      local candidate = app.fs.joinPath(directory, executable)
      if app.fs.isFile(candidate) then
        return candidate
      end
    end
  end
  return "node"
end

local function dshHomeDirectory(plugin)
  local configured = plugin and plugin.preferences and plugin.preferences.dshHome
  if type(configured) == "string" and configured ~= "" then
    return configured
  end

  local fromEnvironment = os.getenv("DSH_HOME")
  if fromEnvironment and fromEnvironment ~= "" then
    return fromEnvironment
  end

  return app.fs.joinPath(userHomeDirectory(), ".dsh")
end

local function dshEntryIndent(line)
  local indent, rest = line:match("^(%s*)%-%s*(.*)$")
  if not indent then
    return nil
  end
  rest = rest:gsub("%s+#.*$", "")
  if rest:match(dshEntryIdPattern) then
    return #indent
  end
  return nil
end

local function isEmptyListLine(line)
  return line:gsub("%s+#.*$", ""):match("^%s*%[%]%s*$") ~= nil
end

-- Removes every previous Aseprite MCP entry from a Cordis patch file, then
-- appends one insert block describing the local MCP server.
local function applyDshRegistration(contents, block)
  contents = contents:gsub("^\239\187\191", "")

  local lines = {}
  for line in (contents .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line:gsub("\r$", "")
  end

  local kept = {}
  local index = 1
  while index <= #lines do
    local line = lines[index]
    if isEmptyListLine(line) then
      index = index + 1
    elseif line:sub(1, 1) ~= "-" then
      kept[#kept + 1] = line
      index = index + 1
    else
      local last = index
      while last + 1 <= #lines and lines[last + 1]:sub(1, 1) ~= "-" do
        last = last + 1
      end

      local entryStart = nil
      local entryIndent = nil
      for i = index, last do
        local indent = dshEntryIndent(lines[i])
        if indent ~= nil then
          entryStart = i
          entryIndent = indent
          break
        end
      end

      local entryEnd = nil
      if entryStart then
        entryEnd = entryStart
        while entryEnd + 1 <= last do
          local nextLine = lines[entryEnd + 1]
          if nextLine:match("^%s*$") then
            entryEnd = entryEnd + 1
          else
            local nextIndent = #(nextLine:match("^%s*") or "")
            if nextIndent > entryIndent then
              entryEnd = entryEnd + 1
            else
              break
            end
          end
        end
      end

      local chunk = {}
      for i = index, last do
        if not (entryStart and i >= entryStart and i <= entryEnd) then
          chunk[#chunk + 1] = lines[i]
        end
      end

      local hasEntries = false
      for i = 2, #chunk do
        if not chunk[i]:match("^%s*$") then
          hasEntries = true
          break
        end
      end
      local dropChunk = chunk[1] ~= nil and
        chunk[1]:match("^%-%s*insert:") ~= nil and
        not hasEntries
      if not dropChunk then
        for i = 1, #chunk do
          kept[#kept + 1] = chunk[i]
        end
      end

      index = last + 1
    end
  end

  local updated = table.concat(kept, "\n"):gsub("%s+$", "")
  if updated ~= "" then
    updated = updated .. "\n\n"
  end
  return updated .. block
end

local function buildDshPatchBlock(serverPath, token, command)
  return "- insert:\n" ..
    "    - id: " .. dshServerId .. "\n" ..
    "      name: " .. yamlString(dshMcpClientPackage) .. "\n" ..
    "      config:\n" ..
    "        serverName: " .. dshServerName .. "\n" ..
    "        transport: stdio\n" ..
    "        command: " .. yamlString(command) .. "\n" ..
    "        args:\n" ..
    "          - " .. yamlString(serverPath) .. "\n" ..
    "        env:\n" ..
    "          ASEPRITE_BRIDGE_TOKEN: " .. yamlString(token) .. "\n" ..
    "        toolCallTimeoutMs: 180000\n"
end

local function fileContains(path, needle)
  if not app.fs.isFile(path) then
    return false
  end
  local readOk, contents = pcall(readTextFile, path)
  if not readOk then
    return false
  end
  return contents:find(needle, 1, true) ~= nil
end

local function isCodexMcpSection(line)
  local header = line:match("^%s*(%[%[?.-%]%]?)")
  if not header then
    return false
  end

  return header == "[mcp_servers.codex-aseprite]" or
         header == "[[mcp_servers.codex-aseprite]]" or
         header:match("^%[mcp_servers%.codex%-aseprite%..-%]$") ~= nil or
         header:match("^%[%[mcp_servers%.codex%-aseprite%..-%]%]$") ~= nil
end

local function registerCodexMcp(plugin)
  local codexDirectory = app.fs.joinPath(userHomeDirectory(), ".codex")
  if not app.fs.makeAllDirectories(codexDirectory) then
    error("Could not create Codex configuration directory: " .. codexDirectory)
  end

  local configPath = app.fs.joinPath(codexDirectory, "config.toml")
  local serverPath = app.fs.joinPath(
    app.fs.joinPath(plugin.path, "mcp-bridge"),
    "server.mjs"
  )
  if not app.fs.isFile(serverPath) then
    error("MCP server is missing from the extension: " .. serverPath)
  end

  local token = ensureBridgeToken(plugin)

  local contents = ""
  if app.fs.isFile(configPath) then
    contents = readTextFile(configPath)
  end

  local keptLines = {}
  local skippingCodexSection = false
  for line in (contents .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", "")
    if line:match("^%s*%[") then
      if isCodexMcpSection(line) then
        skippingCodexSection = true
      else
        skippingCodexSection = false
        keptLines[#keptLines + 1] = line
      end
    elseif not skippingCodexSection then
      keptLines[#keptLines + 1] = line
    end
  end

  local updated = table.concat(keptLines, "\n"):gsub("\n+$", "")
  if updated ~= "" then
    updated = updated .. "\n\n"
  end
  updated = updated ..
    "[mcp_servers.codex-aseprite]\n" ..
    'command = "node"\n' ..
    "args = [" .. tomlString(serverPath) .. "]\n" ..
    "env = { ASEPRITE_BRIDGE_TOKEN = " .. tomlString(token) .. " }\n"

  if contents == updated then
    return configPath
  end

  writeTextFile(configPath, updated)
  return configPath
end

local function registerDshMcp(plugin)
  local dshHome = dshHomeDirectory(plugin)
  if not app.fs.isDirectory(dshHome) then
    error("DeepSeek Harness home not found: " .. dshHome ..
          ". Start DeepSeek Harness once, or set its home folder from the " ..
          "MCP Bridge menu.")
  end

  local patchPath = app.fs.joinPath(dshHome, "cordis.patch.yml")
  local serverPath = app.fs.joinPath(
    app.fs.joinPath(plugin.path, "mcp-bridge"),
    "server.mjs"
  )
  if not app.fs.isFile(serverPath) then
    error("MCP server is missing from the extension: " .. serverPath)
  end

  local token = ensureBridgeToken(plugin)
  local command = findNodeExecutable()
  local block = buildDshPatchBlock(serverPath, token, command)

  local contents = ""
  if app.fs.isFile(patchPath) then
    contents = readTextFile(patchPath)
  end

  local updated = applyDshRegistration(contents, block)
  if contents ~= updated then
    writeTextFile(patchPath, updated)
  end

  return patchPath
end

local function drawStroke(params)
  requireObject(params, "params")

  local sprite = app.activeSprite
  if not sprite then
    error("No sprite is currently open")
  end

  local points = params.points
  requireObject(points, "params.points")

  local pointCount = #points
  if pointCount < 1 or pointCount > maxStrokePoints then
    error("points must contain between 1 and " .. maxStrokePoints .. " items")
  end

  local tool = params.tool or "pencil"
  if type(tool) ~= "string" or tool == "" then
    error("tool must be a non-empty Aseprite tool id")
  end

  local frame = app.activeFrame and app.activeFrame.frameNumber or 1
  if params.frame ~= nil then
    frame = requireInteger(params.frame, "frame")
  end
  if frame < 1 or frame > #sprite.frames then
    error("frame is outside the sprite's frame range")
  end

  local layer = resolveLayerOrActive(sprite, params)
  if layer.isGroup then
    error("Cannot draw on a group layer: " .. layer.name)
  end

  local brushPoints = {}
  for i = 1, pointCount do
    local point = points[i]
    requireObject(point, "points[" .. i .. "]")

    local x = requireInteger(point.x, "points[" .. i .. "].x")
    local y = requireInteger(point.y, "points[" .. i .. "].y")
    if x < 0 or x >= sprite.width or y < 0 or y >= sprite.height then
      error("point " .. i .. " is outside the sprite canvas")
    end
    brushPoints[i] = Point(x, y)
  end

  local color = parseColor(params.color)
  app.transaction("MCP bridge: draw stroke", function()
    local options = {
      tool = tool,
      layer = layer,
      frame = frame,
      points = brushPoints
    }
    if color then
      options.color = color
    end
    app.useTool(options)
  end)
  app.refresh()

  return {
    points = pointCount,
    frame = frame,
    layer = layer.name,
    layerId = layer.id
  }
end

local function saveSprite(params)
  requireObject(params, "params")
  local sprite = app.activeSprite
  if not sprite then
    error("No sprite is currently open")
  end

  local filename = params.filename
  if filename ~= nil and (type(filename) ~= "string" or filename == "") then
    error("filename must be a non-empty path")
  end
  if filename == nil or filename == "" then
    filename = sprite.filename
  end
  if type(filename) ~= "string" or filename == "" then
    error("The sprite has no filename. Provide filename to save it for the first time.")
  end

  if not sprite:saveAs(filename) then
    error("Aseprite could not save the sprite to: " .. filename)
  end
  return { saved = true, filename = sprite.filename }
end

local function exportPreview(params)
  requireObject(params, "params")
  local sprite = requireSprite()

  local frame = app.activeFrame and app.activeFrame.frameNumber or 1
  if params.frame ~= nil then
    frame = requireInteger(params.frame, "frame")
    if frame < 1 or frame > #sprite.frames then
      error("frame is outside the sprite's frame range")
    end
  end

  local path = nextPreviewPath()
  local image = Image(sprite.spec)
  image:drawSprite(sprite, frame, Point(0, 0))
  if not saveImageForSprite(image, path, sprite) then
    error("Aseprite could not export a preview to: " .. path)
  end

  return {
    path = path,
    filename = sprite.filename,
    frame = frame,
    width = sprite.width,
    height = sprite.height,
    colorMode = colorModeName(sprite.colorMode),
    bytes = app.fs.fileSize(path)
  }
end

local function createSprite(params)
  requireObject(params, "params")
  local width = requireInteger(params.width, "width")
  local height = requireInteger(params.height, "height")
  if width < 1 or width > 16384 or height < 1 or height > 16384 then
    error("width and height must be between 1 and 16384")
  end
  local colorMode = parseColorMode(params.colorMode, "colorMode")

  local created = app.command.NewFile {
    ui = false,
    width = width,
    height = height,
    colorMode = colorMode
  }
  if not created then
    error("Aseprite could not create a new sprite")
  end
  local sprite = app.activeSprite
  if not sprite then
    error("Aseprite did not activate the new sprite")
  end
  app.refresh()
  return spriteSummary(sprite)
end

local function openSprite(params)
  requireObject(params, "params")
  if type(params.filename) ~= "string" or params.filename == "" then
    error("filename must be a non-empty path")
  end
  if not app.fs.isFile(params.filename) then
    error("File not found: " .. params.filename)
  end

  local sprite = app.open(params.filename)
  if not sprite then
    error("Aseprite could not open: " .. params.filename)
  end
  app.refresh()
  return spriteSummary(sprite)
end

local function listDocuments()
  local documents = {}
  local active = app.activeSprite
  for index, sprite in ipairs(app.sprites) do
    documents[index] = {
      index = index,
      filename = sprite.filename,
      width = sprite.width,
      height = sprite.height,
      frames = #sprite.frames,
      colorMode = colorModeName(sprite.colorMode),
      modified = sprite.isModified,
      active = (sprite == active)
    }
  end
  return { documents = documents, count = #documents }
end

local function findDocument(params)
  requireObject(params, "params")
  local sprites = app.sprites
  if params.index ~= nil then
    local index = requireInteger(params.index, "index")
    if index < 1 or index > #sprites then
      error("Document index is outside the open document range")
    end
    return sprites[index]
  end
  if type(params.filename) == "string" and params.filename ~= "" then
    for _, sprite in ipairs(sprites) do
      if sprite.filename == params.filename then
        return sprite
      end
    end
    error("Document not found: " .. params.filename)
  end
  error("Provide index or filename")
end

local function activateDocument(params)
  local sprite = findDocument(params)
  app.activeSprite = sprite
  app.refresh()
  return spriteSummary(sprite)
end

local function closeDocument(params)
  requireObject(params, "params")
  local sprite = findDocument(params)
  if sprite.isModified and params.force ~= true then
    error("Document has unsaved changes: " .. tostring(sprite.filename) ..
          ". Pass force=true to close it without saving.")
  end
  local filename = sprite.filename
  sprite:close()
  app.refresh()
  return { closed = true, filename = filename, remaining = #app.sprites }
end

local function resizeSprite(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local width = requireInteger(params.width, "width")
  local height = requireInteger(params.height, "height")
  if width < 1 or width > 16384 or height < 1 or height > 16384 then
    error("width and height must be between 1 and 16384")
  end
  sprite:resize { width = width, height = height }
  app.refresh()
  return { width = sprite.width, height = sprite.height }
end

local function redoSprite()
  requireSprite()
  app.redo()
  app.refresh()
  return { message = "redo requested" }
end

local function setFrameDuration(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local frame = app.activeFrame and app.activeFrame.frameNumber or 1
  if params.frame ~= nil then
    frame = requireInteger(params.frame, "frame")
    if frame < 1 or frame > #sprite.frames then
      error("frame is outside the sprite's frame range")
    end
  end
  local duration = requireInteger(params.durationMs, "durationMs")
  if duration < 1 or duration > 65535 then
    error("durationMs must be between 1 and 65535")
  end
  sprite.frames[frame].duration = duration / 1000
  return { frame = frame, durationMs = duration }
end

local function newTag(params)
  requireObject(params, "params")
  local sprite = requireSprite()

  local from = 1
  local to = #sprite.frames
  if params.from ~= nil then
    from = requireInteger(params.from, "from")
  end
  if params.to ~= nil then
    to = requireInteger(params.to, "to")
  end
  if from < 1 or from > #sprite.frames or to < 1 or to > #sprite.frames then
    error("from and to must be inside the sprite's frame range")
  end
  if to < from then
    error("to must be greater than or equal to from")
  end
  if params.name ~= nil and
     (type(params.name) ~= "string" or params.name == "") then
    error("name must be a non-empty string")
  end

  local tag = sprite:newTag(from, to)
  if params.name then
    tag.name = params.name
  end
  local direction = parseAniDir(params.aniDir)
  if direction ~= nil then
    tag.aniDir = direction
  end
  if params.repeats ~= nil then
    local repeats = requireInteger(params.repeats, "repeats")
    if repeats < 0 then
      error("repeats must be greater than or equal to 0")
    end
    tag.repeats = repeats
  end
  return tagInfo(tag)
end

local function duplicateLayer(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local layer = resolveLayerOrActive(sprite, params)
  if layer.isGroup then
    error("Cannot duplicate a group layer: " .. layer.name)
  end
  app.activeLayer = layer

  local before = countLayers(sprite.layers)
  if not app.command.DuplicateLayer {} then
    error("Aseprite could not duplicate the layer")
  end
  local duplicate = app.activeLayer
  if not duplicate or countLayers(sprite.layers) <= before then
    error("Aseprite did not duplicate the layer")
  end
  app.refresh()
  return {
    layer = duplicate.name,
    layerId = duplicate.id,
    source = layer.name,
    layers = countLayers(sprite.layers)
  }
end

local function mergeDownLayer(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local layer = resolveLayerOrActive(sprite, params)
  if layer.isBackground then
    error("Cannot merge a background layer down: " .. layer.name)
  end

  local mergedName = layer.name
  app.activeLayer = layer
  if not app.command.MergeDownLayer {} then
    error("Aseprite could not merge the layer down; it may be the bottom layer or a group")
  end
  app.refresh()
  return {
    merged = mergedName,
    layers = countLayers(sprite.layers),
    activeLayer = app.activeLayer and app.activeLayer.name or nil
  }
end

local function flattenSprite(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  if not app.command.FlattenLayers {} then
    error("Aseprite could not flatten the sprite")
  end
  app.refresh()
  return { layers = countLayers(sprite.layers) }
end

local function frameParam(sprite, params)
  local frame = app.activeFrame and app.activeFrame.frameNumber or 1
  if params.frame ~= nil then
    frame = requireInteger(params.frame, "frame")
    if frame < 1 or frame > #sprite.frames then
      error("frame is outside the sprite's frame range")
    end
  end
  return frame
end

local function sampleColor(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local x = requireInteger(params.x, "x")
  local y = requireInteger(params.y, "y")
  if x < 0 or x >= sprite.width or y < 0 or y >= sprite.height then
    error("point is outside the sprite canvas")
  end
  local frame = frameParam(sprite, params)

  local image = renderFrameToRgb(sprite, frame)
  return {
    x = x,
    y = y,
    frame = frame,
    color = pixelToHex(image:getPixel(x, y))
  }
end

local maxReadPixels = 4096

local function readPixels(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local x = requireInteger(params.x, "x")
  local y = requireInteger(params.y, "y")
  local width = requireInteger(params.width, "width")
  local height = requireInteger(params.height, "height")
  if width < 1 or height < 1 then
    error("width and height must be at least 1")
  end
  if x < 0 or y < 0 or x + width > sprite.width or y + height > sprite.height then
    error("region is outside the sprite canvas")
  end
  if width * height > maxReadPixels then
    error("region is too large; read at most " .. maxReadPixels .. " pixels")
  end
  local frame = frameParam(sprite, params)

  local image = renderFrameToRgb(sprite, frame)
  local rows = {}
  for row = 0, height - 1 do
    local colors = {}
    for column = 0, width - 1 do
      colors[column + 1] = pixelToHex(image:getPixel(x + column, y + row))
    end
    rows[row + 1] = colors
  end
  return {
    x = x,
    y = y,
    width = width,
    height = height,
    frame = frame,
    rows = rows
  }
end

local function celBounds(cel)
  local bounds = cel.bounds
  return {
    x = bounds.x,
    y = bounds.y,
    width = bounds.width,
    height = bounds.height
  }
end

-- Places an image file on a layer as its cel for one frame. Use newLayer to
-- add a dedicated layer; the target layer's existing cel on that frame is
-- replaced, so artwork prepared outside Aseprite can be iterated quickly.
local function stampImage(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  if type(params.filename) ~= "string" or params.filename == "" then
    error("filename must be a non-empty path")
  end
  if not app.fs.isFile(params.filename) then
    error("File not found: " .. params.filename)
  end
  local image = Image { fromFile = params.filename }
  if not image then
    error("Could not load image: " .. params.filename)
  end

  local frame = frameParam(sprite, params)

  local layer
  if params.newLayer ~= nil then
    if type(params.newLayer) ~= "string" or params.newLayer == "" then
      error("newLayer must be a non-empty name")
    end
    layer = sprite:newLayer()
    layer.name = params.newLayer
  elseif params.layer ~= nil or params.layerId ~= nil then
    layer = findLayerByParams(sprite, params)
  else
    error("Provide layer, layerId, or newLayer")
  end
  if not layer.isImage and not layer.isTilemap then
    error("Cannot stamp an image onto a group layer: " .. layer.name)
  end

  local x = 0
  local y = 0
  if params.x ~= nil then
    x = requireInteger(params.x, "x")
  end
  if params.y ~= nil then
    y = requireInteger(params.y, "y")
  end

  local cel = sprite:newCel(layer, frame, image, Point(x, y))
  if not cel then
    error("Aseprite could not stamp the image")
  end
  app.activeLayer = layer
  app.refresh()
  return {
    layer = layer.name,
    layerId = layer.id,
    frame = frame,
    x = x,
    y = y,
    width = image.width,
    height = image.height,
    bounds = celBounds(cel)
  }
end

local function findTag(sprite, name)
  for i = 1, #sprite.tags do
    local tag = sprite.tags[i]
    if tag.name == name then
      return tag
    end
  end
  return nil
end

local function newCel(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local layer = resolveLayerOrActive(sprite, params)
  if not layer.isImage and not layer.isTilemap then
    error("Cannot create a cel on a group layer: " .. layer.name)
  end
  local frame = frameParam(sprite, params)

  local sourceFrame = nil
  if params.copyFromFrame ~= nil then
    sourceFrame = requireInteger(params.copyFromFrame, "copyFromFrame")
    if sourceFrame < 1 or sourceFrame > #sprite.frames then
      error("copyFromFrame is outside the sprite's frame range")
    end
  end

  local cel
  if sourceFrame then
    local sourceCel = layer:cel(sourceFrame)
    if not sourceCel then
      error("No cel on layer '" .. layer.name .. "' at frame " .. sourceFrame)
    end
    cel = sprite:newCel(layer, frame, sourceCel.image, sourceCel.position)
  else
    cel = sprite:newCel(layer, frame)
  end
  if not cel then
    error("Aseprite could not create a cel")
  end
  app.refresh()
  return {
    layer = layer.name,
    layerId = layer.id,
    frame = frame,
    sourceFrame = sourceFrame,
    bounds = celBounds(cel),
    opacity = cel.opacity
  }
end

local function deleteCel(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local layer = resolveLayerOrActive(sprite, params)
  if not layer.isImage and not layer.isTilemap then
    error("Group layers do not hold cels: " .. layer.name)
  end
  local frame = frameParam(sprite, params)
  if not layer:cel(frame) then
    error("No cel on layer '" .. layer.name .. "' at frame " .. frame)
  end
  sprite:deleteCel(layer, frame)
  app.refresh()
  return {
    deleted = true,
    layer = layer.name,
    layerId = layer.id,
    frame = frame
  }
end

local function listCels(params)
  requireObject(params, "params")
  local sprite = requireSprite()

  local function describeLayerFrame(layer, frame)
    local cel = layer:cel(frame)
    local entry = {
      layer = layer.name,
      layerId = layer.id,
      hasCel = cel ~= nil
    }
    if cel then
      entry.bounds = celBounds(cel)
      entry.opacity = cel.opacity
    end
    return entry
  end

  local function celLayers(frame)
    local entries = {}
    for _, layer in ipairs(allLayers(sprite)) do
      if layer.isImage or layer.isTilemap then
        entries[#entries + 1] = describeLayerFrame(layer, frame)
      end
    end
    return entries
  end

  if params.allFrames == true then
    local frames = {}
    for frame = 1, #sprite.frames do
      local layers = celLayers(frame)
      local count = 0
      for _, entry in ipairs(layers) do
        if entry.hasCel then
          count = count + 1
        end
      end
      frames[frame] = {
        frame = frame,
        durationMs = math.floor(sprite.frames[frame].duration * 1000 + 0.5),
        cels = count,
        layers = layers
      }
    end
    return { frames = frames, frameCount = #sprite.frames }
  end

  local frame = frameParam(sprite, params)
  return { frame = frame, layers = celLayers(frame) }
end

local function duplicateFrame(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local frame = frameParam(sprite, params)
  local before = #sprite.frames

  sprite:newFrame(frame)
  if #sprite.frames ~= before + 1 then
    error("Aseprite did not duplicate the frame")
  end

  local newFrame = frame + 1
  app.activeFrame = newFrame
  app.refresh()
  return {
    frame = newFrame,
    source = frame,
    frames = #sprite.frames
  }
end

local function deleteTag(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  if type(params.name) ~= "string" or params.name == "" then
    error("name must be a non-empty string")
  end
  if not findTag(sprite, params.name) then
    error("Tag not found: " .. params.name)
  end
  sprite:deleteTag(params.name)
  app.refresh()
  return { deleted = params.name, tags = #sprite.tags }
end

local function editTag(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  if type(params.name) ~= "string" or params.name == "" then
    error("name must be a non-empty string")
  end
  if params.newName == nil and params.from == nil and params.to == nil and
     params.aniDir == nil and params.repeats == nil then
    error("provide at least one tag property to change")
  end
  local tag = findTag(sprite, params.name)
  if not tag then
    error("Tag not found: " .. params.name)
  end

  local from = tag.fromFrame.frameNumber
  local to = tag.toFrame.frameNumber
  if params.from ~= nil then
    from = requireInteger(params.from, "from")
  end
  if params.to ~= nil then
    to = requireInteger(params.to, "to")
  end
  if from < 1 or from > #sprite.frames or to < 1 or to > #sprite.frames then
    error("from and to must be inside the sprite's frame range")
  end
  if to < from then
    error("to must be greater than or equal to from")
  end
  if params.newName ~= nil and
     (type(params.newName) ~= "string" or params.newName == "") then
    error("newName must be a non-empty string")
  end
  if params.repeats ~= nil then
    params.repeats = requireInteger(params.repeats, "repeats")
    if params.repeats < 0 then
      error("repeats must be greater than or equal to 0")
    end
  end

  if params.newName ~= nil then
    tag.name = params.newName
  end
  tag.fromFrame = from
  tag.toFrame = to
  if params.aniDir ~= nil then
    tag.aniDir = parseAniDir(params.aniDir)
  end
  if params.repeats ~= nil then
    tag.repeats = params.repeats
  end
  app.refresh()
  return tagInfo(tag)
end

local function exportAnimation(params)
  requireObject(params, "params")
  local sprite = requireSprite()
  local format = params.format or "gif"
  if format ~= "gif" and format ~= "png_sequence" and format ~= "sheet" then
    error("format must be gif, png_sequence, or sheet")
  end

  if format == "gif" then
    -- Saving a GIF directly from a GUI script deadlocks Aseprite's save job
    -- (the same call works in --batch mode), so export through a temporary
    -- .aseprite copy and let Aseprite's own CLI encode the GIF.
    local sourcePath = nextOutputPath("animation-source", "aseprite")
    if not sprite:saveCopyAs(sourcePath) then
      error("Aseprite could not prepare the animation for GIF export")
    end

    local path = nextOutputPath("animation", "gif")
    local appPath = app.fs.appPath
    if not appPath or appPath == "" then
      error("Could not locate the Aseprite executable for GIF export")
    end

    -- Windows needs cmd's outer-quote form because system() passes the line to
    -- `cmd /c`; a plain leading quote is stripped and the path is rejected.
    local command
    if isWindows() then
      command = string.format('cmd /c ""%s" -b "%s" --save-as "%s""',
                              appPath, sourcePath, path)
    else
      command = string.format('"%s" -b "%s" --save-as "%s"',
                              appPath, sourcePath, path)
    end
    os.execute(command)

    local bytes = app.fs.fileSize(path)
    if not app.fs.isFile(path) or type(bytes) ~= "number" or bytes <= 0 then
      error("Aseprite could not encode an animated GIF from: " .. sourcePath)
    end
    return {
      format = "gif",
      path = path,
      source = sourcePath,
      frames = #sprite.frames,
      width = sprite.width,
      height = sprite.height,
      bytes = bytes
    }
  end

  if format == "png_sequence" then
    local paths = {}
    for frame = 1, #sprite.frames do
      local image = Image(sprite.spec)
      image:drawSprite(sprite, frame, Point(0, 0))
      local path = nextOutputPath(string.format("frame-%03d", frame), "png")
      if not saveImageForSprite(image, path, sprite) then
        error("Aseprite could not export frame " .. frame .. " to: " .. path)
      end
      paths[#paths + 1] = path
    end
    return {
      format = "png_sequence",
      paths = paths,
      frames = #sprite.frames,
      width = sprite.width,
      height = sprite.height
    }
  end

  local frames = #sprite.frames
  local image = Image {
    width = sprite.width * frames,
    height = sprite.height,
    colorMode = sprite.colorMode
  }
  for frame = 1, frames do
    image:drawSprite(sprite, frame, Point((frame - 1) * sprite.width, 0))
  end
  local path = nextOutputPath("sheet", "png")
  if not saveImageForSprite(image, path, sprite) then
    error("Aseprite could not export a sprite sheet to: " .. path)
  end
  return {
    format = "sheet",
    path = path,
    frames = frames,
    width = image.width,
    height = image.height,
    bytes = app.fs.fileSize(path)
  }
end

local function dispatch(request)
  requireObject(request, "request")

  if not constantTimeEquals(request.token, bridgeToken) then
    error("Unauthorized bridge request")
  end

  local method = request.method
  local params = request.params

  if method == "ping" then
    return { message = "pong" }
  elseif method == "get_connection_status" then
    return {
      state = connectionState,
      websocketUrl = websocketUrl
    }
  elseif method == "get_active_sprite" then
    return getActiveSpriteInfo()
  elseif method == "list_layers" then
    return listLayers()
  elseif method == "export_preview" then
    return exportPreview(params)
  elseif method == "export_animation" then
    return exportAnimation(params)
  elseif method == "create_sprite" then
    return createSprite(params)
  elseif method == "open_sprite" then
    return openSprite(params)
  elseif method == "list_documents" then
    return listDocuments()
  elseif method == "activate_document" then
    return activateDocument(params)
  elseif method == "close_document" then
    return closeDocument(params)
  elseif method == "resize_sprite" then
    return resizeSprite(params)
  elseif method == "set_active_tool" then
    return setActiveTool(params)
  elseif method == "set_active_layer" then
    return setActiveLayer(params)
  elseif method == "set_active_frame" then
    return setActiveFrame(params)
  elseif method == "new_layer" then
    return createLayer(params, false)
  elseif method == "new_group" then
    return createLayer(params, true)
  elseif method == "add_frame" then
    return addFrame(params)
  elseif method == "duplicate_frame" then
    return duplicateFrame(params)
  elseif method == "delete_frame" then
    return deleteFrame(params)
  elseif method == "new_cel" then
    return newCel(params)
  elseif method == "stamp_image" then
    return stampImage(params)
  elseif method == "delete_cel" then
    return deleteCel(params)
  elseif method == "list_cels" then
    return listCels(params)
  elseif method == "delete_layer" then
    return deleteLayer(params)
  elseif method == "duplicate_layer" then
    return duplicateLayer(params)
  elseif method == "merge_down_layer" then
    return mergeDownLayer(params)
  elseif method == "flatten_sprite" then
    return flattenSprite(params)
  elseif method == "set_colors" then
    return setColors(params)
  elseif method == "set_layer_properties" then
    return setLayerProperties(params)
  elseif method == "draw_stroke" then
    return drawStroke(params)
  elseif method == "sample_color" then
    return sampleColor(params)
  elseif method == "read_pixels" then
    return readPixels(params)
  elseif method == "set_frame_duration" then
    return setFrameDuration(params)
  elseif method == "new_tag" then
    return newTag(params)
  elseif method == "edit_tag" then
    return editTag(params)
  elseif method == "delete_tag" then
    return deleteTag(params)
  elseif method == "save_sprite" then
    return saveSprite(params)
  elseif method == "undo" then
    requireSprite()
    app.undo()
    app.refresh()
    return { message = "undo requested" }
  elseif method == "redo" then
    return redoSprite()
  end

  error("Unknown method: " .. tostring(method))
end

local function startConnection()
  if type(bridgeToken) ~= "string" or #bridgeToken < 32 then
    alertLines {
      "The MCP bridge has not been registered yet.",
      "Re-enable the extension, then use",
      "File > Scripts > MCP Bridge > Register with Codex or DeepSeek Harness."
    }
    return
  end

  if connection then
    connection:close()
    connection = nil
  end

  connectionState = "connecting"
  local socket
  socket = WebSocket {
    url = websocketUrl,
    onreceive = function(messageType, data, messageError)
      if messageType == WebSocketMessageType.OPEN then
        connectionState = "connected"
        print("Aseprite MCP: connected to " .. websocketUrl)
        return
      end

      if messageType == WebSocketMessageType.CLOSE then
        if connection == socket then
          connection = nil
          connectionState = "disconnected"
        end
        return
      end

      if messageType == WebSocketMessageType.ERROR then
        connectionState = "error"
        print("Aseprite MCP: WebSocket error: " .. tostring(messageError))
        return
      end

      if messageType ~= WebSocketMessageType.TEXT then
        return
      end

      local decodeOk, request = pcall(json.decode, data)
      if not decodeOk then
        sendResponse(socket, {
          id = "",
          ok = false,
          error = "Invalid JSON request: " .. tostring(request)
        })
        return
      end

      local requestId = ""
      if type(request) == "userdata" and
         (type(request.id) == "string" or type(request.id) == "number") then
        requestId = tostring(request.id)
      end

      if requestId == "" then
        sendResponse(socket, {
          id = "",
          ok = false,
          error = "Request id is required"
        })
        return
      end

      local dispatchOk, result = pcall(dispatch, request)
      if dispatchOk then
        sendResponse(socket, {
          id = requestId,
          ok = true,
          result = result
        })
      else
        sendResponse(socket, {
          id = requestId,
          ok = false,
          error = tostring(result)
        })
      end
    end
  }

  connection = socket
  socket:connect()
end

local function stopConnection()
  if connection then
    local socket = connection
    connection = nil
    connectionState = "disconnected"
    socket:close()
  end
end

local function showStatus(plugin)
  local lines = {
    "Aseprite MCP bridge: " .. connectionState,
    "WebSocket: " .. websocketUrl
  }

  local homeOk, home = pcall(userHomeDirectory)
  if homeOk then
    local codexPath = app.fs.joinPath(app.fs.joinPath(home, ".codex"), "config.toml")
    local state = "not registered"
    if fileContains(codexPath, "[mcp_servers.codex-aseprite]") then
      state = "registered"
    end
    lines[#lines + 1] = "Codex: " .. codexPath .. " (" .. state .. ")"
  end

  local dshHomeOk, dshHome = pcall(dshHomeDirectory, plugin)
  if dshHomeOk then
    local patchPath = app.fs.joinPath(dshHome, "cordis.patch.yml")
    local state = "not registered"
    if fileContains(patchPath, "id: " .. dshServerId) then
      state = "registered"
    end
    lines[#lines + 1] = "DeepSeek Harness: " .. patchPath .. " (" .. state .. ")"
  end

  alertLines(lines)
end

local function setDshHome(plugin)
  local current = plugin.preferences.dshHome
  if type(current) ~= "string" or current == "" then
    local ok, detected = pcall(dshHomeDirectory, plugin)
    current = ok and detected or ""
  end

  local dialogOk, dialog = pcall(function()
    local dlg = Dialog { title = "DeepSeek Harness home folder" }
    dlg:entry { id = "home", label = "DSH home:", text = current, focus = true }
    dlg:button { id = "ok", text = "Save" }
    dlg:button { id = "cancel", text = "Cancel" }
    dlg:show()
    return dlg
  end)
  if not dialogOk then
    alertLines { "Could not open the DSH home dialog.", tostring(dialog) }
    return
  end

  local data = dialog.data
  if not data or not data.ok then
    return
  end
  if type(data.home) ~= "string" or data.home == "" then
    app.alert("The DeepSeek Harness home folder cannot be empty.")
    return
  end

  plugin.preferences.dshHome = data.home
  local ok, result = pcall(registerDshMcp, plugin)
  if ok then
    alertLines {
      "DeepSeek Harness MCP server registered.",
      tostring(result),
      "Restart DeepSeek Harness if the Aseprite tools do not appear."
    }
  else
    alertLines {
      "Could not register DeepSeek Harness MCP server.",
      tostring(result)
    }
  end
end

local function configureImageApi(plugin)
  local existing = readImageApiConfig(plugin)
  local baseUrl = "https://api.openai.com/v1"
  local apiKey = ""
  local model = "gpt-image-1"
  local size = "1024x1024"
  if existing then
    local ok, value = pcall(function() return existing.baseUrl end)
    if ok and type(value) == "string" and value ~= "" then baseUrl = value end
    ok, value = pcall(function() return existing.apiKey end)
    if ok and type(value) == "string" then apiKey = value end
    ok, value = pcall(function() return existing.model end)
    if ok and type(value) == "string" and value ~= "" then model = value end
    ok, value = pcall(function() return existing.size end)
    if ok and type(value) == "string" and value ~= "" then size = value end
  end

  local dialogOk, dialog = pcall(function()
    local dlg = Dialog { title = "Image API (OpenAI compatible)" }
    dlg:entry { id = "baseUrl", label = "Base URL:", text = baseUrl }
    dlg:entry { id = "apiKey", label = "API key:", text = apiKey }
    dlg:entry { id = "model", label = "Model:", text = model }
    dlg:entry { id = "size", label = "Size:", text = size }
    dlg:button { id = "ok", text = "Save" }
    dlg:button { id = "cancel", text = "Cancel" }
    dlg:show()
    return dlg
  end)
  if not dialogOk then
    alertLines { "Could not open the image API dialog.", tostring(dialog) }
    return
  end

  local data = dialog.data
  if not data or not data.ok then
    return
  end

  local newBase = tostring(data.baseUrl or ""):gsub("%s+$", "")
  local newKey = tostring(data.apiKey or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local newModel = tostring(data.model or ""):gsub("%s+$", "")
  local newSize = tostring(data.size or ""):gsub("%s+$", "")

  if not newBase:match("^https?://") then
    app.alert("Base URL must start with http:// or https://")
    return
  end
  if newKey == "" then
    app.alert("API key cannot be empty.")
    return
  end
  if newModel == "" then
    app.alert("Model cannot be empty.")
    return
  end

  local saveOk, saveError = pcall(writeImageApiConfig, plugin,
    newBase, newKey, newModel, newSize)
  if saveOk then
    app.alert("Image API configuration saved.\n" ..
              "The generate_image tool uses it immediately.")
  else
    app.alert("Could not save the image API configuration:\n" ..
              tostring(saveError))
  end
end

function init(plugin)
  plugin.preferences = plugin.preferences or {}
  bridgeToken = plugin.preferences.bridgeToken

  plugin:newMenuGroup {
    id = "codex-aseprite",
    title = "MCP Bridge",
    group = "file_scripts"
  }

  plugin:newCommand {
    id = "codex-aseprite-start",
    title = "Connect to local bridge",
    group = "codex-aseprite",
    onclick = startConnection
  }

  plugin:newCommand {
    id = "codex-aseprite-stop",
    title = "Disconnect",
    group = "codex-aseprite",
    onclick = stopConnection
  }

  plugin:newCommand {
    id = "codex-aseprite-status",
    title = "Connection status",
    group = "codex-aseprite",
    onclick = function() showStatus(plugin) end
  }

  plugin:newCommand {
    id = "codex-aseprite-register-codex",
    title = "Register with Codex",
    group = "codex-aseprite",
    onclick = function()
      local ok, result = pcall(registerCodexMcp, plugin)
      if ok then
        alertLines {
          "Codex MCP server registered.",
          tostring(result),
          "Restart Codex to load it."
        }
      else
        alertLines {
          "Could not register Codex MCP server.",
          tostring(result)
        }
      end
    end
  }

  plugin:newCommand {
    id = "codex-aseprite-register-dsh",
    title = "Register with DeepSeek Harness",
    group = "codex-aseprite",
    onclick = function()
      local ok, result = pcall(registerDshMcp, plugin)
      if ok then
        alertLines {
          "DeepSeek Harness MCP server registered.",
          tostring(result),
          "Restart DeepSeek Harness if the Aseprite tools do not appear."
        }
      else
        alertLines {
          "Could not register DeepSeek Harness MCP server.",
          tostring(result)
        }
      end
    end
  }

  plugin:newCommand {
    id = "codex-aseprite-set-dsh-home",
    title = "Set DeepSeek Harness home...",
    group = "codex-aseprite",
    onclick = function() setDshHome(plugin) end
  }

  plugin:newCommand {
    id = "codex-aseprite-image-api",
    title = "Configure image API...",
    group = "codex-aseprite",
    onclick = function() configureImageApi(plugin) end
  }

  local registered = {}
  local failures = {}

  local codexOk, codexResult = pcall(registerCodexMcp, plugin)
  if codexOk then
    registered[#registered + 1] = "Codex"
    print("Aseprite MCP: Codex config updated at " .. tostring(codexResult))
  else
    failures[#failures + 1] = "Codex: " .. tostring(codexResult)
    print("Aseprite MCP: Codex registration failed: " .. tostring(codexResult))
  end

  local dshHomeOk, dshHome = pcall(dshHomeDirectory, plugin)
  if dshHomeOk and app.fs.isDirectory(dshHome) then
    local dshOk, dshResult = pcall(registerDshMcp, plugin)
    if dshOk then
      registered[#registered + 1] = "DeepSeek Harness"
      print("Aseprite MCP: DeepSeek Harness config updated at " .. tostring(dshResult))
    else
      failures[#failures + 1] = "DeepSeek Harness: " .. tostring(dshResult)
      print("Aseprite MCP: DeepSeek Harness registration failed: " ..
            tostring(dshResult))
    end
  end

  if #failures > 0 then
    local message = { "Could not register the Aseprite MCP server automatically." }
    for _, failure in ipairs(failures) do
      message[#message + 1] = failure
    end
    alertLines(message)
  elseif #registered > 0 then
    app.tip("Aseprite MCP registered for " .. table.concat(registered, " and ") ..
            ". Restart the agent to load it.")
  end
end

function exit(plugin)
  stopConnection()
end
