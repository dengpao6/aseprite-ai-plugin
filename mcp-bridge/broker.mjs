import { randomUUID } from "node:crypto";
import { isIP } from "node:net";
import { WebSocket, WebSocketServer } from "ws";

const host = "127.0.0.1";
const asepritePort = Number(process.env.ASEPRITE_BRIDGE_PORT ?? 8765);
const mcpPort = Number(process.env.ASEPRITE_MCP_BROKER_PORT ?? 8766);
const requestTimeoutMs = 15000;
const maxPayloadBytes = 1024 * 1024;
const bridgeToken = process.env.ASEPRITE_BRIDGE_TOKEN;

if (!bridgeToken || bridgeToken.length < 32) {
  throw new Error("Set ASEPRITE_BRIDGE_TOKEN to a secret of at least 32 characters.");
}

if (!Number.isInteger(asepritePort) || asepritePort < 1 || asepritePort > 65535 ||
    !Number.isInteger(mcpPort) || mcpPort < 1 || mcpPort > 65535 ||
    asepritePort === mcpPort) {
  throw new Error("Bridge and broker ports must be different valid TCP ports.");
}

const asepriteServer = new WebSocketServer({
  host,
  port: asepritePort,
  maxPayload: maxPayloadBytes,
  perMessageDeflate: false
});
const mcpServer = new WebSocketServer({
  host,
  port: mcpPort,
  maxPayload: maxPayloadBytes,
  perMessageDeflate: false
});

let asepriteSocket = null;
const authenticatedClients = new Set();
const pendingRequests = new Map();

function isLoopback(address) {
  const normalized = address?.startsWith("::ffff:")
    ? address.slice("::ffff:".length)
    : address;
  return !!normalized && isIP(normalized) !== 0 &&
    ["127.0.0.1", "::1"].includes(normalized);
}

function rejectPendingRequests(reason, client = null) {
  for (const [bridgeId, pending] of pendingRequests) {
    if (client && pending.client !== client) {
      continue;
    }
    clearTimeout(pending.timeout);
    pendingRequests.delete(bridgeId);
    if (pending.client.readyState === WebSocket.OPEN) {
      pending.client.send(JSON.stringify({
        id: pending.requestId,
        ok: false,
        error: reason
      }));
    }
  }
}

asepriteServer.on("connection", (socket, request) => {
  if (!isLoopback(request.socket.remoteAddress)) {
    socket.close(1008, "Loopback connections only");
    return;
  }
  if (asepriteSocket && asepriteSocket.readyState === WebSocket.OPEN) {
    socket.close(1013, "An Aseprite instance is already connected");
    return;
  }

  asepriteSocket = socket;
  process.stderr.write("Aseprite MCP broker: Aseprite connected.\n");

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

    if (!response || typeof response.id !== "string") {
      return;
    }
    const pending = pendingRequests.get(response.id);
    if (!pending) {
      return;
    }

    clearTimeout(pending.timeout);
    pendingRequests.delete(response.id);
    if (pending.client.readyState !== WebSocket.OPEN) {
      return;
    }

    pending.client.send(JSON.stringify({
      id: pending.requestId,
      ok: response.ok === true,
      ...(response.ok === true
        ? { result: response.result }
        : { error: typeof response.error === "string"
            ? response.error
            : "Aseprite operation failed." })
    }));
  });

  socket.on("close", () => {
    if (asepriteSocket !== socket) {
      return;
    }
    asepriteSocket = null;
    rejectPendingRequests("Aseprite disconnected before replying.");
    process.stderr.write("Aseprite MCP broker: Aseprite disconnected.\n");
  });

  socket.on("error", (error) => {
    process.stderr.write(`Aseprite MCP broker WebSocket error: ${error.message}\n`);
  });
});

mcpServer.on("connection", (socket, request) => {
  if (!isLoopback(request.socket.remoteAddress)) {
    socket.close(1008, "Loopback connections only");
    return;
  }

  let authenticated = false;
  socket.on("message", (data, isBinary) => {
    if (isBinary) {
      socket.close(1003, "Text messages only");
      return;
    }

    let message;
    try {
      message = JSON.parse(data.toString());
    } catch {
      socket.close(1007, "Invalid JSON");
      return;
    }

    if (!authenticated) {
      if (message?.type !== "authenticate" || message.token !== bridgeToken) {
        socket.close(1008, "Authentication failed");
        return;
      }
      authenticated = true;
      authenticatedClients.add(socket);
      socket.send(JSON.stringify({ type: "authenticated" }));
      return;
    }

    if (message?.type !== "request" ||
        typeof message.id !== "string" ||
        typeof message.method !== "string" ||
        !message.params || typeof message.params !== "object" ||
        Array.isArray(message.params)) {
      socket.send(JSON.stringify({
        id: typeof message?.id === "string" ? message.id : "",
        ok: false,
        error: "Invalid broker request."
      }));
      return;
    }

    if (!asepriteSocket || asepriteSocket.readyState !== WebSocket.OPEN) {
      socket.send(JSON.stringify({
        id: message.id,
        ok: false,
        error: "Aseprite is not connected. Use File > Scripts > MCP Bridge > Connect to local bridge."
      }));
      return;
    }

    const bridgeId = randomUUID();
    const timeout = setTimeout(() => {
      pendingRequests.delete(bridgeId);
      if (socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({
          id: message.id,
          ok: false,
          error: `Aseprite timed out while handling '${message.method}'.`
        }));
      }
    }, requestTimeoutMs);

    pendingRequests.set(bridgeId, {
      client: socket,
      requestId: message.id,
      timeout
    });

    const target = asepriteSocket;
    const payload = JSON.stringify({
      id: bridgeId,
      token: bridgeToken,
      method: message.method,
      params: message.params
    });
    const handleSendError = (error) => {
      if (!error) {
        return;
      }
      const pending = pendingRequests.get(bridgeId);
      if (!pending) {
        return;
      }
      clearTimeout(pending.timeout);
      pendingRequests.delete(bridgeId);
      if (socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({
          id: message.id,
          ok: false,
          error: `Could not send request to Aseprite: ${error.message}`
        }));
      }
    };
    try {
      target.send(payload, handleSendError);
    } catch (error) {
      handleSendError(error);
    }
  });

  socket.on("close", () => {
    authenticatedClients.delete(socket);
    rejectPendingRequests("MCP session disconnected.", socket);
  });

  socket.on("error", (error) => {
    process.stderr.write(`Aseprite MCP broker client error: ${error.message}\n`);
  });
});

await Promise.all([
  new Promise((resolve, reject) => {
    asepriteServer.once("listening", resolve);
    asepriteServer.once("error", reject);
  }),
  new Promise((resolve, reject) => {
    mcpServer.once("listening", resolve);
    mcpServer.once("error", reject);
  })
]);

process.stderr.write(
  `Aseprite MCP broker ready; Aseprite port ${asepritePort}, MCP port ${mcpPort}.\n`
);

async function shutdown() {
  rejectPendingRequests("Aseprite MCP broker is shutting down.");
  for (const client of authenticatedClients) {
    client.close(1001, "Broker shutting down");
  }
  if (asepriteSocket && asepriteSocket.readyState === WebSocket.OPEN) {
    asepriteSocket.close(1001, "Broker shutting down");
  }
  await Promise.all([
    new Promise((resolve) => asepriteServer.close(resolve)),
    new Promise((resolve) => mcpServer.close(resolve))
  ]);
}

process.once("SIGINT", () => void shutdown());
process.once("SIGTERM", () => void shutdown());
