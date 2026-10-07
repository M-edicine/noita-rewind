# Noita Rewind（存档回溯）v5

**Save a checkpoint mid-run and jump straight back to it — terrain included.** Press `Ctrl+S` to write a real
checkpoint (the engine writes the world chunks + `world_state.xml` + `player.xml` to disk), press `Ctrl+Z` to return
to it at any time, and a **Rewind** button is also added to the death screen. All keys are rebindable in the in-game
**Mod Settings**.

一局游戏中随时存档、随时回到存档点，**地形一起回档**：`Ctrl+S` 记录存档点，`Ctrl+Z` 回到存档点，死亡结算界面里
还会多出一个「回溯」按钮。所有按键都能在游戏内的【Mod 设置】里改。

---

## 功能

- **即时存档（`Ctrl+S`，默认 Q 键可改）**：不走游戏菜单，随时记录当前这一局。
- **回溯（`Ctrl+Z`）**：回到上一个存档点，自动完成"重启并载入"的全过程，不需要你手动做任何事。
- **死亡界面「回溯」按钮**：在结算界面直接回溯（颜色、位置都按原生菜单项绘制）。
- **真正落盘的世界快照**：包含 `world` 区块文件（`world_x_y.png_petri`、`area_*.bin`、`entities_*.bin`）、
  `world_state.xml`、`player.xml`，所以回溯回去地形、道具、敌人状态都是存档点那一刻的样子。
- **按键可配置**：存档键、回溯键、修饰键都在【Mod 设置】里改；存档点按钮的位置/颜色也能在配置文件里调。
- **存档最小间隔**：默认 8 秒，避免落盘过程中重复存档（可配置、可关）。

## 安装

1. 需要正版 Windows PC 版 Noita，并在启动器里勾选 **允许不安全的 Mod / unsafe mods**。
2. 把本仓库放进游戏的 mods 目录，**文件夹名必须是 `rewind_v5`**（目录名要和 `mod_id.txt` 一致，否则游戏找不到）：

   ```
   <Steam 安装位置>\steamapps\common\Noita\mods\rewind_v5\
   ```

   用 git 安装的话，克隆时直接指定目录名：
   ```bash
   cd "<Steam 安装位置>/steamapps/common/Noita/mods"
   git clone https://github.com/<你的用户名>/<仓库名>.git rewind_v5
   ```
   不用 git 的话，把仓库里的文件下载/复制到 `mods\rewind_v5\` 下即可（要保证 `init.lua`、`mod.xml`、
   `mod_id.txt`、`settings.lua` 都在这一层）。

3. 启动游戏 → **Mods** → 勾选 **Noita Rewind v5** → 开局。

## 使用

| 操作 | 默认按键 | 说明 |
|---|---|---|
| 记录存档点 | `Q` | 游戏进行中按一下；屏幕会提示「已存档」 |
| 回到存档点 | `R` | 任意时刻按；自动重启并载入存档点 |
| 修改按键 | — | 游戏内 **Mod 设置** 里改（存档键 / 回溯键 / 修饰键） |
| 死后再来一次 | — | 死亡结算界面点「回溯」按钮 |

按键可以在【Mod 设置】里改成别的（比如原来的 Ctrl+S / Ctrl+Z；注意别和游戏本身的操作冲突）。

## 文件位置（重要）

- **mod 本体**：`...\Noita\mods\rewind_v5\`（只有 4 个静态文件，运行时不会往这里写东西）。
- **运行时数据/配置/日志**：`%USERPROFILE%\AppData\LocalLow\Nolla_Games_Noita\noita_rewind_v5\`
  - `rewind_config.txt` —— 配置（按键、按钮位置、颜色、存档最小间隔等）
  - `rewind_log.txt` —— 日志（排查问题看这个）
  - `snap\`、`snap_auto\` —— 存档点数据
- 卸载时把上面两个目录都删掉即可（游戏存档 `save00…save06` 不会被本 mod 修改）。

## 配置项（`rewind_config.txt`）

常用几项：

```
KEY_SAVE=Q            # 存档键（也可在【Mod 设置】里改）
KEY_REWIND=R          # 回溯键
KEY_MOD=none          # 修饰键（ctrl / shift / alt / none）
SAVE_COOLDOWN_MS=8000 # 两次存档的最小间隔
GUI_X=50.78 GUI_Y=70  # 死亡界面「回溯」按钮的位置
GUI_COLOR=0.816,0.812,0.804,1        # 未选中颜色（= 原生菜单的 #d0cfcd）
GUI_COLOR_HOVER=0.996,0.992,0.678,1  # 选中颜色（= 原生菜单的 #fefdad）
```

## 工作原理（简述）

Noita 没有暴露任何存档/读档的 Lua API，而且**引擎只在"保存并退出"时才把世界区块写盘**。本 mod 的做法是：

1. 用 FFI 调用引擎自己的写盘序列（先 `world_state.xml`、`player.xml`，再调世界写盘入口），让这一局真正落盘；
2. 等 `.autosave` 标记消失、文件数稳定后，把这一局的局内文件镜像到自己的存档点目录；
3. 回溯时把存档点写回游戏存档槽，然后让游戏重新载入（自动重启，无需人工操作）。

只动**局内文件**（`player.xml`、`world_state.xml`、`world\**`）；`persistent`、`stats` 等跨局数据绝不触碰。
所有补丁/调用都按"能安全失败"的方式做了校验，任何前置条件不满足时只写日志、不做动作。

## 已知问题

- **存档后画面可能出现局部空洞**（屏幕里某一块变白/空），**往那个方向走一段路就会自行恢复**。
  原因：引擎把世界写盘时会动到当前已加载区块的运行时状态，而引擎只有在玩家靠近/跨区块时才会重新流式加载。
  我们试过多条"主动请求引擎重新加载区块"的路子（每条都做了前置校验），但这些引擎内部函数不接受从 mod 侧
  这样调用（会崩），因此**没有修掉**。这是纯视觉问题，不会丢数据，也不影响存档/回溯。
- **同一时间只能启用一个 rewind**：本版与 `rewind_v3` / `rewind_v4` / `rewind_v3restored` 会争同一份存档点数据，
  别同时开。
- 本 mod 依赖 FFI 与内存读取，**只支持 Windows PC 版**。游戏大版本更新后若引擎内部代码位置变化，
  "存档落盘"这一步可能需要跟着更新（按键、回溯、按钮这些功能不受影响）。

## 兼容性

- 与 **No Mod Lock**（解除"使用 Mod 就锁成就"的限制）互不冲突，可以同时启用。
- 会直接写游戏存档槽里的局内文件，因此**不要和别的"写存档"类 mod 同时用**。

## 许可

见 `LICENSE`（上传时在 GitHub 仓库页面用 “Add file → Create new file → LICENSE” 选一个即可）。
