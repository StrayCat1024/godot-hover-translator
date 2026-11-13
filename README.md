# Hover Translator

Godot 编辑器悬停翻译插件：鼠标划过英文，立即显示中文并朗读。

## 安装

把 `addons/hover_translator` 复制到你的 Godot 项目，然后在
`项目 → 项目设置 → 插件` 启用 **Hover Translator**。

## 语音依赖

默认使用外部 Edge TTS（统一男声 `en-US-GuyNeural`）：

```bash
python -m pip install edge-tts
```

第一次遇到新词会生成 MP3，之后使用本地缓存。

## AI 词库分类

以后接手词库的 AI 请先读：

```text
addons/hover_translator/AI_CLASSIFICATION.md
```

## 词库位置

插件目录里的 `data/` 只是种子；运行时词库在：

```text
%USERPROFILE%\AppData\LocalLow\HoverTranslator\data\
%USERPROFILE%\AppData\LocalLow\HoverTranslator\review\online_review.json
```
