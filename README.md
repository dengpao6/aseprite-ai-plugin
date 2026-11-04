# Aseprite MCP Bridge

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
- 如果能在 `PATH` 中找到 `node`，扩展会写入绝对路径；否则写入 `node`。DSH
  启动 bridge 时会清理环境变量，所以绝对路径最可靠。
- home patch 是机器级配置，对所有 DSH profile 生效，优先级高于 per-profile
  patch。DSH 的配置编辑器只写 profile patch，所以这一行由扩展管理。
- `cordis.patch.yml` 中的其他行（locale、theme、模型设置）会保留。重复注册是
  幂等的，只替换 `mcp-aseprite` 行。
- DSH 开启热重载（`dsh-hmr`）时，新 MCP server 无需重启即可挂载；否则注册后
  重启 DSH。

工具名会加上 `serverName` 命名空间，例如 `mcp__aseprite__get_active_sprite`
或 `mcp__aseprite__draw_stroke`。

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

### 生成图片

- **首次配置 API**：File > Scripts > MCP Bridge > Configure image API...
  填写 Base URL（默认 `https://api.openai.com/v1`）、API key、模型名（例如
  `gpt-image-1`），以及可选的尺寸（如 `1024x1024`）。配置写入扩展目录的
  `image-api.json`，并镜像到 Aseprite 用户配置目录的
  `codex-aseprite-image.json`。API key 以明文保存；Base URL/Model 保持可编辑，
  以便兼容任意 OpenAI 兼容服务商。
- `generate_image`：调用配置的 API 生成新图；传入 `referenceImage` 时使用参考
  图。无参考图时向 `/images/generations` 发送 JSON。有参考图时先尝试 OpenAI 的
  multipart `/images/edits`；如果该接口不存在（404/405），则回退到
  `/images/generations` 并携带 `image` 字段（base64 data URL），Qwen 的
  OpenAI 兼容模式就是用这种方式实现图生图。响应可能是 `b64_json` 或 `url`；
  结果保存到 `%TEMP%\aseprite-mcp-gen`，返回本地路径，任何 agent 都可以读取、
  检查并传给 `stamp_image`。结果的 `transport` 字段为 `generations`、
  `multipart` 或 `image-field`。
- `get_image_api_status`：报告 API 是否已配置、base URL、模型、尺寸以及是否
  设置了 key，但不返回 key 本身。

两个工具都运行在共享 MCP server 中，Codex 和 DSH 一样可用；不绑定 DSH。

### 查看结果

- `export_preview`：把所有可见图层合并后的当前 sprite 渲染为 PNG，写到系统
  临时目录（Windows 为 `%TEMP%\aseprite-mcp-previews`），返回路径、尺寸和
  字节数。读取该路径即可在每次编辑之间真正看到画面。
- `export_animation`：把整个动画导出为 GIF、编号 PNG 序列或横向 sprite sheet，
  返回输出路径。GIF 通过先保存临时 `.aseprite` 副本，再用 Aseprite CLI 批处理
  生成——因为 GUI 脚本里直接保存 GIF 会让 Aseprite 的保存任务死锁；比 PNG
  输出多花一两秒。
- `sample_color`：返回某个像素合成后的颜色，格式 `#RRGGBBAA`。
- `read_pixels`：返回一个矩形区域内合成后的像素，按行给出 `#RRGGBBAA` 值
  （每次最多 4096 像素）。

### 检查

- `ping`：检查 Aseprite 扩展是否可达。
- `get_connection_status`：报告扩展的 WebSocket 连接状态。
- `get_active_sprite`：返回文件名、修改状态、尺寸、帧数和每帧时长、当前帧和
  图层（含稳定 id）、颜色模式、调色板（索引 sprite 会包含索引色）、动画 tag、
  选区范围、当前工具，以及前景/背景色。
- `list_layers`：列出图像、组和 tilemap 图层，含稳定 id、嵌套深度、父级名称、
  堆叠顺序、可见性、可编辑性和不透明度。
- `list_cels`：报告某帧（默认当前帧）哪些图层有 cel；`allFrames: true` 返回
  每帧的 cel 占用和时长。
- `list_documents`：列出所有打开的文档，含索引、文件名、尺寸、帧数、修改状态
  和是否为当前文档。

### 文档

- `create_sprite`：按指定宽高和颜色模式（`rgb`、`grayscale`、`indexed`）新建
  文档。
- `open_sprite`：打开 sprite 文件并设为当前文档。
- `activate_document` / `close_document`：按索引或文件名切换/关闭文档。已修改
  的文档只有 `force` 为 true 才会关闭。
- `resize_sprite`：调整画布尺寸；已有内容保持左上角原点。
- `save_sprite`：保存当前 sprite 到原文件名；提供 `filename` 时保存到新路径。

