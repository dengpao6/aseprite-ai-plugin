# Aseprite AI Plugin

这个扩展和自带的 MCP server 把 Aseprite 连接到支持 Model Context Protocol
(MCP) 的本地 AI agent。开箱支持两个 agent：

- **Codex**：通过 `~/.codex/config.toml` 配置。
- **DeepSeek Harness (DSH)**：通过 DSH home patch
  `$DSH_HOME/cordis.patch.yml` 配置。

MCP server 通过 stdio 与每个 agent 通信。一个共享的本地 broker 在任意数量的
MCP 会话与 Lua 扩展之间转发请求；Aseprite 连接到 `ws://127.0.0.1:8765`。
Codex 和 DSH 可以同时连接，并共享同一个 Aseprite 连接。

## 安装

1. 安装 Node.js 18 或更新版本。在 `codex-aseprite/mcp-bridge` 目录运行：

   ```powershell
   npm install
   ```

2. 在 `codex-aseprite` 目录生成扩展包：

   ```powershell
   .\package.ps1
   ```

3. 在 Aseprite 中打开 **Edit > Preferences > Extensions > Add Extension**，
   选择生成的 `codex-aseprite.aseprite-extension.zip`。如有需要，启用该扩展。
4. 启用后，扩展会注册自己的 MCP server，并生成一个共享 token 保存在扩展偏好
   中。请同意 Aseprite 的文件访问提示：
   - 它会新增或更新 `%USERPROFILE%\.codex\config.toml`
     （macOS/Linux 为 `$HOME/.codex/config.toml`）中的
     `[mcp_servers.codex-aseprite]`。
   - 当存在 DeepSeek Harness home 目录（`%USERPROFILE%\.dsh` 或
     `$DSH_HOME`）时，会在该目录的 `cordis.patch.yml` 中新增或更新
     `mcp-aseprite` 行。
5. 在 Aseprite 中选择 **File > Scripts > MCP Bridge > Connect to local bridge**。
   如出现提示，同意脚本访问 `127.0.0.1` 的 WebSocket 权限。

压缩包同时包含 Lua 扩展和 MCP bridge 文件。bridge 需要安装 Node.js，并且
`node` 在 PATH 中可用。仅把源码文件夹放到 Aseprite 仓库根目录不会加载它；
请通过 Preferences 安装扩展包。

扩展菜单位于 **File > Scripts > MCP Bridge**：

- **Connect to local bridge**：启动 Aseprite 的 WebSocket 连接。
- **Disconnect**：关闭连接。
- **Connection status**：显示 bridge 状态和两个 agent 的注册情况。
- **Register with Codex**：重写 Codex 的 MCP 条目（例如移动扩展目录或更换
  token 之后）。
- **Register with DeepSeek Harness**：重写 DSH 的 MCP 条目。
- **Set DeepSeek Harness home...**：修改检测到的 DSH home 目录。

每次启动 Aseprite 都会执行注册，因此更新或重装扩展后会自动刷新 server 路径。

## 使用流程

- **安装插件**：在aseprite的上框栏中选择:Edit > Preferences > Extensions > Add Extension
  >选择压缩文件
- **向agent注册mcp工具**：在aseprite上框中选择File > Scripts > MCP Bridge > Register With Codex/DeepSeek Harness
- 在同级目录点击Connect to local bridge
- **向agent配置生图大模型**：在aseprite上框中选择File > Scripts > MCP Bridge > Configure image API...
  填写 Base URL（默认 `https://api.openai.com/v1`）、API key、模型名（例如
  `gpt-image-1`），以及可选的尺寸（如 `1024x1024`）。
  配置好后遇到需要大幅重构的工作等,智能体可以通过调用生图大模型生成所需素材,再放入aseprite工作区进行修改
两个工具都运行在共享 MCP server 中，Codex 和 DSH 一样可用；不绑定 DSH。


## DeepSeek Harness (DSH) 配置

DSH 适配器使用内置的 `@deepseek-ai/dsh-mcp-client` 插件，当前 DSH 版本自带。
注册会在 DSH home patch（`$DSH_HOME/cordis.patch.yml`，默认
`%USERPROFILE%\.dsh\cordis.patch.yml`）中插入一行：

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

说明：

- DSH 至少启动过一次，home 目录才会存在。如果不存在，先启动一次 DSH，再运行
  **Register with DeepSeek Harness**，或从菜单设置 home 目录。
- DSH 开启热重载（`dsh-hmr`）时，新 MCP server 无需重启即可挂载；否则注册后
  重启 DSH。
## Codex 配置

注册会写入 `~/.codex/config.toml`：

```toml
[mcp_servers.codex-aseprite]
command = "node"
args = ["C:\\path\\to\\codex-aseprite\\mcp-bridge\\server.mjs"]
env = { ASEPRITE_BRIDGE_TOKEN = "<shared bridge token>" }
```

条目创建或更新后重启 Codex。

## MCP 工具

Codex 和 DSH 从 MCP server 获得相同的 42 个工具。

