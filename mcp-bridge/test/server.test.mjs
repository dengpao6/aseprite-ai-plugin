import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { createServer } from "node:net";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import WebSocket from "ws";

async function getFreePort() {
  const server = createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const { port } = server.address();
  await new Promise((resolve, reject) => server.close((error) =>
    error ? reject(error) : resolve()
  ));
  return port;
}

async function waitForSocket(url) {
  const deadline = Date.now() + 10000;
  let lastError;
  while (Date.now() < deadline) {
    const socket = new WebSocket(url);
    try {
      await new Promise((resolve, reject) => {
        socket.once("open", resolve);
        socket.once("error", reject);
      });
      return socket;
    } catch (error) {
      lastError = error;
      socket.terminate();
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
  }
  throw lastError ?? new Error(`Timed out connecting to ${url}`);
}

test("multiple MCP sessions share one Aseprite bridge connection", async () => {
  const token = randomBytes(32).toString("hex");
  const asepritePort = await getFreePort();
  const brokerPort = await getFreePort();
  const env = {
    ...process.env,
    ASEPRITE_BRIDGE_PORT: String(asepritePort),
    ASEPRITE_MCP_BROKER_PORT: String(brokerPort),
    ASEPRITE_BRIDGE_TOKEN: token
  };
  const broker = spawn(process.execPath, ["broker.mjs"], {
    cwd: process.cwd(),
    env,
    stdio: "ignore"
  });
  const clients = [];
  let asepriteSocket;

  async function startMcpSession(name) {
    const transport = new StdioClientTransport({
      command: process.execPath,
      args: ["server.mjs"],
      cwd: process.cwd(),
      env
    });
    const client = new Client({ name, version: "1.0.0" });
    await client.connect(transport);
    clients.push(client);
    return client;
  }

  try {
    const brokerSocket = await waitForSocket(`ws://127.0.0.1:${brokerPort}`);
    brokerSocket.close();

    const firstClient = await startMcpSession("codex-session-one");
    const secondClient = await startMcpSession("codex-session-two");
    const { tools } = await secondClient.listTools();
    assert.deepEqual(
      tools.map((tool) => tool.name).sort(),
      [
        "activate_document",
        "add_frame",
        "close_document",
        "create_sprite",
        "delete_cel",
        "delete_frame",
        "delete_layer",
        "delete_tag",
        "draw_stroke",
        "duplicate_frame",
        "duplicate_layer",
        "edit_tag",
        "export_animation",
        "export_preview",
        "flatten_sprite",
        "generate_image",
        "get_active_sprite",
        "get_connection_status",
        "get_image_api_status",
        "list_cels",
        "list_documents",
        "list_layers",
        "merge_down_layer",
        "new_cel",
        "new_group",
        "new_layer",
        "new_tag",
        "open_sprite",
        "ping",
        "read_pixels",
        "redo",
        "resize_sprite",
        "sample_color",
        "save_sprite",
        "set_active_frame",
        "set_active_layer",
        "set_active_tool",
        "set_colors",
        "set_frame_duration",
        "set_layer_properties",
        "stamp_image",
        "undo"
      ]
    );

    asepriteSocket = await waitForSocket(`ws://127.0.0.1:${asepritePort}`);
    asepriteSocket.on("message", (data) => {
      const request = JSON.parse(data.toString());
      assert.equal(request.token, token);
      let result;
      if (request.method === "ping") {
        result = { message: "pong" };
      } else if (request.method === "get_active_sprite") {
        result = {
          width: 32,
          height: 32,
          frames: 1,
          frame: 1,
          layer: "Layer 1"
        };
      } else if (request.method === "draw_stroke") {
        result = {
          points: request.params.points.length,
          frame: 1,
          layer: "Layer 1"
        };
      } else {
        result = { message: `${request.method} forwarded` };
      }
      asepriteSocket.send(JSON.stringify({
        id: request.id,
        ok: true,
        result
      }));
    });

    const [spriteResult, pingResult, strokeResult] = await Promise.all([
      firstClient.callTool({
        name: "get_active_sprite",
        arguments: {}
      }),
      secondClient.callTool({
        name: "ping",
        arguments: {}
      }),
      secondClient.callTool({
        name: "draw_stroke",
        arguments: {
          points: [{ x: 1, y: 2 }, { x: 3, y: 4 }],
          tool: "pencil"
        }
      })
    ]);

    assert.equal(JSON.parse(spriteResult.content[0].text).width, 32);
    assert.deepEqual(JSON.parse(pingResult.content[0].text), { message: "pong" });
    assert.equal(JSON.parse(strokeResult.content[0].text).points, 2);

    const failedUndo = await firstClient.callTool({
      name: "undo",
      arguments: {}
    });
    assert.equal(failedUndo.isError, undefined);
    assert.match(failedUndo.content[0].text, /undo forwarded/);
  } finally {
    if (asepriteSocket && asepriteSocket.readyState === WebSocket.OPEN) {
      asepriteSocket.close();
    }
    await Promise.all(clients.map((client) => client.close()));
    broker.kill();
    await new Promise((resolve) => {
      if (broker.exitCode !== null) {
        resolve();
      } else {
        broker.once("exit", resolve);
        setTimeout(resolve, 2000);
      }
    });
  }
});
