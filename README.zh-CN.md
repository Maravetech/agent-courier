# agent-courier

[English](README.md)

**Courier（投递）**：让一个 AI Agent 往 macOS 上 **Codex 桌面 App** 的指定会话里投递消息，再读会话记录确认送达、读取回复，然后接着推进任务。整个过程**不抢你的键盘和鼠标焦点**。

> 这是非官方的社区项目，和 OpenAI、Anthropic 没有关联，也没有得到它们的认可或支持。「Codex」「ChatGPT」「Claude」是各自所有者的商标。

## 原理

- **前端发送**：Agent 通过 macOS 的辅助功能接口在后台操作：切到 Codex App 里的目标会话，写入输入框，再点发送。任意会话都能投，包括新建会话。
- **后端核对**：直接只读 `~/.codex` 里的会话记录。核对送达、读回复都只要几行文字，不用截图。
- **身份令牌**：发送时第一行写 `【投递】<发送方>·<编号> → Codex·<编号>`，回复时第一行写 `【回复】Codex·<编号> → <发送方>·<编号>`，谁发给谁一眼就能看清。

| 通道 | 工具 | 能投到哪里 | 截图 |
| --- | --- | --- | --- |
| 前端主通道 | Claude Computer use（后台 `app_*` 工具） | Codex App 里的任意会话，包括新建会话 | 写入或点击前截一张 0.1 倍的小图 |
| 前端备用通道 | [cua-driver](https://github.com/trycua/cua) 的辅助功能调用（`ui-*` 命令） | 同上 | 不截图 |
| 命令行兜底 | `codex exec` | 新建会话，以及 App 从没加载过的会话 | 不截图 |

## 安全设计

- 不覆盖草稿：输入框里只要不是占位文字，就停下来问你。
- 发送前核对当前标签页；没有身份抬头的消息直接拒发。
- 只在后台操作：不接管全屏、不碰剪贴板、不点链接。
- 碰到资金、凭据、改规则、不可逆操作，或者迟迟没有进展，就停下来交还给你。

## 安装

**Claude Code**（插件）：

```bash
claude plugin marketplace add Maravetech/agent-courier
claude plugin install agent-courier@courier-marketplace
```

**其他 Agent**（Codex、OpenClaw、Hermes 等读技能目录的 Agent）：

```bash
git clone https://github.com/Maravetech/agent-courier
cd agent-courier && ./install.sh          # 把 skills/courier 软链到 ~/.agents/skills 等目录
./install.sh --check                      # 只检查，不改动
```

然后对照 **[PREREQUISITES.md](skills/courier/PREREQUISITES.md)** 逐项检查：macOS 授权、打开 Computer use、批准 Codex 访问、命令行登录、自检。不要跳过。

## 配置

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `CODEX_HOME` | `~/.codex` | Codex 会话记录所在目录 |
| `COURIER_STATE_DIR` | `~/.local/state/courier` | 命令行通道的日志目录 |
| `COURIER_AGENTS` | 任意合规名称 | 发送方白名单，逗号分隔 |
| `COURIER_SEND_LABELS` | `发送,Send,送信,Senden,Envoyer,Enviar` | cua-driver 通道识别「发送」按钮用的文字 |

## 开发

```bash
python3 -m unittest discover -s tests -v   # 离线测试，用假的 CODEX_HOME
claude plugin validate --strict .
```

## 许可证

[MIT](LICENSE)
