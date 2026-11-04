import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import WebSocket from "ws";
import { z } from "zod";

const host = "127.0.0.1";
const port = Number(process.env.ASEPRITE_MCP_BROKER_PORT ?? 8766);
const requestTimeoutMs = 60000;
const maxPayloadBytes = 1024 * 1024;
const bridgeToken = process.env.ASEPRITE_BRIDGE_TOKEN;

if (!bridgeToken || bridgeToken.length < 32) {
  throw new Error("Set ASEPRITE_BRIDGE_TOKEN to a secret of at least 32 characters.");
}

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("ASEPRITE_MCP_BROKER_PORT must be a valid TCP port.");
}

let brokerSocket = null;
const pendingRequests = new Map();

function rejectPendingRequests(reason) {
  for (const [id, pending] of pendingRequests) {
    clearTimeout(pending.timeout);
    pendingRequests.delete(id);
    pending.reject(new Error(reason));
  }
}

function connectToBroker() {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(`ws://${host}:${port}`, {
      maxPayload: maxPayloadBytes,
      perMessageDeflate: false
    });
    let authenticated = false;

    const failBeforeAuth = (error) => {
      if (authenticated) {
        return;
      }
      socket.close();
      reject(error);
    };

    socket.on("open", () => {
      socket.send(JSON.stringify({
        type: "authenticate",
        token: bridgeToken
      }));
    });

    socket.on("message", (data, isBinary) => {
      if (isBinary) {
        socket.close(1003, "Text messages only");
        return;
      }
      let response;
      try {
        response = JSON.parse(data.toString());
      } catch {
        socket.close(1007, "Invalid JSON");
        return;
      }

      if (!authenticated) {
        if (response?.type !== "authenticated") {
          failBeforeAuth(new Error("MCP broker authentication failed."));
          return;
        }
        authenticated = true;
        brokerSocket = socket;
        resolve();
        process.stderr.write("Aseprite MCP: connected to shared broker.\n");
        return;
      }

      if (!response || typeof response.id !== "string") {
        return;
      }
      const pending = pendingRequests.get(response.id);
      if (!pending) {
        return;
      }
      clearTimeout(pending.timeout);
      pendingRequests.delete(response.id);

      if (response.ok === true) {
        if (!response.result || typeof response.result !== "object" ||
            Array.isArray(response.result)) {
          pending.reject(new Error("Aseprite returned an invalid result."));
        } else {
          pending.resolve(response.result);
        }
      } else {
        pending.reject(new Error(
          typeof response.error === "string" ? response.error : "Aseprite operation failed."
        ));
      }
    });

    socket.on("error", (error) => {
      if (!authenticated) {
        failBeforeAuth(error);
      } else {
        process.stderr.write(`Aseprite MCP broker error: ${error.message}\n`);
      }
    });

    socket.on("close", () => {
      if (!authenticated) {
        failBeforeAuth(new Error("MCP broker closed the connection during startup."));
      }
      if (brokerSocket !== socket) {
        return;
      }
      brokerSocket = null;
      rejectPendingRequests("MCP broker disconnected before replying.");
      process.stderr.write("Aseprite MCP: shared broker disconnected.\n");
    });
  });
}

function startBrokerProcess() {
  const brokerPath = fileURLToPath(new URL("./broker.mjs", import.meta.url));
  const child = spawn(process.execPath, [brokerPath], {
    cwd: fileURLToPath(new URL(".", import.meta.url)),
    detached: true,
    stdio: "ignore",
    windowsHide: true,
    env: process.env
  });
  child.once("error", (error) => {
    process.stderr.write(`Could not start shared MCP broker: ${error.message}\n`);
  });
  child.unref();
}

async function connectOrStartBroker() {
  const deadline = Date.now() + 10000;
  let brokerStarted = false;
  let lastError;
  while (Date.now() < deadline) {
    try {
      await connectToBroker();
      return;
    } catch (error) {
      lastError = error;
      if (!brokerStarted) {
        startBrokerProcess();
        brokerStarted = true;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
  throw new Error(`Could not connect to shared MCP broker: ${String(lastError)}`);
}

function callAseprite(method, params = {}) {
  const socket = brokerSocket;
  if (!socket || socket.readyState !== WebSocket.OPEN) {
    throw new Error(
      "The shared MCP broker is not connected. Restart the MCP server, then use " +
      "File > Scripts > MCP Bridge > Connect to local bridge."
    );
  }

  const id = randomUUID();
  const message = JSON.stringify({ type: "request", id, method, params });

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pendingRequests.delete(id);
      reject(new Error(`Aseprite timed out while handling '${method}'.`));
    }, requestTimeoutMs);
    pendingRequests.set(id, { resolve, reject, timeout });
    const handleSendError = (error) => {
      clearTimeout(timeout);
      pendingRequests.delete(id);
      reject(new Error(`Could not send request to Aseprite: ${error.message}`));
    };
    try {
      socket.send(message, (error) => {
        if (error) {
          handleSendError(error);
        }
      });
    } catch (error) {
      handleSendError(error);
    }
  });
}

