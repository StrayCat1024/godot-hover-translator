# Hover Translator（Godot 编辑器悬停翻译）

给 **Godot 编辑器本体** 用的插件：鼠标划过英文，立即出现一个独立的小卡片，显示中文并朗读英文。

不修改引擎源码，不依赖原生 tooltip 的延迟，也不会去翻译游戏运行时或 Debugger 的输出。

## 覆盖范围

- 检查器：`Transform`、`Visibility`、`Texture`、`Material`、`Physics Interpolation` 等分区和属性行
- 场景树 / 文件系统：节点名、类名、文件名
- 菜单、按钮、Tab、下拉菜单、对话框、底部面板
- 脚本编辑器 `CodeEdit`：`add_child`、`queue_free`、`Sprite2D`、`get_viewport_rect` 等
- 中文界面下没有英文文本的自绘分区标题：通过编辑器自身的中文 tooltip 反查英文，再显示中文

## 安装 / 启用

插件目录：

```text
addons/hover_translator/
```

在 Godot 中打开：

```text
项目 → 项目设置 → 插件 → Hover Translator → 启用
```

然后重启编辑器（或 `项目 → 重新加载当前项目`）。

启用后，编辑器底部会出现 **“划词翻译”** 面板。把鼠标移到英文上即可，不需要悬停等待。

## 设置

在 **项目设置 → Hover Translator** 中：

| 设置 | 默认值 | 说明 |
|---|---|---|
| `enabled` | `true` | 总开关 |
| `speak` | `true` | 悬停时朗读英文 |
| `show_card` | `true` | 显示翻译浮窗 |
| `follow_mouse` | `true` | 浮窗跟随鼠标 |
| `rate` | `0` | 语速，-10 ~ 10 |
| `volume` | `100` | 音量，0 ~ 100 |
| `voice` | `Microsoft Zira Desktop` | Windows 英文语音名 |
| `online_fallback` | `true` | 本地词典没命中时联网翻译 |
| `online_voice` | `true` | 使用外部 Edge 在线语音 |
| `auto_apply_review` | `true` | 审核文件出现 `approved` 时自动导入词库 |
| `online_timeout` | `8` | 联网超时秒数 |
| `online_url` | MyMemory | 在线翻译接口模板 |
| `online_voice_name` | `en-US-GuyNeural` | Edge 音色；默认统一男声 |

也可以直接在“划词翻译”底部面板里调整语速、语音、开关和测试。

## 词库维护（可选，不影响使用）

先说明：**日常查词、联网翻译、朗读都不需要 AI，也不需要看这一节。** 插件装好就能直接用。

这里的 AI 只负责“词库管理员”的工作：某个词本地没有、走了联网翻译后，插件会把它放进“待审”队列；AI 负责把译文和分类整理好，减少以后重复联网，让同一个词在不同界面里的翻译更一致。

如果你只是使用插件，这一段可以完全跳过。

完整分类规则见 [`AI_CLASSIFICATION.md`](AI_CLASSIFICATION.md)。审核文件旁边也会自动放一份简版 `AI_REVIEW_GUIDE.md`。给 AI 的文档里已经要求：**不要一步步手改 JSON，直接给出一整条可复制运行的 PowerShell 脚本。**

## 翻译数据

词库分四层，code 下面再分三个子类：

```text
data/
  main_zh.json                 主词库：非 code 的 UI / 通用词
  code/
    godot_api_zh.json          Godot API / 类 / 属性名
    custom_api_zh.json         用户自定义 API / 类 / 属性名
    grammar_zh.json            GDScript 语法关键字 / 运算符
  tmp/
    code_zh.json               待审：code 里没命中的
    other_zh.json              待审：非 code 没命中的
review/
  online_review.json           原文 + 译文 + 上下文，给 AI 审核
```

插件目录里的 `data/` 只是**首次启动的种子**；运行时真正读写的是：

```text
%USERPROFILE%\AppData\LocalLow\HoverTranslator\data\
%USERPROFILE%\AppData\LocalLow\HoverTranslator\review\online_review.json
```

这样做是因为 Godot 可能以低权限/沙箱进程运行，写不了项目目录。面板里的 **“打开词库目录”**、**“打开审核文件”** 会直接打开真实路径。

查询顺序：

- **code**：Godot API → 语法 → 自定义 → 待审 code → 主词库兜底
- **非 code**：主词库 → 待审其他 → code 词库兜底

本地词库命中时是 O(1)，立即显示，不联网。

本地没命中时：

1. 先显示“正在联网翻译…”；
2. 后台请求 MyMemory 免费接口；
3. 返回后把 **原文、译文、上下文** 写进 `review/online_review.json`；
4. 同时写进 `tmp/code_zh.json` 或 `tmp/other_zh.json`，卡片标记“待审”；
5. 第二次再划到同一个词，直接命中 tmp，不再联网。

AI 审核时修改 `online_review.json` 里的 `zh`，把 `bucket` 改成：

- `main`：进主词库
- `godot_api`：进 Godot API/类/属性
- `grammar`：进语法
- `custom_api`：进自定义 API/类/属性

然后把 `status` 改成 `approved`。插件每 2 秒检查一次审核文件，发现 `approved` 会自动导入对应词库；也可以手动点 **“导入审核结果”**。主词库不会自动添加，只有审核通过的 `tmp/other` 才会进 `main`。

代码标识符会先拆词（`get_viewport_rect` → `get viewport rect`）再请求，避免把下划线当成一个单词。

## 音频实现

优先使用外部 **Edge TTS**：插件调用 `python -m edge_tts` 生成 MP3，默认音色 `en-US-GuyNeural`（统一男声），再用 Godot 的 `AudioStreamPlayer` 播放。这样不经过 SAPI，也不调用会崩溃的 `DisplayServer.tts_*`。

- 第一次划到某个词：后台生成 MP3，通常约 1 秒；
- 播放后缓存到：
  `%USERPROFILE%\AppData\LocalLow\HoverTranslator\tts_edge\<hash>.mp3`
- 第二次划到同一个词：直接读本地 MP3，零生成延迟；
- 需要本机 Python 和 `edge-tts`：
  `python -m pip install edge-tts`
- 如果想换音色，改 `online_voice_name`，例如 `en-US-AriaNeural`（女声）、`en-GB-RyanNeural`（英式男声）。

SAPI 只在关闭 `online_voice` 时作为离线备选。如果 Godot 在 **低完整性 / 沙箱进程** 中启动，Windows 会拒绝 SAPI 访问（日志里是“没有当前安全设置可用的语音”或 `Access denied`），这时保持 `online_voice = true` 即可。

语音日志（SAPI 路径）：

```text
%APPDATA%\Godot\app_userdata\<项目名>\hover_translator_tts.log
```

如果日志里有 `READY` 和 `SPEAK:...` 但没有声音，请检查 Windows 的默认播放设备和英文语音包。低完整性环境不用管 SAPI 日志，在线语音会接管。

## 说明

- 这是编辑器插件，不是游戏内 UI；导出的游戏不会包含它。
- 原生 tooltip 会保留；检测到它出现时，翻译卡自动贴到它旁边：优先放在远离鼠标的一侧并与提示顶部对齐，侧面放不下时放到上方/下方，不再隐藏原生提示。
- 在线接口不需要 Key，但属于第三方免费服务；如果被限流，把 `online_url` 换成自己的翻译接口，或换 `online_voice_name` / 自己实现语音接口。
- 旧插件 `addons/comfycat_翻译器` 未被删除，只是不再启用。
