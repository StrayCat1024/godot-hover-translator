# 审核前先读我

完整规则在插件目录的 `AI_CLASSIFICATION.md`。这里只放最短版本。

## 给 AI 的输出格式

不要给“打开文件、找到某行、手动改”的步骤，也不要给零散 JSON 片段。  
只输出一个 `powershell` 代码块，直接给用户**一整条可复制运行的 PowerShell 脚本**：备份 → 读取 → 批量修改 → 校验 → 写回。

脚本里必须：

- 用 `[IO.File]::ReadAllText(..., [Text.Encoding]::UTF8)` 读
- 用 `[IO.File]::WriteAllText(..., [Text.UTF8Encoding]::new($false))` 写
- 脚本含中文，保存成 `.ps1` 时用 **UTF-8 with BOM**，或直接粘贴到 PowerShell 窗口运行
- 保留备份
- 写完再用 `ConvertFrom-Json` 校验
- 不要用 `Set-Content` / `Out-File` 默认编码

不确定的词保持 `pending`，不要 `approved`。

## bucket 只能填四个

```text
main
godot_api
custom_api
grammar
```

## 决策顺序

1. 先判断上下文是不是 code。
2. code 里：
   - GDScript 关键字/运算符 → `grammar`
   - Godot 引擎类/API/属性/虚方法 → `godot_api`
   - 用户自己定义的变量/函数/类/属性/信号 → `custom_api`
3. 非 code → `main`
4. 拿不准 → 保持 `pending`，不要 `approved`。

## 只改三个字段

```json
"zh": "正确中文",
"bucket": "godot_api",
"status": "approved"
```

不要改 `en`、key、`kind`、`context`，不要重复造条目。

## 记住

- 首字母大写不一定是 Godot API；`class_name MyPlayer` 是 `custom_api`。
- 检查器属性 `Transform` / `Physics Interpolation` 是 `godot_api`。
- `if` / `var` / `await` 是 `grammar`。
- `player_speed` / `health_changed` 是 `custom_api`。
- 长句 tooltip、菜单、按钮、文件类型说明 → `main`。
- 主词库不会被在线结果自动写入，只有 `tmp_other` 审核通过才进 `main`。
- `approved` 后插件会自动导入；不确定就留在 `pending`。

## 真实文件位置

```text
Windows: %USERPROFILE%\AppData\LocalLow\HoverTranslator\review\online_review.json
macOS:   ~/Library/Application Support/HoverTranslator/review/online_review.json
Linux:   ${XDG_DATA_HOME:-~/.local/share}/HoverTranslator/review/online_review.json
```

插件目录里的 `data/` 只是种子，不要改错。