const server = new McpServer({
  name: "aseprite",
  version: "0.7.1"
});

function registerTool(name, description, inputSchema, method, getParams) {
  server.registerTool(name, { description, inputSchema }, async (input) => {
    try {
      const result = await callAseprite(method, getParams(input));//MCP 工具处理器调用 callAseprite()，把 MCP 请求转发出去
      return {
        content: [{ type: "text", text: JSON.stringify(result) }]
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        content: [{ type: "text", text: message }],
        isError: true
      };
    }
  });
}

function registerLocalTool(name, description, inputSchema, handler) {
  server.registerTool(name, { description, inputSchema }, async (input) => {
    try {
      const result = await handler(input ?? {});
      return {
        content: [{ type: "text", text: JSON.stringify(result) }]
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        content: [{ type: "text", text: message }],
        isError: true
      };
    }
  });
}

const IMAGE_CONFIG_FILENAME = "image-api.json";

function imageConfigCandidates() {
  const here = dirname(fileURLToPath(import.meta.url));
  const candidates = [resolve(here, "..", IMAGE_CONFIG_FILENAME)];
  if (process.env.APPDATA) {
    candidates.push(join(process.env.APPDATA, "Aseprite",
      "codex-aseprite-image.json"));
  }
  if (process.env.HOME) {
    candidates.push(join(process.env.HOME, "Library", "Application Support",
      "Aseprite", "codex-aseprite-image.json"));
    candidates.push(join(process.env.HOME, ".config", "Aseprite",
      "codex-aseprite-image.json"));
    candidates.push(join(process.env.HOME, ".config", "aseprite",
      "codex-aseprite-image.json"));
  }
  return candidates;
}

function readImageApiConfig() {
  for (const file of imageConfigCandidates()) {
    if (!existsSync(file)) {
      continue;
    }
    try {
      return { file, config: JSON.parse(readFileSync(file, "utf8")) };
    } catch {
      // Ignore malformed candidates and try the next location.
    }
  }
  return null;
}

function requireImageApiConfig() {
  const found = readImageApiConfig();
  if (!found) {
    throw new Error(
      "Image API is not configured. In Aseprite use File > Scripts > MCP Bridge > Configure image API..."
    );
  }
  const config = found.config ?? {};
  if (typeof config.baseUrl !== "string" ||
      !/^https?:\/\//i.test(config.baseUrl)) {
    throw new Error("Image API baseUrl must be an http(s) URL. Re-run Configure image API...");
  }
  if (typeof config.apiKey !== "string" || config.apiKey.length < 1) {
    throw new Error("Image API key is missing. Re-run Configure image API...");
  }
  if (typeof config.model !== "string" || config.model.length < 1) {
    throw new Error("Image API model is missing. Re-run Configure image API...");
  }
  return config;
}

function imageApiEndpoint(baseUrl, pathname) {
  return `${String(baseUrl).replace(/\/+$/, "")}${pathname}`;
}

function imageMime(file) {
  const lower = String(file).toLowerCase();
  if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) {
    return "image/jpeg";
  }
  if (lower.endsWith(".webp")) {
    return "image/webp";
  }
  return "image/png";
}

function uploadPart(file) {
  if (typeof file !== "string" || !existsSync(file)) {
    throw new Error(`Reference image not found: ${file}`);
  }
  return new Blob([readFileSync(file)], { type: imageMime(file) });
}

function imageDataUrl(file) {
  if (typeof file !== "string" || !existsSync(file)) {
    throw new Error(`Reference image not found: ${file}`);
  }
  return `data:${imageMime(file)};base64,${readFileSync(file).toString("base64")}`;
}

