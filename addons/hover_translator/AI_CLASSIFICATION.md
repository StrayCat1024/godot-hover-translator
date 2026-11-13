# AI 词条分类与审核说明

这份说明书是给以后接手词库的 AI / 人看的。目标只有一个：**不要乱分类，不要把不确定的词直接塞进正式词库。**

---

## 0. 给 AI 的交付格式（硬性要求）

当用户让你审核、修改或新增词条时：

- **不要**输出“先打开文件、找到某一行、手动改这个字段”的分步教程。
- **不要**只给零散的 JSON 片段。
- **直接给出一整条可复制运行的 PowerShell 脚本**，一次完成：备份 → 读取 → 批量修改 → 校验 → 写回 → 打印结果。
- 脚本必须是完整可执行的，不留 `...`、`<这里填>`、`TODO` 之类占位符；需要改的内容直接写进脚本里的 `$changes` 数组。
- 只输出一个 `powershell` 代码块。不要在同一条回复里给多个互不完整的脚本。
- 不要用 `Set-Content` / `Out-File` 的默认编码写 JSON，会把中文写坏；必须用 `[IO.File]::WriteAllText(..., [Text.UTF8Encoding]::new($false))`。
- 不确定的词不要 `approved`，留在 `pending`；脚本里也不要替用户猜。

推荐脚本骨架：

```powershell
$ErrorActionPreference = 'Stop'

$path = Join-Path $env:USERPROFILE 'AppData\LocalLow\HoverTranslator\review\online_review.json'
$backup = "$path.bak_$(Get-Date -Format yyyyMMdd_HHmmss)"
Copy-Item -LiteralPath $path -Destination $backup

$data = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json

# 只改 zh / bucket / status；key 必须和 review 文件里的 key 完全一致
$changes = @(
    @{ key = 'code|player_speed'; zh = '玩家速度'; bucket = 'custom_api'; status = 'approved' },
    @{ key = 'ui|physics interpolation'; zh = '物理插值'; bucket = 'godot_api'; status = 'approved' }
)

foreach ($c in $changes) {
    $prop = $data.entries.PSObject.Properties[$c.key]
    if ($null -eq $prop) { throw "找不到词条：$($c.key)" }
    $entry = $prop.Value
    if ($c.zh) { $entry.zh = $c.zh }
    $entry.bucket = $c.bucket
    $entry.status = $c.status
}

$out = $data | ConvertTo-Json -Depth 20
[IO.File]::WriteAllText($path, $out, [Text.UTF8Encoding]::new($false))

# 写回后立即校验，坏 JSON 会在这里直接报错
$null = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json

Write-Host "OK：已更新 $($changes.Count) 条；备份：$backup"
```

如果用户要改的是正式词库而不是审核文件，也按同样原则：**一条完整 PowerShell 脚本**，包含备份、UTF-8 读写和结果校验。

注意 key 是 `kind|en.to_lower()`，所以 `Physics Interpolation` 的 key 是 `ui|physics interpolation`，不要写成大写。

---

## 1. 词库结构

```text
code语法（父类，不是单独文件）
  ├─ godot_api      Godot API / 类 / 属性名
  ├─ custom_api     用户自定义 API / 类 / 属性名
  └─ grammar        GDScript 语法关键字 / 运算符

main                主词库：非 code 的 UI / 通用词

tmp（待审）
  ├─ code           code 上下文中没命中的
  └─ other          非 code 上下文中没命中的
```

对应的 bucket 值只有这四个：

```text
main
godot_api
custom_api
grammar
```

`tmp_code` / `tmp_other` 只是暂存，**不是**审核后的正式 bucket。

---

## 2. 先判断：是不是 code

当前插件的判定沿用 `kind`：

- 脚本编辑器 `TextEdit` / `CodeEdit` → code
- 检查器属性行、检查器分区 → code
- 场景树 / 文件树里的节点名、类名 → code
- 菜单、按钮、Tab、普通 Label、文件类型、普通提示 → 非 code

以后如果收紧成“只有脚本编辑器窗口才算 code”，以新版本代码为准，不要按旧记忆硬套。

---

## 3. 分类决策树

### 3.1 code 上下文

按顺序判断：

1. **语法 `grammar`**
   - GDScript 关键字、运算符、字面量：
   - `if` `elif` `else` `for` `while` `match` `when`
   - `break` `continue` `pass` `return`
   - `func` `var` `const` `class` `class_name` `extends`
   - `super` `self` `signal` `await` `static` `enum`
   - `export` `onready` `setget`
   - `is` `in` `as` `and` `or` `not`
   - `true` `false` `null` `void`
   - `setter` `getter` `virtual` `statement` `breakpoint`

2. **Godot API / 类 / 属性 `godot_api`**
   - 引擎类：`Node2D`、`Sprite2D`、`CharacterBody2D`、`Control`
   - 引擎方法/函数：`add_child`、`queue_free`、`get_viewport_rect`、`set_process`
   - 引擎属性/检查器属性：`Transform`、`Visibility`、`Texture`、`Physics Interpolation`、`Autowrap`
   - 引擎虚方法/生命周期：`_ready`、`_process`、`_physics_process`、`_input`、`_draw`
   - 引擎内置类型：`Vector2`、`Vector3`、`Color`、`Array`、`Dictionary`、`Callable`
   - 引擎信号/枚举：`Timer.timeout`、`Tween.finished`、`PropertyHint`

