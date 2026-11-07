<img src=".claude-plugin/icon.png" width="96" alt="agent-courier icon">

# agent-courier

[English](README.md)

**Courier（投递）**：向 macOS 上指定的 **Codex 或 Claude Code 会话**投递消息，再读本地会话记录确认送达和回复。Codex 界面通道在后台操作，不抢键盘和鼠标焦点。

> 这是非官方的社区项目，和 OpenAI、Anthropic 没有关联，也没有得到它们的认可或支持。「Codex」「ChatGPT」「Claude」是各自所有者的商标。

## 原理

- **前端发送**：Agent 通过 macOS 的辅助功能接口在后台操作：切到 Codex App 里的目标会话，写入输入框，再点发送。任意会话都能投，包括新建会话。
- **后端核对**：直接只读 `~/.codex` 里的会话记录。核对送达、读回复都只要几行文字，不用截图。
- **身份令牌**：发送时第一行写 `【投递】<发送方>·<编号> → <收件方>·<编号>`，回复时第一行用 `【回复】` 反向写两个令牌，谁发给谁一眼就能看清。

| 通道 | 工具 | 能投到哪里 | 截图 |
| --- | --- | --- | --- |
| 前端主通道 | Claude Computer use（后台 `app_*` 工具） | Codex App 里的任意会话，包括新建会话 | 写入或点击前截一张 0.1 倍的小图 |
| 前端备用通道 | Swift 原生 macOS AX 控件操作，配合 [cua-driver](https://github.com/trycua/cua) 发现屏上窗口 ID，再按 ID 绑定 AX 窗口（`ui-*` 命令） | 同上 | 不截图 |
| 命令行兜底 | `codex exec` | 新建会话，以及 App 从没加载过的会话 | 不截图 |
| Claude 会话发送 | 同一个 `claude -p` 进程先 `ListAgents`，再至多一次 `SendMessage` | 按完整 CLI 会话 ID 确认本机 Claude Desktop 会话，再以唯一完整标题发送 | 不截图 |

## 安全设计

- 不覆盖草稿：输入框里只要不是占位文字，就停下来问你。
- 原生 AX 备用通道要求完整会话 ID 和精确标签标题，点击发送前再核对标签与草稿；没有身份抬头的消息直接拒发。
- 只在后台操作：不接管全屏、不碰剪贴板、不点链接。
- 碰到资金、凭据、改规则、不可逆操作，或者迟迟没有进展，就停下来交还给你。

## 可选投递小鸟浮层（macOS）

浮层**默认关闭**。构建后运行 `python3 -I skills/courier/scripts/courier.py overlay on` 启用，`overlay off` 立即收起浮层，`overlay status` 查看保存值与生效值。面板复选框写入同一份本地设置。`COURIER_OVERLAY=0` 或 `1` 可临时覆盖。关闭时投递不会启动浮层、为视觉读取 rollout 或写入配对记录，已断开仍拦投。

圆圈标记配对的两条侧栏会话，虚线连接两端。实心鸟表示正在投递或处理，空心鸟表示空闲，灰鸟表示已断开。点击菜单栏小鸟可查看配对、关联或断开，并清理失效记录。物理点击穿透、焦点连续性和真实拖窗跟随由 fenn 本人验收。

运行 `sh overlay/build.sh` 构建 SkyLight/Core Animation 浮层。绘制进程不链接 AppKit；18 × 14 pt 的透明小鸟完全由 Swift 方格路径生成，展翅、收翅和左右镜像交给 Core Animation，不加载鸟的图片文件。稳定安装需签名身份，并将 `tech.marave.courier-overlay` 固定安装到 `~/Applications/courier-overlay.app` 后由 fenn 开启辅助功能；本机尚无签名身份，安装未验收。未授权时小鸟隐藏且不弹窗。进程只在有配对时运行，空配对约 3 秒退出；同一进程自绘小鸟图标，点击时按需启动独立 AppKit 配对面板。当前图标点击依赖系统已有的输入监控授权，未获授权时不会请求新权限，图标不可点击。面板提供显示开关、逐对关联/断开和退出；登录时启动使用 `SMAppService.mainApp`，默认关闭；无签名身份时无法实机验证注册。断开状态写入 `$COURIER_STATE_DIR/overlay/links.json`，投递退出码 5。

每对使用一个覆盖连线与两端圆圈的透明 CA 窗口，通过空事件区域设置点击穿透；没有移动鼠标的调用。物理点击与 key window 仍需桌面实测。浮层进程通过 AX 定位侧栏会话行。查找规则：Codex 在 `AXList` 下找五位编号开头的 `AXButton`；Claude 在 `AXWebArea` 下找四位编号开头且位于左侧 320 pt 内的 `AXButton`。重复 frame 去重，只取屏幕与滚动区可见行，再用行内标题 `AXStaticText` 的 frame 把鸟停在编号首字左侧；如果圆圈会越过窗口左边缘，就把圆心移到窗口内。每对画虚线、两个圈；同时显示的最多 10 对获得 10 种不同的线色，实心鸟身体和空心鸟描边与其圈线同色，断开时鸟变灰。飞行 2.5 秒，翅膀在展开和收起两态切换，飞行与落点使用 CAEmitterLayer 粒子，减弱动态效果时不发粒子。最多显示最近活跃的 10 对，其他配对保留在面板。AXObserver 驱动重定位，结果记入 `$COURIER_STATE_DIR/overlay/locate.log`；任一端看不到就隐藏。菜单开关写入 `$COURIER_STATE_DIR/overlay/config.json`。

Claude Computer use 发送前先运行 `python3 -I skills/courier/scripts/courier.py overlay check --from 'Claude Code·0064' --to 'Codex·00165'`；退出码 5 时停止投递，再运行 `overlay pair --from ... --to ... --state sending`。Codex→Codex 也支持。原生 App 监听 Codex rollout 文件并推进状态，Python 控制命令一次性退出；`watch`、`verify`、`wait` 也会更新。`COURIER_OVERLAY=0` 关闭浮层但不绕过断开门禁。DSH 属于第二期。

按需配对面板按 App 分组，展示会话标题、收发方向、对端、状态和最后往来时间。`courier.py overlay list [--json]` 与面板、浮层共用原生会话目录。明确归档或不存在的配对进入「已失效」并停止绘制，索引读不到时保留编号、不判失效；清理在 state.lock 下只删除指定失效配对及其断开记录。

## 安装

**Claude Code**（插件）：

```bash
claude plugin marketplace add Maravetech/agent-courier
claude plugin install agent-courier@courier-marketplace
```

**任意 Agent，通过 [skills.sh](https://skills.sh)**（Vercel 的 `skills` 命令行，要求 Node 22.20 及以上）：

```bash
npx skills add Maravetech/agent-courier --skill courier -g          # 交互选择装到哪些 Agent
npx skills add Maravetech/agent-courier --skill courier -g -a codex -y
```

**其他 Agent**（Codex、OpenClaw、Hermes 等读技能目录的 Agent）：

```bash
git clone https://github.com/Maravetech/agent-courier
cd agent-courier && ./install.sh          # 把 skills/courier 软链到 ~/.agents/skills 等目录
./install.sh --check                      # 只检查，不改动
```

然后对照 **[PREREQUISITES.md](skills/courier/PREREQUISITES.md)** 逐项检查：macOS 授权、打开 Computer use、批准 Codex 访问、命令行登录、自检。不要跳过。

## 快速示例

```bash
C=skills/courier/scripts/courier.py
python3 -I $C find 00159                                  # 查会话 ID
python3 -I $C compose --from-agent "Claude Code" --from-session 0007 \
  --to <ID> --file body.txt --out msg.txt                 # 加身份抬头
# 用 Computer use 发送 msg.txt，或走备用通道：
python3 -I $C ui-switch "<完整标题>" && python3 -I $C ui-send --file msg.txt --session-id <ID> --expect-tab "<完整标题>"
python3 -I $C verify <ID> --text "<片段>" --since <UTC 时间>
python3 -I $C wait <ID> --text "<唯一投递片段>"
python3 -I $C watch <ID>             # 持续输出开工、完成、中止、等待确认
```

`ui-send` 只用于索引中已有的会话；新建会话用 Computer use 或 `send --new`。`find`、`status`、`verify`、`wait`、`watch` 按会话 ID 汇总所有 rollout 分段，按事件时间读取，包含文件名带 `_分段ID` 后缀的记录。`wait` 以匹配到的投递消息为锚，即使回合已结束也能返回；中止或抬头不符会返回非零。离线测试不代表真实 Codex 界面已经送达。

**Codex → Claude Code：**先用 `--app claude find <编号或完整标题>` 找到完整 CLI 会话 ID，用 `status <ID> -n 0` 查看状态；再用 `--app claude compose --from-agent Codex --from-session <五位编号> --to <Claude ID> --file body.txt --out msg.txt`，执行 `--app claude send <完整 Claude CLI 会话 ID> --file msg.txt`，最后依次 `--app claude verify <ID> --text <唯一标识>`、`--app claude wait <ID> --text <唯一标识>`。发送命令只接受完整 ID，以核对本机元数据和账号；真正的 `SendMessage` 收件地址是唯一的完整标题。同一个 `claude -p` 进程先调用 `ListAgents`，只有恰好一条同名且标为 `Claude Desktop session` 的会话时，临时工具门禁才允许至多一次 `SendMessage`，并核对收件标题和正文逐字一致。远程或云端重名则拒发。目标正在运行也可发送，消息可能排队。返回 0 仅表示工具成功并返回 `msg_id`；`verify` 读回目标本地记录证明送达，`wait` 再核对回复。Claude 回复首行须是 `【回复】Claude Code·NNNN → Codex·NNNNN`，并用 courier 投回发起的 Codex 会话；完整往返见 [SKILL.md](skills/courier/SKILL.md)。

投递对象只认桌面 App：Codex 按 `com.openai.codex` 绑定原生窗口，Claude 只指向本机 Claude Desktop 会话。浏览器扩展、网页版 ChatGPT/Codex、远程或云端会话都不作投递目标。DSH 由 CrossLab 的 `codex-relay` / `claude-relay` 按编号投进 DSH App 会话，不走 courier。

新会话用 `locate` 取得 ID 后，先运行 `wait-number <ID> --timeout 90`，等标题出现唯一的五位编号；超时返回「编号未就绪」。首条 `Codex·新建` 投递前即使有引导用的用户消息，只要此前没有带抬头的投递或助手回复，`wait` 仍接受新建令牌。

`ui-switch` 和 `ui-send` 默认等 Codex 离开前台最多 30 秒，可用 `--front-timeout <秒>` 调整。Codex 始终在前台时不切页、不写入；原生桥接在 AX 操作前再次核对。切页途中 Codex 转到前台就中止，并尽力恢复原标签页；恢复无法确认时明确报出。

前台判断优先读 macOS `NSWorkspace.frontmostApplication`。Chrome 等其他 App 即使有多个进程同时标成 active，也不会因此阻断后台 Codex 投递；确认 Codex App 在前台时仍等待或拒发。

`ui-send` 写入后若未能点发送，只在原窗口、原标签页和输入框仍是本次写入全文时清空并报告「已还原」。若标签或内容变化，报告「未还原」，必须先在 App 核对再重试；不会清掉别人的新草稿。发送按钮与当前标签页都从绑定的原生 AX 窗口核对。

`verify` 默认最多轮询 30 秒，因为发送返回后会话记录可能延迟写入。只查一次时传 `--timeout 0`。

`send --new` 不会设置 Codex App 会话标题，也不能保证侧栏标题有编号。本机 `codex-cli 0.160.0` 的 `codex exec` 没有标题参数，CLI 也没有改名命令；新会话需通过受支持的 App 会话工具或 App 界面改名，再读回核对编号。不要直接修改 `~/.codex/session_index.jsonl`。首条 `Codex·新建` 投递在 App 自动生成标题后仍可用 `wait` 核验。

**原生 AX 窗口绑定：**`ui-*` 按 bundle ID 找 Codex 进程，读取该 App 自己的 `AXWindows`，优先按 WindowServer 窗口 ID 唯一匹配，必要时退回位置和尺寸唯一匹配。当前标题、侧栏按钮、输入框、发送按钮及还原都限制在该窗口内。Codex 26.1029 的当前标题来自「聊天工具栏」中的静态文字，必须与 AXWindow 标题一致；旧版 AXRadioButton 仍兼容。缺标题、标题不一致、窗口或关键控件不唯一时拒绝。同一窗口中完整标题相同的多个侧栏按钮可点第一个，切页后最多轮询 3 秒核对实际标题。目标按钮缺席且「最近」分区折叠时，`ui-switch` 会展开、切页并折回；折回不能读回确认则返回非零，不得继续发送。输入框就绪但按钮缺席会单独报「目标会话按钮不存在（侧栏分区可能折叠）」，与加载超时区分。多个屏上窗口时传 `--window-id <ID>`。旧 CuaDriver 快照虽然会出现重复的 `AXWindow` 根节点，现版 `ui-*` 不用其树选控件。冷启动先尝试 `AXManualAccessibility` 并轮询工具栏和输入框；当前 App 对该属性返回不支持（AXError -25205），超时后做一次只读、过滤的 CuaDriver 快照来唤起 Electron 辅助功能，再用原生 AX 重试；再次超时则在写入前拒绝。

Codex 闲置后若暂时读不到匹配的 `AXWindows`，桥接先做一次只读、按工具栏过滤的 CuaDriver 窗口快照，再重试窗口绑定。重试仍无匹配就拒绝；出现多个匹配时也不猜测目标窗口。

2026-11-05 已在隔离测试会话实发单行、多行，各自通过 `verify`、`wait`，前台 App 保持不变。空输入框的 AXValue 占位提示带一个换行；失败还原时写入空字符串，再核对发送按钮消失，不能把占位提示当成草稿写回。

`ui-tab`、`ui-switch`、`ui-send` 共用 `$COURIER_STATE_DIR` 下的跨进程 Codex 界面锁，避免多个进程同时操作同一个 Codex 窗口。锁记录持有者 PID 与命令，进程退出即释放；默认 10 秒超时，可用 `--lock-timeout <秒>` 调整。只有使用同一状态目录的本版 courier 进程会遵守该锁；直接调用 cua-driver 或仍用旧插件的 Agent 不受约束。发送前还会核对抬头收件编号与当前标签页编号。

原生 AX 桥接首次用 `swiftc` 编译，二进制缓存在 `~/Library/Caches/agent-courier`，后续 `ui-*` 命令复用。缓存文件名含 Swift 源码 SHA-256；复用前检查私有目录、仅本人可读写执行的权限以及二进制校验清单。源码或缓存被改动时重编；编译或缓存不可用时退回解释执行，不运行未通过校验的旧二进制。

停在「新聊天」首页时，如果输入框已加载但没有打开会话，`ui-tab` 会拒绝并提示「当前在首页，没有打开会话」。输入框尚未加载的冷启动仍提示加载超时。`ui-*` 异常现在显示具体的安全原因（例如界面锁超时及持有者 PID）；CuaDriver 的原始输出可能带窗口私密文字，因此不会原样打印。

`wait` 会忽略完整、结构化的 Codex 问答控制封套（如 `<send_user_message_question_reply>`）和环境、外部上下文注入；投递后的普通用户新消息仍判为 `interleaved`。rollout 没有能区分「人工消息完整仿造控制封套」的独立来源标记，因此这一极少见情形无法仅靠记录辨别。

## 环境要求

macOS、Codex 桌面 App、Python 3.8 及以上（只用标准库）；备用 `ui-*` 通道还需要 Swift 命令行工具和 cua-driver。可选：带 Computer use 的 Claude 桌面 App、Codex 命令行。实测过的版本见 [PREREQUISITES.md](skills/courier/PREREQUISITES.md)。

## 配置

| 变量 | 默认值 | 含义 |
| --- | --- | --- |
| `CODEX_HOME` | `~/.codex` | Codex 会话记录所在目录 |
| `COURIER_STATE_DIR` | `~/.local/state/courier` | 命令行通道日志与 Codex 界面写锁目录 |
| `COURIER_AGENTS` | 任意合规名称 | 发送方白名单，逗号分隔 |
| `COURIER_SEND_LABELS` | `发送,Send,送信,Senden,Envoyer,Enviar` | 原生 AX 通道识别「发送」按钮用的文字 |

## 开发

```bash
python3 -m unittest discover -s tests -v   # 离线测试，用假的 CODEX_HOME
claude plugin validate --strict .
```

参与贡献请先读 [CONTRIBUTING.md](CONTRIBUTING.md)，并遵守 [行为准则](CODE_OF_CONDUCT.md)。安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证

[MIT](LICENSE)