function imageExtension(buffer) {
  if (buffer.length >= 8 && buffer[0] === 0x89 && buffer[1] === 0x50 &&
      buffer[2] === 0x4e && buffer[3] === 0x47) {
    return "png";
  }
  if (buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 &&
      buffer[2] === 0xff) {
    return "jpg";
  }
  if (buffer.length >= 12 && buffer.toString("ascii", 0, 4) === "RIFF" &&
      buffer.toString("ascii", 8, 12) === "WEBP") {
    return "webp";
  }
  return "png";
}

async function generateImage(input) {
  const config = requireImageApiConfig();
  const prompt = String(input.prompt ?? "").trim();
  if (!prompt) {
    throw new Error("prompt is required.");
  }
  const referenceImage = input.referenceImage;
  const useEdit = typeof referenceImage === "string" && referenceImage.length > 0;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 180000);

  try {
    let response;
    let editTransport = useEdit ? "multipart" : "generations";
    if (useEdit) {
      const form = new FormData();
      form.append("model", config.model);
      form.append("prompt", prompt);
      form.append("n", String(input.n ?? 1));
      const size = input.size ?? config.size;
      if (size) {
        form.append("size", size);
      }
      form.append("image", uploadPart(referenceImage), basename(referenceImage));
      if (typeof input.mask === "string" && input.mask.length > 0) {
        form.append("mask", uploadPart(input.mask), basename(input.mask));
      }
      response = await fetch(imageApiEndpoint(config.baseUrl, "/images/edits"), {
        method: "POST",
        headers: { Authorization: `Bearer ${config.apiKey}` },
        body: form,
        signal: controller.signal
      });
      if (response.status === 404 || response.status === 405) {
        // Some providers (for example Qwen's OpenAI-compatible mode) do not
        // implement OpenAI's multipart /images/edits endpoint. They accept
        // image-to-image through /images/generations with an `image` field
        // holding a URL or a base64 data URL instead.
        await response.text().catch(() => "");
        const payload = {
          model: config.model,
          prompt,
          n: input.n ?? 1,
          image: imageDataUrl(referenceImage)
        };
        const fallbackSize = input.size ?? config.size;
        if (fallbackSize) {
          payload.size = fallbackSize;
        }
        response = await fetch(
          imageApiEndpoint(config.baseUrl, "/images/generations"), {
            method: "POST",
            headers: {
              Authorization: `Bearer ${config.apiKey}`,
              "Content-Type": "application/json"
            },
            body: JSON.stringify(payload),
            signal: controller.signal
          });
        editTransport = "image-field";
      }
    } else {
      const payload = {
        model: config.model,
        prompt,
        n: input.n ?? 1
      };
      const size = input.size ?? config.size;
      if (size) {
        payload.size = size;
      }
      response = await fetch(
        imageApiEndpoint(config.baseUrl, "/images/generations"), {
          method: "POST",
          headers: {
            Authorization: `Bearer ${config.apiKey}`,
            "Content-Type": "application/json"
          },
          body: JSON.stringify(payload),
          signal: controller.signal
        });
    }

    const text = await response.text();
    if (!response.ok) {
      throw new Error(`Image API returned ${response.status}: ${text.slice(0, 800)}`);
    }
    let data;
    try {
      data = JSON.parse(text);
    } catch {
      throw new Error(`Image API returned non-JSON content: ${text.slice(0, 200)}`);
    }
    const items = Array.isArray(data?.data) ? data.data : [];
    if (items.length === 0) {
      throw new Error("Image API returned no images.");
    }

    const outDir = join(tmpdir(), "aseprite-mcp-gen");
    mkdirSync(outDir, { recursive: true });
    const stamp = Date.now();
    const images = [];
    for (let i = 0; i < items.length; i += 1) {
      const item = items[i] ?? {};
      let buffer;
      if (typeof item.b64_json === "string") {
        buffer = Buffer.from(item.b64_json, "base64");
      } else if (typeof item.url === "string") {
        const download = await fetch(item.url, { signal: controller.signal });
        if (!download.ok) {
          throw new Error(`Could not download the generated image (${download.status}).`);
        }
        buffer = Buffer.from(await download.arrayBuffer());
      } else {
        continue;
      }
      const file = join(outDir,
        `gen-${stamp}-${i + 1}.${imageExtension(buffer)}`);
      writeFileSync(file, buffer);
      images.push({
        path: file,
        bytes: buffer.length,
        ...(typeof item.revised_prompt === "string"
          ? { revisedPrompt: item.revised_prompt }
          : {})
      });
    }
    if (images.length === 0) {
      throw new Error("Image API returned no usable image data.");
    }

    return {
      model: config.model,
      count: images.length,
      edit: useEdit,
      transport: editTransport,
      images
    };
  } finally {
    clearTimeout(timer);
  }
}