3. **用户自定义 API / 类 / 属性 `custom_api`**
   - 自己起的变量/函数/类/属性/信号：
   - `player_speed`、`my_node`、`calculate_damage`
   - `class_name MyPlayer` 里的 `MyPlayer`
   - `signal health_changed` 里的 `health_changed`
   - 自定义属性 `enemy_count`、`is_alive`
   - 注意：**首字母大写不等于 Godot API**。看到 `class_name MyPlayer` 或上下文明显是用户定义，就选 `custom_api`。

4. 拿不准：
   - 留在 `pending`，不要 `approved`。
   - 不要为了“看起来完整”硬猜。

### 3.2 非 code 上下文

- 菜单、按钮、Tab、文件类型、普通 UI 文案、通用词 → `main`
- 长句/整段 tooltip 说明 → `main`
- 文件扩展名说明（`.tscn`、`.gd` 等）→ `main`
- 非 code 的普通英文术语 → `main`

### 3.3 检查器特例

检查器里的**属性行和分区标题**，即使插件当前把它标成 `kind=ui`，也优先按 `godot_api` 处理：

- `Transform` → `godot_api`
- `Physics Interpolation` → `godot_api`
- `Visibility` → `godot_api`
- `Texture` → `godot_api`

只有检查器里的普通说明文字、按钮文案才考虑 `main`。

---

## 4. 示例表

| 原文 | 上下文 | bucket |
|---|---|---|
| `Transform` | 检查器属性 | `godot_api` |
| `Physics Interpolation` | 检查器分区 | `godot_api` |
| `add_child` | 脚本 API | `godot_api` |
| `queue_free` | 脚本 API | `godot_api` |
| `Sprite2D` | 引擎类 | `godot_api` |
| `_ready` | 引擎虚方法 | `godot_api` |
| `if` | GDScript 关键字 | `grammar` |
| `await` | GDScript 关键字 | `grammar` |
| `player_speed` | 用户变量 | `custom_api` |
| `calculate_damage` | 用户函数 | `custom_api` |
| `MyPlayer` | `class_name` 用户类 | `custom_api` |
| `health_changed` | 用户自定义信号 | `custom_api` |
| `enemy_count` | 用户属性 | `custom_api` |
| `Physics Interpolation` | 只是普通 UI 文案（非检查器） | `main` |
| `Auto Translate` | 项目设置 UI | `main` |
| `Scene File` | 文件类型说明 | `main` |

---

## 5. 审核文件

真实审核文件：

```text
%USERPROFILE%\AppData\LocalLow\HoverTranslator\review\online_review.json
```

插件目录里的 `data/` 只是首次启动的种子；真正生效的词库在：

```text
%USERPROFILE%\AppData\LocalLow\HoverTranslator\data\
```

不要改错地方。

### 5.1 条目格式

```json
"code|player_speed": {
  "en": "player_speed",
  "zh": "玩家速度",
  "kind": "code",
  "context": "var player_speed = 300.0",
  "bucket": "custom_api",
  "suggested_bucket": "custom_api",
  "status": "pending",
  "source": "MyMemory",
  "count": 1,
  "first_seen": "2026-11-13T15:00:00",
  "last_seen": "2026-11-13T15:00:00"
}
```

key 规则：`kind|en.to_lower()`。**不要改 key，不要改 `en`**，否则会对不上 tmp。

### 5.2 AI 只改这些字段

- `zh`：改成正确中文
- `bucket`：改成四个正式 bucket 之一
- `status`：
  - `approved`：确认，插件会自动导入
  - `rejected`：拒绝，插件会从 tmp 删除
  - `pending`：拿不准，保留待审

不要改：

- `en`
- `kind`
- `context`（除非明显错）
- `source`
- `count`
- `first_seen` / `last_seen`
- 已经是 `applied` 的条目

### 5.3 审核规则

- **不确定就不要 approved。**
- 不要给同一个 `kind|en` 造重复条目。
- 不要在审核文件里写注释；保持合法 JSON。
- 不要手动把词直接写进 `main_zh.json` / `code/*.json` 来绕过审核；除非你明确知道自己在做迁移。
- `approved` 后插件每 2 秒检查一次，自动写入正式词库并清掉 tmp；也可以点“导入审核结果”。
- 主词库 `main` **永远不会**被在线结果直接写入，只有 `tmp_other` 审核通过才会进 `main`。
- `tmp_code` 审核通过只能进 `godot_api` / `custom_api` / `grammar`，不能进 `main`。

---

## 6. 查询优先级

- code：`godot_api` → `grammar` → `custom_api` → `tmp_code` → `main` 兜底
- 非 code：`main` → `tmp_other` → code 词库兜底

不要把 code 词条塞进 `main`，也不要把普通 UI 文案塞进 `grammar`。

---

## 7. 常见错误

| 错误 | 正确做法 |
|---|---|
| 看到首字母大写就判 Godot API | 看 `class_name` / 上下文，用户类进 `custom_api` |
| 把 `if`、`var` 放进 Godot API | 进 `grammar` |
| 把 `player_speed` 放进 Godot API | 进 `custom_api` |
| 把 `Physics Interpolation` 放进主词库 | 检查器属性进 `godot_api` |
| 把长句 tooltip 放进 code 词库 | 进 `main` |
| 不确定也 approved | 保持 `pending` |
| 改 `en` 或 key | 不改，重开新条目 |
| 改 addon 里的种子文件 | 改 LocalLow 里的真实词库 |

---

## 8. 一句话总结

**先看上下文是不是 code；code 里再分“语法 / Godot API / 自定义 API”；非 code 才进主词库；拿不准就留在 tmp，不要 approved。**
