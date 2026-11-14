# Hover Translator

Godot 编辑器悬停翻译插件：鼠标划过英文，立即显示中文并朗读。

安装后即可使用。查词、联网翻译、朗读都是自动的，**不需要 AI**。

支持 **Windows / macOS / Linux** 桌面版 Godot 编辑器；Android / iOS / Web 版会在启用时自动拦截并提示，不会加载面板。

## 安装

把 `addons/hover_translator` 复制到你的 Godot 项目，然后在
`项目 → 项目设置 → 插件` 启用 **Hover Translator**。

## 用法

鼠标放在要翻译的目标上，翻译器会自动翻译并读出内容，安装完后底部会出现 **划词翻译** 这个选项，点击它可以开启或关闭某一项功能，或者查看一些属性 （嫌弃这个插件读着太吵了的，或者嫌弃这个框框的交互逻辑，讨厌这个框框，都可以在这里更改）(*/ω＼*)

## 语音

- **Windows**：默认“先 Windows 系统语音再 Edge”，没装 Python 也能出声。
- **macOS**：默认使用系统原生 `say`，不需要 Python，也不会生成音频文件。
- **Linux**：默认使用 `spd-say`（speech-dispatcher）或 `espeak-ng` / `espeak`。

想要 Edge TTS 的音色时再安装（可选）：

```bash
python3 -m pip install --user edge-tts
```

Windows 也可以用面板里的 **安装语音环境** 一键安装 Python + edge-tts。第一次遇到新词会生成 MP3，之后使用本地缓存。

## 词库维护（可选，不影响使用）

这一节不是使用前提，普通用户可以直接跳过。

翻译器会自动查本地词库；本地没有时走联网翻译，并把新词放进“待审”队列。这里的 AI 只负责“词库管理员”的整理工作：把译文和分类确认好，减少以后重复联网，让同一个词在不同界面里的翻译更一致。

如果想让 AI 批量审核，让它先读：

```text
addons/hover_translator/AI_CLASSIFICATION.md
```

文档里已经要求 AI：**不要一步步手改 JSON，直接给出一整条可复制运行的 PowerShell 脚本。** 脚本含中文，保存成 `.ps1` 时用 UTF-8 with BOM，或者直接粘贴到 PowerShell 窗口运行。

## 词库位置

插件目录里的 `data/` 只是种子；运行时词库在：

```text
Windows: %USERPROFILE%\AppData\LocalLow\HoverTranslator\data\
macOS:   ~/Library/Application Support/HoverTranslator/data/
Linux:   ${XDG_DATA_HOME:-~/.local/share}/HoverTranslator/data/
```

审核文件在对应目录的 `review/online_review.json`。

最后如果喜欢的话就点个⭐吧   ❤️❤️❤️