registerLocalTool(
  "generate_image",
  "Generate or edit an image with the OpenAI-compatible image API configured in Aseprite. Pass referenceImage to edit an existing picture; results are saved to the temp folder and their paths are returned.",
  {
    prompt: z.string().min(1).max(4000),
    referenceImage: z.string().min(1).max(4096).optional(),
    mask: z.string().min(1).max(4096).optional(),
    size: z.string().min(1).max(32).optional(),
    n: z.number().int().min(1).max(4).optional()
  },
  (input) => generateImage(input)
);

registerLocalTool(
  "get_image_api_status",
  "Report whether the OpenAI-compatible image API is configured (base URL, model, size) without exposing the API key.",
  {},
  () => {
    const found = readImageApiConfig();
    if (!found) {
      return { configured: false };
    }
    const config = found.config ?? {};
    return {
      configured: Boolean(config.baseUrl && config.apiKey && config.model),
      baseUrl: config.baseUrl ?? null,
      model: config.model ?? null,
      size: config.size ?? null,
      keySet: Boolean(config.apiKey),
      source: found.file
    };
  }
);

registerTool(
  "ping",
  "Check that the Aseprite Lua extension is reachable.",
  {},
  "ping",
  () => ({})
);

registerTool(
  "get_connection_status",
  "Get the Aseprite extension's WebSocket connection status.",
  {},
  "get_connection_status",
  () => ({})
);

registerTool(
  "get_active_sprite",
  "Get the active document: filename, modified state, dimensions, frame count and durations, active frame/layer, color mode, palette, animation tags, selection, tool, and colors.",
  {},
  "get_active_sprite",
  () => ({})
);

registerTool(
  "list_layers",
  "List the active sprite's layers with their stable ids, nesting, stack order, and properties.",
  {},
  "list_layers",
  () => ({})
);

registerTool(
  "list_cels",
  "Report which layers have a cel on a frame (defaults to the active frame), or the cel occupancy of every frame when allFrames is true.",
  {
    frame: z.number().int().min(1).optional(),
    allFrames: z.boolean().optional()
  },
  "list_cels",
  (input) => input
);

registerTool(
  "export_preview",
  "Render the active sprite with all visible layers flattened into a PNG in the temp folder and return its path. Read that path to actually look at the artwork.",
  { frame: z.number().int().min(1).optional() },
  "export_preview",
  (input) => input
);

registerTool(
  "export_animation",
  "Export the whole animation as an animated GIF, a numbered PNG sequence, or a horizontal sprite sheet, and return the output path(s).",
  { format: z.enum(["gif", "png_sequence", "sheet"]).optional() },
  "export_animation",
  (input) => input
);

registerTool(
  "sample_color",
  "Read the composited color of one pixel as #RRGGBBAA.",
  {
    x: z.number().int().min(0),
    y: z.number().int().min(0),
    frame: z.number().int().min(1).optional()
  },
  "sample_color",
  (input) => input
);

registerTool(
  "read_pixels",
  "Read a rectangle of composited pixels as rows of #RRGGBBAA colors. At most 4096 pixels per call.",
  {
    x: z.number().int().min(0),
    y: z.number().int().min(0),
    width: z.number().int().min(1),
    height: z.number().int().min(1),
    frame: z.number().int().min(1).optional()
  },
  "read_pixels",
  (input) => input
);

registerTool(
  "create_sprite",
  "Create a new sprite document with the given canvas size and color mode.",
  {
    width: z.number().int().min(1).max(16384),
    height: z.number().int().min(1).max(16384),
    colorMode: z.enum(["rgb", "grayscale", "indexed"]).optional()
  },
  "create_sprite",
  (input) => input
);

registerTool(
  "open_sprite",
  "Open a sprite file from disk and make it the active document.",
  { filename: z.string().min(1).max(4096) },
  "open_sprite",
  (input) => input
);

registerTool(
  "list_documents",
  "List every open document with its index, filename, size, frame count, modified state, and active flag.",
  {},
  "list_documents",
  () => ({})
);

registerTool(
  "activate_document",
  "Switch to another open document by index or filename.",
  {
    index: z.number().int().min(1).optional(),
    filename: z.string().min(1).max(4096).optional()
  },
  "activate_document",
  (input) => {
    if (input.index === undefined && input.filename === undefined) {
      throw new Error("Provide index or filename.");
    }
    return input;
  }
);