### 图层与 cel

- `new_layer` / `new_group`：新增图像图层或组。
- `set_active_layer`：按名称或稳定 `layerId` 选择图层。
- `set_layer_properties`：重命名图层，或修改可见性、可编辑性、不透明度
  （0-255）。
- `delete_layer`：按名称或 id 删除图层；最后一个图层受保护。
- `duplicate_layer`：在源图层上方复制一份。
- `merge_down_layer`：把图层合并到下方图层。
- `flatten_sprite`：把所有图层合并为一个。
- `new_cel`：创建或替换某图层在某帧的 cel；可选从另一帧复制 cel 内容（和
  位置），以便在已有 keyframe 基础上继续。
- `delete_cel`：删除某图层在某帧的 cel，不删除帧本身。

### 帧与 tag

- `set_active_frame`：按 1 起始的帧号选择帧。
- `add_frame`：追加复制帧或空帧。
- `duplicate_frame`：在帧后插入副本并选中副本，便于复制 keyframe 后就地编辑。
- `delete_frame`：删除帧；最后一帧受保护。
- `set_frame_duration`：设置帧显示时长（毫秒）。
- `new_tag`：在帧范围上创建动画 tag，可指定方向（`forward`、`reverse`、
  `ping-pong`、`ping-pong-reverse`）和重复次数。
- `edit_tag`：重命名 tag，或修改帧范围、方向、重复次数。
- `delete_tag`：按名称删除动画 tag。

### 绘制

- `set_colors`：设置前景/背景色，支持 `#RRGGBB` 或 `#RRGGBBAA`。
- `set_active_tool`：按 id 选择已安装的 Aseprite 工具。
- `draw_stroke`：按工具 id 向任意已安装工具发送整数画布坐标（例如 `pencil`、
  `eraser`、`line`、`paint_bucket`）。可选参数：`tool`、`color`
  （`#RRGGBB` 或 `#RRGGBBAA`）、`frame`（1 起始）、目标 `layer` /
  `layerId`。一次笔画是一个可撤销事务，完成后刷新显示，最多 2048 个点。在没有
  cel 的帧上绘制会自动创建 cel。
- `undo` / `redo`：在共享的 Aseprite 撤销历史中前进/后退。

编辑不再自动保存：文档修改会保持未保存，直到调用 `save_sprite`，因此出错时
可以撤销而不碰文件。`get_active_sprite` 会返回 `isModified`，agent 可据此判断
是否需要保存。

有些 Aseprite 工具需要特定数量或排列的点。它们的行为遵循 Aseprite 自己的
`app.useTool()` API；不支持的工具 id 或点排列会返回操作错误。图层、帧和工具
选择只作用于当前 sprite；先用 `get_active_sprite` 和 `list_layers` 检查。

图层可以用 `layer`（名称）或 `layerId` 指定。两个图层同名时，按名称查找会报错
并列出候选 id，而不是悄悄编辑第一个匹配项；此时用 `list_layers` 里的
`layerId`。

预览 PNG 会堆积在临时目录；删除该目录是安全的。

Lua 脚本其余函数是内部辅助或扩展生命周期操作，不是远程操作。例如 bridge
连接通过 Aseprite 的 **File > Scripts > MCP Bridge** 菜单启动/停止。

扩展会自动创建并共享 MCP 认证 token。每个 agent 会话可以启动自己的 stdio
MCP 进程；这些进程连接到 `127.0.0.1:8766` 上的同一个本地 broker，由它通过
单一 Aseprite 连接转发请求。broker 随第一个 MCP 进程自动启动并独立运行，以便
后续会话复用。它的 WebSocket 端点只绑定 loopback，不要暴露到网络接口。

## 故障排查

- **重装或更新扩展后 agent 工具消失。** 全新安装可能重新生成共享 token，而
  仍在运行的 broker 和 agent 还持有旧 token；新的 MCP 进程会在认证时被拒绝。
  重启 Aseprite 以加载新扩展和 token，再重启 agent（Codex 或 DSH）以使用当前
  配置重连。
- **DSH 不显示 Aseprite 工具。** 重启 DSH；DSH 通常通过 HMR 重载
  `cordis.patch.yml`，但挂载失败时需要重启。检查 `mcp-aseprite` 行；如果文件
  被编辑或移动，重新运行 **Register with DeepSeek Harness**。
- **工具调用报 "Aseprite is not connected"。** 在 Aseprite 中点击
  **File > Scripts > MCP Bridge > Connect to local bridge**。
- **更新后报 `Unknown method`。** 已安装的 Aseprite 仍在运行旧的 `main.lua`；
  重启 Aseprite。