registerTool(
  "close_document",
  "Close an open document. A modified document is closed only when force is true, so unsaved work is not lost by accident.",
  {
    index: z.number().int().min(1).optional(),
    filename: z.string().min(1).max(4096).optional(),
    force: z.boolean().optional()
  },
  "close_document",
  (input) => {
    if (input.index === undefined && input.filename === undefined) {
      throw new Error("Provide index or filename.");
    }
    return input;
  }
);

registerTool(
  "resize_sprite",
  "Resize the active sprite canvas; existing content keeps its top-left origin.",
  {
    width: z.number().int().min(1).max(16384),
    height: z.number().int().min(1).max(16384)
  },
  "resize_sprite",
  (input) => input
);

registerTool(
  "set_active_tool",
  "Select an installed Aseprite tool by its tool id.",
  { tool: z.string().min(1).max(100) },
  "set_active_tool",
  (input) => input
);

registerTool(
  "set_active_layer",
  "Select a layer by name or by its stable layer id.",
  {
    layer: z.string().min(1).optional(),
    layerId: z.number().int().optional()
  },
  "set_active_layer",
  (input) => input
);

registerTool(
  "new_layer",
  "Create an image layer in the current sprite and select it.",
  { name: z.string().min(1).max(255).optional() },
  "new_layer",
  (input) => input
);

registerTool(
  "new_group",
  "Create a group layer in the current sprite.",
  { name: z.string().min(1).max(255).optional() },
  "new_group",
  (input) => input
);

registerTool(
  "delete_layer",
  "Delete a layer by name or id. The only layer cannot be deleted.",
  {
    layer: z.string().min(1).optional(),
    layerId: z.number().int().optional()
  },
  "delete_layer",
  (input) => input
);

registerTool(
  "new_cel",
  "Create or replace the cel of one layer on one frame; copyFromFrame copies that frame's cel content as the starting point.",
  {
    layer: z.string().min(1).optional(),
    layerId: z.number().int().optional(),
    frame: z.number().int().min(1).optional(),
    copyFromFrame: z.number().int().min(1).optional()
  },
  "new_cel",
  (input) => input
);

registerTool(
  "delete_cel",
  "Remove the cel of one layer on one frame without deleting the frame itself.",
  {
    layer: z.string().min(1).optional(),
    layerId: z.number().int().optional(),
    frame: z.number().int().min(1).optional()
  },
  "delete_cel",
  (input) => input
);

registerTool(
  "stamp_image",
  "Place a PNG file on a layer as that frame's cel (optionally creating a new layer), so artwork prepared outside Aseprite can be iterated quickly.",
  {
    filename: z.string().min(1).max(4096),
    x: z.number().int().min(0).optional(),
    y: z.number().int().min(0).optional(),
    frame: z.number().int().min(1).optional(),
    layer: z.string().min(1).optional(),
    layerId: z.number().int().optional(),
    newLayer: z.string().min(1).max(255).optional()
  },
  "stamp_image",
  (input) => {
    if (input.layer === undefined && input.layerId === undefined &&
        input.newLayer === undefined) {
      throw new Error("Provide layer, layerId, or newLayer.");
    }
    return input;
  }
);

registerTool(
  "duplicate_layer",
  "Duplicate a layer (by name or id, defaulting to the active layer) above its source.",
  {
    layer: z.string().min(1).optional(),
    layerId: z.number().int().optional()
  },
  "duplicate_layer",
  (input) => input
);

registerTool(
  "merge_down_layer",
  "Merge a layer into the layer below it.",
  {
    layer: z.string().min(1).optional(),
    layerId: z.number().int().optional()
  },
  "merge_down_layer",
  (input) => input
);

registerTool(
  "flatten_sprite",
  "Flatten every layer of the active sprite into a single layer.",
  {},
  "flatten_sprite",
  () => ({})
);

registerTool(
  "set_layer_properties",
  "Rename a layer or set its visibility, editability, or opacity. Address it by name or id.",
  {
    layer: z.string().min(1).optional(),
    layerId: z.number().int().optional(),
    name: z.string().min(1).optional(),
    visible: z.boolean().optional(),
    editable: z.boolean().optional(),
    opacity: z.number().int().min(0).max(255).optional()
  },
  "set_layer_properties",
  (input) => {
    if (input.name === undefined && input.visible === undefined &&
        input.editable === undefined && input.opacity === undefined) {
      throw new Error("Provide at least one layer property to change.");
    }
    return input;
  }
);

registerTool(
  "set_active_frame",
  "Select a frame in the current sprite using a 1-based frame number.",
  { frame: z.number().int().min(1) },
  "set_active_frame",
  (input) => input
);

registerTool(
  "add_frame",
  "Append a new frame, either copying the previous frame or creating an empty frame.",
  { empty: z.boolean().optional() },
  "add_frame",
  (input) => input
);

registerTool(
  "duplicate_frame",
  "Insert a copy of a frame (defaults to the active frame) right after it and select the copy.",
  { frame: z.number().int().min(1).optional() },
  "duplicate_frame",
  (input) => input
);

registerTool(
  "delete_frame",
  "Delete a frame by its 1-based frame number. The only frame cannot be deleted.",
  { frame: z.number().int().min(1) },
  "delete_frame",
  (input) => input
);

registerTool(
  "set_frame_duration",
  "Set how long a frame stays on screen, in milliseconds.",
  {
    frame: z.number().int().min(1).optional(),
    durationMs: z.number().int().min(1).max(65535)
  },
  "set_frame_duration",
  (input) => input
);

registerTool(
  "new_tag",
  "Create an animation tag over a frame range with an optional direction and repeat count.",
  {
    name: z.string().min(1).max(255).optional(),
    from: z.number().int().min(1).optional(),
    to: z.number().int().min(1).optional(),
    aniDir: z.enum(["forward", "reverse", "ping-pong", "ping-pong-reverse"]).optional(),
    repeats: z.number().int().min(0).optional()
  },
  "new_tag",
  (input) => input
);

registerTool(
  "edit_tag",
  "Rename an animation tag or change its frame range, direction, or repeat count.",
  {
    name: z.string().min(1),
    newName: z.string().min(1).max(255).optional(),
    from: z.number().int().min(1).optional(),
    to: z.number().int().min(1).optional(),
    aniDir: z.enum(["forward", "reverse", "ping-pong", "ping-pong-reverse"]).optional(),
    repeats: z.number().int().min(0).optional()
  },
  "edit_tag",
  (input) => {
    if (input.newName === undefined && input.from === undefined &&
        input.to === undefined && input.aniDir === undefined &&
        input.repeats === undefined) {
      throw new Error("Provide at least one tag property to change.");
    }
    return input;
  }
);

registerTool(
  "delete_tag",
  "Delete an animation tag by name.",
  { name: z.string().min(1) },
  "delete_tag",
  (input) => input
);

registerTool(
  "set_colors",
  "Set the foreground color, background color, or both using #RRGGBB or #RRGGBBAA values.",
  {
    foreground: z.string().regex(/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/).optional(),
    background: z.string().regex(/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/).optional()
  },
  "set_colors",
  (input) => {
    if (input.foreground === undefined && input.background === undefined) {
      throw new Error("Provide foreground, background, or both colors.");
    }
    return input;
  }
);

registerTool(
  "draw_stroke",
  "Draw points with any installed Aseprite tool id (pencil, eraser, paint_bucket, line, ...). Colors accept #RRGGBB or #RRGGBBAA; address the target layer by name or id.",
  {
    points: z.array(z.object({
      x: z.number().int().min(0).max(32767),
      y: z.number().int().min(0).max(32767)
    })).min(1).max(2048),
    tool: z.string().min(1).max(100).optional(),
    color: z.string().regex(/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/).optional(),
    frame: z.number().int().min(1).optional(),
    layer: z.string().min(1).optional(),
    layerId: z.number().int().optional()
  },
  "draw_stroke",
  (input) => input
);

registerTool(
  "save_sprite",
  "Save the current sprite to its existing file, or save it to a new filename.",
  { filename: z.string().min(1).max(4096).optional() },
  "save_sprite",
  (input) => input
);

registerTool(
  "undo",
  "Undo the most recent Aseprite operation.",
  {},
  "undo",
  () => ({})
);

registerTool(
  "redo",
  "Redo the most recently undone Aseprite operation.",
  {},
  "redo",
  () => ({})
);

const transport = new StdioServerTransport();
await connectOrStartBroker();
await server.connect(transport);
process.stderr.write("Aseprite MCP ready; shared broker connection established.\n");

async function shutdown() {
  rejectPendingRequests("MCP bridge is shutting down.");
  if (brokerSocket && brokerSocket.readyState === WebSocket.OPEN) {
    brokerSocket.close(1001, "MCP session shutting down");
  }
  await server.close();
}

process.once("SIGINT", () => void shutdown());
process.once("SIGTERM", () => void shutdown());
