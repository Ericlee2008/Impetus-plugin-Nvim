# Impetus.nvim 近期修改回顾（2026-04-25）

## 一、参数跨引用视觉标记（下划线 / 波浪线）

### 1.1 需求背景

用户希望在关键字参数的 ID 字段上添加视觉标记，用于指示该参数被其他参数定义或引用：

- 例如 `*PART` 的 `pid=2` 被 `*BC_MOTION` 引用时，两处的 `2` 下方都显示下划线
- 提示用户这不是一个孤立的独立参数

### 1.2 核心实现：`lua/impetus/ref_marks.lua`

**新建模块**，基于现有 `analysis.lua` 的 `object_defs` / `object_refs` 索引，使用 Neovim **extmark** 机制：

| 标记样式      | 高亮组                  | 含义                                |
| --------- | -------------------- | --------------------------------- |
| **绿色下划线** | `ImpetusDefMark`     | 该 ID 在此处**被定义**，且至少被一处**引用**      |
| **蓝色下划线** | `ImpetusRefMark`     | 该 ID 在此处**被引用**，且存在对应的定义          |
| **红色波浪线** | `ImpetusRefMarkDead` | 该 ID 在此处**被引用**，但**找不到**对应定义（死引用） |

**关键逻辑**：

- 定义标记优先于引用标记（同一位置只显示绿色）
- 使用 `occupied` 表防止重复标记
- `update_debounced()` 对 `TextChanged/TextChangedI` 做 **400ms debounce**
- `BufEnter` 时立即更新

### 1.3 集成点

- `config.lua`：新增 `ref_marks = true` 默认配置
- `init.lua`：`setup()` 中调用 `ref_marks.setup()`，`refresh_main_visuals()` 中调用 `ref_marks.update()`
- `commands.lua`：新增 `:ImpetusRefMarksToggle`（别名 `:Crm`）全局开关

---

## 二、`analysis.lua` 中的识别规则扩展

### 2.1 `classify_def_type` — 定义识别

新增以下参数 → 对象类型的映射：

| 参数名      | 关键字                                                | 对象类型                |
| -------- | -------------------------------------------------- | ------------------- |
| `csysid` | `*COORDINATE_SYSTEM*` / `*COORDINATE_SYSTEM_FIXED` | `coordinate_system` |
| `nid`    | `*NODE`                                            | `node`              |
| `eid`    | `*ELEMENT*`                                        | `element`           |

### 2.2 `classify_ref_type` — 引用识别

新增以下参数 → 对象类型的映射：

| 参数名                                                                 | 对象类型                |
| ------------------------------------------------------------------- | ------------------- |
| `csysid`                                                            | `coordinate_system` |
| `nid` / `nid_N`                                                     | `node`              |
| `eid` / `eid_N`                                                     | `element`           |
| `range_1` / `...` / `range_K` / `range_M` / `range_N`（在 `*SET_*` 中） | 按 `*SET_*` 类型映射     |

`*SET_*` 支持：

- `*SET_PART` → `part`
- `*SET_NODE` → `node`
- `*SET_ELEMENT` → `element`
- `*SET_GEOMETRY` → `geometry`
- `*SET_FACE` → `element`

### 2.3 `parse_block_objects` — `*BC_MOTION` 硬编码处理

`*BC_MOTION` 的 schema 参数名是**示例值**（`2`, `P`, `XY`, `XYZ` 等），不是标准化参数名，导致 schema-driven 循环无法识别坐标系引用。添加硬编码处理：

| 数据行    | 字段                 | 识别为                    |
| ------ | ------------------ | ---------------------- |
| Row 1  | 字段1 (`bcid`)       | `command` 定义           |
| Row 2  | 字段5 (`csysid_tr`)  | `coordinate_system` 引用 |
| Row 2  | 字段6 (`csysid_rot`) | `coordinate_system` 引用 |
| Row ≥3 | 字段3 (`cid`)        | `curve` 引用             |
| Row ≥3 | 字段5 (`fid`)        | `curve` 引用             |

### 2.4 `parse_block_objects` — `*SET_*` 超出 schema 字段修复

`*SET_NODE` 的 schema 只有 3 个参数（`range_1, ..., range_K`），但数据行可能有 8 个节点 ID。超出 schema 的字段被跳过。

**修复**：当 `param_name` 为 nil 且 keyword 匹配 `^%*SET_` 时，回退使用**最后一个 schema 参数名**（如 `range_K`），确保整行都被识别。

### 2.5 `scan_object_defs_from_lines` — `*NODE` / `*ELEMENT_*` 多行定义修复

该函数之前只处理每个关键字的**第一行数据**。但 `*NODE` 和 `*ELEMENT_*` **每行都是一个独立定义**。

**修复**：对 `*NODE` 和 `*ELEMENT_*` 取消单行限制，处理所有数据行。

### 2.6 `scan_object_refs_from_lines` — 扩展引用扫描

之前该函数**只扫描 `fcn(id)` / `crv(id)`**。对于 include 文件中的引用扫描不完整。

**修复**：添加对以下关键字的轻量级解析：

| 关键字                   | 扫描规则                     |
| --------------------- | ------------------------ |
| `*SET_PART`           | 第2行起所有数值 → `part` 引用     |
| `*SET_NODE`           | 第2行起所有数值 → `node` 引用     |
| `*SET_ELEMENT`        | 第2行起所有数值 → `element` 引用  |
| `*SET_GEOMETRY`       | 第2行起所有数值 → `geometry` 引用 |
| `*SET_FACE`           | 第2行起所有数值 → `element` 引用  |
| `*GEOMETRY_SEED_NODE` | 第2行起所有数值 → `node` 引用     |

### 2.7 `obj_type_for_def_keyword` — 新增定义关键字

新增：` *NODE` → `node`，`*ELEMENT*` → `element`，`*COORDINATE_SYSTEM*` → `coordinate_system`

---

## 三、跨文件引用支持

### 3.1 问题

`ref_marks.lua` 最初只使用 `build_buffer_index()`（仅扫描当前 buffer）。如果定义在 include 文件中，当前 buffer 中的引用会被误判为**死引用**（红色波浪线）。

### 3.2 修复

`ref_marks.update()` 现在同时调用：

- `analysis.build_buffer_index(bufnr)` — 获取当前 buffer 的 defs/refs（知道在哪里标记）
- `analysis.build_cross_file_object_index(bufnr)` — 获取跨文件的 defs（判断引用是否有效）

判断逻辑：

- 定义标记绿色：`cross.refs[id]` 或 `idx.object_refs[id]` 存在即显示
- 引用标记蓝色/红色：`cross.defs[id]` 存在 → 蓝色，否则 → 红色

---

## 四、`*OUTPUT_SENSOR` 的 `R` 参数按需校验

### 4.1 需求

`*OUTPUT_SENSOR` 的 `R`（schema 第6字段）是否为**必需**，取决于文件中是否存在：

1. `*PARTICLE_*` 开头的关键字（如 `*PARTICLE_DETONATION`, `*PARTICLE_DOMAIN` 等）
2. 或 `*CFD_*` 开头的关键字（如 `*CFD_DETONATION`, `*CFD_BOUNDARY` 等）
- **存在**上述关键字 → `R` **必需**，缺失报 `ERROR`
- **不存在**上述关键字 → `R` **可选**，缺失不报错

### 4.2 实现

#### 步骤1：扩展 `build_cross_file_object_index` 收集关键字

返回值新增 `keywords` 字段，记录所有扫描到的关键字名称（当前 buffer + include 文件 + 其他已加载 buffer）。

```lua
return { defs = all_defs, refs = all_refs, keywords = all_keywords }
```

#### 步骤2：`lint.lua` 的 `M.run` 中检测条件

```lua
local has_particle_or_cfd = false
for kw, _ in pairs(cross_file_objects.keywords or {}) do
  if kw:match("^%*PARTICLE") or kw:match("^%*CFD") then
    has_particle_or_cfd = true
    break
  end
end
```

#### 步骤3：`check_required_fields` 中覆盖 `R` 的可选性

在 `*OUTPUT_SENSOR` 的专用分支中：

```lua
if p == "r" and not ctx.has_particle_or_cfd then
  is_optional = true
end
```

当没有 particle/cfd 关键字时，将 `R` 强制视为可选，跳过 `Missing required field` 报错。

---

## 五、`field_col_from_idx` 边界修复

### 问题

当目标字段是**行尾最后一个字段**（后面没有逗号）时，`field_col_from_idx` 循环结束后虽有 `idx == target_idx` 的检查，但曾在某次修改中被遗漏。

### 修复

确保循环结束后检查 `idx == target_idx`，正确返回最后一个字段的起始列（跳过前导空格）。

---

## 六、文件变更清单

| 文件                          | 变更类型   | 主要内容                                                                     |
| --------------------------- | ------ | ------------------------------------------------------------------------ |
| `lua/impetus/ref_marks.lua` | **新建** | 视觉标记核心模块                                                                 |
| `lua/impetus/config.lua`    | 修改     | 新增 `ref_marks = true` 配置                                                 |
| `lua/impetus/init.lua`      | 修改     | 集成 `ref_marks.setup()` 和 `update()`                                      |
| `lua/impetus/commands.lua`  | 修改     | 新增 `:ImpetusRefMarksToggle` / `:Crm`                                     |
| `lua/impetus/analysis.lua`  | 修改     | 扩展 def/ref 识别规则、修复跨文件扫描、扩展 `build_cross_file_object_index` 返回 `keywords` |
| `lua/impetus/lint.lua`      | 修改     | `*OUTPUT_SENSOR` `R` 按需校验                                                |

---

## 七、测试验证要点

1. **同文件引用**：`*PART` + `*ELEMENT_SOLID` → `pid` 双向标记正确
2. **跨文件引用**：主文件 `*SET_NODE` + include 文件 `*NODE` → 全部蓝色下划线
3. **`*GEOMETRY_SEED_NODE`**：`nid_1` / `nid_2` 跨文件引用 → 蓝色下划线
4. **`*OUTPUT_SENSOR` 无 particle/cfd**：`R` 缺失 → 不报错
5. **`*OUTPUT_SENSOR` 有 particle/cfd**：`R` 缺失 → `Missing required field 'R'`

---

# 后续更新记录（本次对话批次）

## 一、`gr` / `gd` 精度修复 — embedded `fcn(id)` 精确列计算

### 问题

`parse_block_objects` 在提取 `fcn(id)` / `crv(id)` / `dfcn(id)` 中的数字 ID 时，使用 `gmatch` 返回的是**字段内**的匹配位置。加上 `field_col_from_idx` 计算出的字段起始列后，`id_col` 的偏移量不准确，导致 `gr` 列出的下划线位置偏离实际数字。

### 修复

改用 `tv:find` 循环逐个定位匹配，再用 `match_str:find("%d+")` 精确计算数字在匹配字符串中的起始位置：

```lua
local s, e, prefix, ref_id = tv:find("(%a+)%s*%(%s*(%d+)%s*%)", search_pos)
-- ...
local match_str = tv:sub(s, e)
local id_s = match_str:find("%d+")
local id_col = field_start_col + s - 1 + id_s - 1
```

## 二、`*PARAMETER` "or" option 解析精简

### 问题

`commands.help` 中某些字段的 `options:` 包含 slash aliases（如 `mm/ton/s`），popup 显示多达 14 个选项，过于拥挤。

### 修复

`actions.lua` 中 hardcode 8 个 representative items（如 `SI`, `MMTONS`, `CMGUS` 等），popup 只展示这些。lint 侧仍然接受所有 alias。

## 三、SPH 和 DP 对象支持

### 新增类型

- `sph` — SPH 粒子定义（`*PARTICLE_SPH` 等）
- `dp` — 离散粒子定义（`*PARTICLE_HE`, `*PARTICLE_AIR`, `*PARTICLE_SOIL`）

### 修改点

- `entype_to_obj_type`：`SPH` → `sph`
- `obj_type_for_def_keyword`：`SPH` 关键字匹配 → `sph`；`*PARTICLE_HE/AIR/SOIL` → `dp`
- `build_buffer_index`：`sph = {}`, `dp = {}` 加入三个索引桶
- `parse_block_objects`：硬编码 row-1 定义提取

## 四、`*PARTICLE_DOMAIN` entype=0 支持

### 问题

`*PARTICLE_DOMAIN` 的 `entype` 允许 `0`（表示无交互），但 lint 的 generic enum 不包含 `0`，报 `Invalid value '0' for field 'entype'`。

### 修复

- 更新 `commands.help` 中 `*PARTICLE_DOMAIN` 的描述，使 `0` 出现在 `options:` 中
- `lint.lua` `check_enum_values`：对 `*PARTICLE_DOMAIN` + `entype` 组合跳过 generic enum，改用 description options

## 五、`re -a` scientific notation 精度 bug

### 问题

`re -a` 后 `1.0e9` 被 `simplify_numeric_text` 的 whole-line path 重新求值，由于 Lua 浮点精度导致数值轻微变化（如 `1.0e9` → `999999999.9999`）。

### 修复

whole-line path 增加 `is_plain_numeric_literal` guard：如果整行已经是一个合法的纯数字字面量（含科学计数法），跳过重新求值。

## 六、`re -b` floor evaluation 误吞 description

### 问题

`re -b` 在替换 `*PARAMETER` 定义行时，将 trailing description（如 `, "V0=V*b^3*R/k..."`）也送进了 `eval_fn`，导致 floor/ceil 等函数收到非法字符串参数。

### 修复

在 `replace_params_in_buffer` 中，求值前检查 `raw_val:find(',%s*".*"$')`，如果存在 trailing description，先截断再求值，最后把 description 拼回。

## 七、`re -b` 后美化 `*PARAMETER` 块

### 需求

`re -b` 替换并求值后，`*PARAMETER` / `*PARAMETER_DEFAULT` 定义行的等号不再对齐，可读性下降。

### 修复

`replace_params_in_buffer` 返回前，若 `mode == "all"`，调用 `align_parameter_blocks_in_buffer()`，对所有 `*PARAMETER` / `*PARAMETER_DEFAULT` 块执行等号对齐。

## 八、`*CFD_WIND_TUNNEL` 支持

### 新增支持

- `skip_field_count` 中加入 `*CFD_WIND_TUNNEL`（该关键字字段数可变）
- `check_required_fields`：仅校验第一字段 `fid_v`，其余字段视为可选
- `classify_ref_type`：扩展 `fid_` 匹配模式为 `^fid_[%w_]+$`，使 `fid_v` 等后缀被识别为 `curve` 引用

## 九、空行作为合法数据行

### 背景

某些关键字块中，空行代表“全部取默认值”，是合法的。之前 lint 和 side_help 在收集数据行时会跳过空行，导致字段数判断错误。

### 修复

`collect_data_rows` 以及 `lint.lua` / `side_help.lua` 中的数据行收集逻辑统一改为**包含空行**（只要不是 `#`/`$`/`~` 开头或标题行）。

## 十、`*FUNCTION` expression 中的 `fcn(id)` 未被索引

### 问题

`parse_block_objects` 中对 `fcn(id)`/`crv(id)`/`dfcn(id)` 的 embedded 搜索被放在 `if param_name then` 块内。当字段超出 schema 长度时（如 `*FUNCTION` 的第二行 expression 没有 schema 参数名），整个搜索被跳过。

### 修复

将 embedded `fcn(id)`/`crv(id)`/`dfcn(id)` 搜索移到 `param_name` guard **外部**，使其对所有字段值都生效。

## 十一、Unused parameter 波浪线宽度修复

### 问题

未使用参数的波浪下划线只覆盖第一个字符，而不是整个参数名。

### 修复

- `analysis.lua`：`build_params_from_lines` 和 `build_buffer_index` 在存储参数定义时额外记录 `end_col`
- `lint.lua`：`push_diagnostic` 接受可选 `end_col`；`check_unused_params` 将 `first.end_col` 传入，使波浪线覆盖完整参数名

## 十二、`*PARAMETER` description 误报 enum 错误的根本原因

### 症状

`*PARAMETER` 行如：

```
V0 = 1.905e-4, "V0=V*b^3*R/k where R=8.3145, k=1.38e-23, V=18.41, b=2.58e-10"
```

执行 `:Cc` 仍然报 `Invalid value 'V=18.41' for field 'quantity'`。

### 表面修复（已做但未生效）

1. `split_csv_outside_quotes` 替代 `split_csv_keep_empty`，正确分割带引号的逗号
2. `is_param_description` guard：若 `*PARAMETER` 字段含 `=` 或被双引号包围，跳过 enum 检查

### 根本原因

`check_enum_values` 函数（`lint.lua` line 1344）内部使用了 `kw_upper`，但该变量**从未在该函数内定义**。Lua 中未定义变量值为 `nil`，因此：

- `(kw_upper == "*PARAMETER" or kw_upper == "*PARAMETER_DEFAULT")` 永远为 `false`
- `split_csv_outside_quotes` 从未被调用（仍用 `split_csv_keep_empty`）
- `is_param_description` 永远为 `false`

### 修复

在 `check_enum_values` 的 `if kw then` 块内添加：

```lua
local kw_upper = kw:upper()
```

## 十三、`tabid` → `*TABLE` 引用支持

### 需求

`*BOLT_FAILURE`、`*BOLT`、`*SPOT_WELD` 等关键字中的 `tabid` 字段需要被识别为对 `*TABLE` 关键字中 `coid` 的引用，支持 `gd`/`gr` 跳转和 lint 未定义检查。

### 修改点

- `classify_ref_type`：`p:match("^tabid")` → `table`
- `classify_def_type`：`*TABLE` + `coid`/`id` → `table`
- `obj_type_for_def_keyword`：`*TABLE` → `table`
- `build_buffer_index`：`table = {}` 加入三个索引桶
- `parse_block_objects`：`*TABLE` row-1 硬编码定义
- `scan_object_refs_from_lines`：添加 8 个含 `tabid` 关键字的字段位置映射：

| 关键字                  | tabid 所在字段    |
| -------------------- | ------------- |
| `*BOLT_FAILURE`      | 2             |
| `*BOLT`              | 7             |
| `*SPOT_WELD`         | 3             |
| `*AIR_BLAST`         | 7             |
| `*CHARGE`            | 7             |
| `*LAYERED_COMPOSITE` | 2             |
| `*CUTTER`            | 3             |
| `*BALLISTIC_LIMIT`   | 5 (`tabid_m`) |

## 十四、`re -a` / `re -b` 执行后自动刷新

### 问题

`replace_params_in_buffer` 使用 `nvim_buf_set_lines` 批量修改 buffer。**`nvim_buf_set_lines` 不会触发 `TextChanged` autocmd**，因此：

- `ref_marks` 的 debounce 不会触发，下划线保持旧状态
- lint 不会自动更新
- 虽然 `gd`/`gr` 基于 `changedtick` 的缓存会在下次调用时重建，但视觉上用户看不到更新

### 修复

提取公共函数 `refresh_buffer_analysis(buf)`，在 `changed > 0` 时调用：

1. `analysis.invalidate_buffer_index(buf)`
2. `lint.run(buf)`
3. `require("impetus.ref_marks").update(buf)`

## 十五、`:Update` 命令新增

### 需求

用户手动编辑文件后（如修改一个对象 ID），想立即看到最新的下划线、lint 诊断和索引关系，不想等 400ms debounce 或保存文件。

### 实现

- 新增 `:ImpetusUpdate` 命令，内部调用 `refresh_buffer_analysis()`
- 短别名 `:Update`
- 执行后显示 `Impetus analysis updated.`

---

## 本次对话批次文件变更清单

| 文件                          | 变更类型 | 主要内容                                                                                                                                                                                                                                                                 |
| --------------------------- | ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lua/impetus/analysis.lua`  | 修改   | `classify_ref_type` `tabid` 支持；`classify_def_type` `*TABLE` 支持；`obj_type_for_def_keyword` `*TABLE`；`build_buffer_index` `table/sph/dp` 桶；`parse_block_objects` `*TABLE`/`*FUNCTION`/`fcn(id)` 精确列/SPH/DP/embedded ref 修复；`scan_object_refs_from_lines` `tabid` 跨文件扫描 |
| `lua/impetus/lint.lua`      | 修改   | `kw_upper` 定义修复；`split_csv_outside_quotes` `*PARAMETER` 支持；`*PARTICLE_DOMAIN` entype=0；`*CFD_WIND_TUNNEL` 支持；空行作为数据行；unused param `end_col`；`check_object_refs_valid` 泛型遍历                                                                                           |
| `lua/impetus/commands.lua`  | 修改   | `refresh_buffer_analysis()` 公共函数；`re -a`/`re -b` 后自动刷新；`:ImpetusUpdate` / `:Update` 命令；`re -b` beautify + description 截断；scientific notation guard                                                                                                                   |
| `lua/impetus/ref_marks.lua` | 修改   | `id_end_col` 扩展 token 覆盖范围；def marks 优先于 ref marks                                                                                                                                                                                                                   |
| `commands.help`             | 修改   | `*PARTICLE_DOMAIN` entype 描述更新；`*BOLT_FAILURE` 等 `tabid` 字段已存在                                                                                                                                                                                                       |
| `data/keywords.json`        | 重新生成 | 与 `commands.help` 同步                                                                                                                                                                                                                                                 |

---

# 后续更新记录（第二轮对话批次）

## 十六、`*LOAD_AIR_BLAST` ground=0 enum fix

### 问题

`*LOAD_AIR_BLAST` 的 `ground` 字段填 `0` 时，`:Cc` 报错 `Invalid value '0'`。

### 根因

`schema.lua` 的 `generic_enum_for_name("ground")` 返回的预定义枚举只有 `{"X", "Y", "Z"}`，缺少 `"0"`。

### 修复

```lua
if n == "ground" then
  return { "0", "X", "Y", "Z" }
end
```

---

## 十七、Material density (`ρ`) physics sanity check

### 问题

材料密度使用希腊字母 `ρ` 作为字段名时，物理合理性检查（SI 密度范围 500–30000 kg/m³）不生效。

### 根因

`lint.lua` `check_physics_sanity` 只匹配了 `rho` 和 `density`，未匹配 Unicode `ρ`。

### 修复

```lua
if fname == "rho" or fname == "density" or fname == "ρ" then
  -- suspicion_below / suspicion_above checks
end
```

---

## 十八、`*OUTPUT_SENSOR` `R` 条件校验（最终版）

### 问题演进

- 最初：`*OUTPUT_SENSOR` 的 `R` 被无条件视为可选
- 第一轮修复：改为当文件中出现 `*PARTICLE_*` 或 `*CFD_*` 关键字时，`R` 强制必填
- **本轮发现**：help 实际说明 `R` 仅在 `pid == "DP"`（离散粒子）时才需要，`R>0` 是采样半径

### 最终修复

`lint.lua` `check_required_fields` 中：

```lua
if p == "r" then
  local pid_val = trim(fields[2] or ""):upper()
  if pid_val ~= "DP" then
    is_optional = true
  end
end
```

仅在 `pid=DP` 时校验 `R>0`，其余情况 `R` 可选。

---

## 十九、`*CFD_*` / `*PARTICLE_*` per-subtype ID scoping

### 问题

`*CFD_HE`（ID=1）和 `*CFD_BOUNDARY`（ID=1）被归为同一 family `"cfd"`，导致不同子类型不能共用 ID，报 duplicate ID。

### 思路

不同 CFD 子类型（如 HE、BOUNDARY、WIND_TUNNEL）之间应当允许 ID 重复，同一子类型内部才应禁止。

### 修复

`lint.lua` `keyword_to_family`：

```lua
if k:match("^%*CFD_") then return k:sub(2) end
if k:match("^%*PARTICLE_") then return k:sub(2) end
```

返回去掉 `*` 后的完整关键字名作为 family，而不是统一返回 `"cfd"`/`"particle"`。

---

## 二十、`*END` trailing whitespace fix

### 问题

`*END` 后面如果有空格或尾随内容，`:Cc` 报格式错误。

### 思路

`*END` 是输入终止符，solver 会忽略其后所有内容，因此 trailing content 完全合法。

### 修复

`lint.lua` `check_required_fields` 中直接 `return`，完全跳过 `*END` 的字段校验。

---

## 二十一、`*OBJECT` local parameters

### 问题

1. `*OBJECT` 块内的局部参数（如 `a = 1.0`）被当作全局未使用参数，报 unused param 波浪线
2. `clean -a` 不对 `*OBJECT` 内的参数行做等号对齐

### 思路

`*OBJECT` 内部的 `name = expression` 行是局部参数定义，作用域仅限于该对象。

### 修复

- `check_unused_params`：跳过位于 `*OBJECT` 块内的参数定义
- `commands.lua` `align_parameter_blocks_in_buffer`：对 `*OBJECT` 块，从第一个 `name = ...` 行开始，将该行及之后的参数定义行按 `*PARAMETER` 格式对齐

---

## 二十二、`*PATH` multi-column alignment

### 问题

`*PATH` 数据有3列（x, y, z），但 `format_curve_data_lines` 只硬编码支持2列对齐。

### 修复

改为动态检测列数，逐列计算最大显示宽度，每列前面按前一列的 `max_width - actual_width` 填充空格：

```lua
for ci = 2, #spec.cols do
  local pad = string.rep(" ", math.max(0, (max_widths[ci - 1] or 0) - (spec.widths[ci - 1] or 0)))
  text = text .. ", " .. pad .. spec.cols[ci]
end
```

---

## 二十三、Comment-line param parsing

### 问题

注释行中的 `%param` 被错误识别为引用或定义：

```
# %rho is defined above
```

导致 `#%rho` 被当作对 `%rho` 的引用。

### 修复

`analysis.lua` 的 `build_buffer_index` 和 `build_params_from_lines` 中，扫描 `%param` 前增加：

```lua
local is_comment = trimmed:sub(1, 1) == "#" or trimmed:sub(1, 1) == "$"
if not is_comment then
  -- scan %param refs and defs
end
```

---

## 二十四、`*COMPONENT_PIPE` duplicate ID 0

### 问题

`*COMPONENT_PIPE` 中 `csysid=0` 被报 duplicate ID 0。

### 根因

`classify_def_type` 无条件地把所有关键字中的 `csysid` 字段识别为 `coordinate_system` 定义，但 `*COMPONENT_PIPE` 中的 `csysid` 只是对已有坐标系的引用。

### 修复

```lua
if k:match("^%*COORDINATE_SYSTEM") and p == "csysid" then
  return "coordinate_system"
end
```

仅 `*COORDINATE_SYSTEM` 关键字中的 `csysid` 才是定义。

---

## 二十五、Diagnostic colors unified

### 修复

`highlight.lua` 中统一定义：

```lua
hi("DiagnosticError", { fg = "#ff4444" })   -- red
hi("DiagnosticWarn",  { fg = "#ffd166" })   -- yellow
hi("DiagnosticHint",  { fg = "#00d7ff" })   -- cyan
```

---

## 二十六、`*INITIAL_STRESS_FUNCTION` optional fids

### 问题

`*INITIAL_STRESS_FUNCTION` 中从第3字段开始的 `fid_xx`、`fid_yy` 等被报 missing required field。

### 思路

help 说明这些 stress function ID 全部可选，默认值为 0，只有 `entype` 和 `enid` 是必需的。

### 修复

`lint.lua` `check_required_fields` 中对该关键字只校验 `entype` 和 `enid` 非空。

---

## 二十七、`*PARTICLE_DOMAIN` conditional `enid`

### 问题

`*PARTICLE_DOMAIN` 的 `entype` 为空或 `"0"`（表示无结构交互）时，`enid` 为空被报 missing required field。

### 修复

`check_required_fields` 中：

```lua
if kw_upper == "*PARTICLE_DOMAIN" then
  local entype_val = trim(fields[1] or "")
  if entype_val == "" or entype_val == "0" then
    -- enid is optional when no structure interaction
  end
end
```

---

## 二十八、Parameter case sensitivity

### 问题

`*PARAMETER a = 1` 和 `*PARAMETER A = 2` 被当作同一个变量；`:re` 替换时 `a` 和 `A` 互相覆盖；`:Cc` unused-param 检查混淆大小写。

### 思路

Impetus solver 中参数名是 **case-sensitive** 的，`a` 和 `A` 是两个不同变量。

### 修复

1. `analysis.lua`、`commands.lua`、`lint.lua` 的 `normalize_param_name` 中移除 `:lower()`
2. `commands.lua` `replace_params_in_buffer` 中使用 case-sensitive 的 `current_vars` 键，不再用 `name:lower()` 做 lookup

---

## 二十九、`*OUTPUT` `N_res` 范围表达式解析

### 问题

`*OUTPUT` 第二行最后一个参数 `N_res=2` 被 `:Cc` 报错 `Invalid value '2'`。

### help 原文

```
N_res : Number of cyclic alternating files for model database and state file output
        options: 1 leq N_res leq 99
        default: N_res=9
```

### 根因

`extract_options_from_desc` 的 Pattern 1 将 `options: 1 leq N_res leq 99` 当作逗号分隔的枚举列表解析，由于没有逗号，整个字符串 `"1 leq N_res leq 99"` 被当作**单个枚举值**存入 opts。当实际值是 `2` 时，`opts["2"]` 不存在，触发报错。

### 修复

**步骤1**：`extract_options_from_desc` 新增对 `N leq VAR leq M` / `N <= VAR <= M` 范围语法的专门解析：

```lua
local lo, hi = d:match("(%d+)%s*leq%s*[%w_]+%s*leq%s*(%d+)")
if not lo then
  lo, hi = d:match("(%d+)%s*<=%s*[%w_]+%s*<=%s*(%d+)")
end
if lo and hi then
  local opts = {}
  opts["__ge__"] = tonumber(lo)
  opts["__le__"] = tonumber(hi)
  return opts
end
```

**步骤2**：`check_enum_values` 将原有仅支持下界（`__gt__`/`__ge__`）的数值检查，扩展为支持完整四则边界：

```lua
if num then
  local in_range = true
  if opts.__gt__ and num <= opts.__gt__ then in_range = false end
  if opts.__ge__ and num < opts.__ge__ then in_range = false end
  if opts.__lt__ and num >= opts.__lt__ then in_range = false end
  if opts.__le__ and num > opts.__le__ then in_range = false end
  if in_range then
    is_valid = true
  end
end
```

现在 `N_res = 2` 满足 `num >= 1` 且 `num <= 99`，不再被误判为非法值。

---

## 第二轮对话批次文件变更清单

| 文件                          | 变更类型 | 主要内容                                                                                                                                                                                                                                                                                                            |
| --------------------------- | ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lua/impetus/schema.lua`    | 修改   | `generic_enum_for_name("ground")` 增加 `"0"`                                                                                                                                                                                                                                                                      |
| `lua/impetus/lint.lua`      | 修改   | `ρ` 密度检查；`*OUTPUT_SENSOR` `R` 按 `pid=DP` 条件校验；`*CFD_*` / `*PARTICLE_*` per-subtype family；`*END` 跳过；`*OBJECT` 局部参数豁免；`*PATH` 多列对齐；comment-line 跳过；`*COMPONENT_PIPE` `csysid` 定义限制；diagnostic colors 统一；`*INITIAL_STRESS_FUNCTION` 可选 fids；`*PARTICLE_DOMAIN` 条件 enid；parameter case sensitivity；`N_res` 范围表达式解析 |
| `lua/impetus/analysis.lua`  | 修改   | comment-line 跳过；`csysid` 定义限制；parameter case sensitivity；`*OBJECT` 局部参数                                                                                                                                                                                                                                         |
| `lua/impetus/commands.lua`  | 修改   | parameter case sensitivity；`*OBJECT` 参数对齐；`*PATH` 多列对齐                                                                                                                                                                                                                                                          |
| `lua/impetus/highlight.lua` | 修改   | `DiagnosticError`/`Warn`/`Hint` 颜色统一                                                                                                                                                                                                                                                                            |

---

**备份时间戳**：`202604281034`

---

# 后续更新记录（第三轮对话批次）

## 三十、`crv(id, x)` / `fcn(id, t)` 多参数识别修复

### 问题

`*FUNCTION` 表达式中的 `crv(101, x)` 的 `101` 没有被识别为 curve ID。导致：

1. `gd` 在 `101` 上无法跳转到 `*CURVE 101`
2. `:Cc` lint 对 `*CURVE 101` 报 "unused curve"（ falsely ）
3. `:Cc` lint 对缺失的 curve 引用不报 "undefined curve"

### 根因分析（双重问题）

#### 问题 A：`scan_object_refs_from_lines` 正则过于严格

该函数用于跨文件轻量级扫描，其 `gmatch` 模式要求数字后必须紧跟 `)`：

```lua
for id in tv:gmatch("crv%s*%(%s*(%d+)%s*%)'") do  -- 只匹配 crv(101)
```

当表达式为 `crv(101, x)` 时，数字后是逗号而非右括号，匹配失败。

#### 问题 B：`parse_block_objects` 字段级扫描被逗号分割破坏

`*FUNCTION` 表达式行 `-y*0.005/0.015*crv(101,x)` 先经过 `split_csv_outside_quotes` 按逗号分割字段。逗号在 `crv(101,x)` 中被当成 CSV 分隔符，导致表达式被拆成：

1. `-y*0.005/0.015*crv(101`
2. `x)`

原来的字段级 `tv:find(...)` 在每个碎片上搜索 `crv(%d+)`，均匹配失败。

### 修复

#### 修复 A：`scan_object_refs_from_lines` 允许逗号或右括号

将三个 `gmatch` 模式从 `%)` 改为 `[,)]`，并补全 `dfcn`：

```lua
-- 旧
for id in tv:gmatch("fcn%s*%(%s*(%d+)%s*%)'") do
for id in tv:gmatch("crv%s*%(%s*(%d+)%s*%)'") do

-- 新
for id in tv:gmatch("fcn%s*%(%s*(%d+)%s*[,)]") do
for id in tv:gmatch("crv%s*%(%s*(%d+)%s*[,)]") do
for id in tv:gmatch("dfcn%s*%(%s*(%d+)%s*[,)]") do
```

#### 修复 B：`parse_block_objects` 从字段级提升到行级扫描

将 `fcn(id)` / `crv(id)` / `dfcn(id)` 的扫描从 `for field_idx, value in ipairs(values) do` 循环**内部**移到循环**外部**，改为直接对 `raw_line` 扫描：

```lua
-- 放在 for field_idx ... end 之后、else 块结束之前
-- Treat fcn(id) / crv(id) / dfcn(id) anywhere in the row as curve references.
-- Scan on raw_line (not split fields) so commas inside crv(101,x) are not
-- mistaken for CSV separators.
do
  local tv = trim(raw_line)
  local search_pos = 1
  while search_pos <= #tv do
    local s, e, prefix, ref_id = tv:find("(%a+)%s*%(%s*(%d+)%s*[,)]", search_pos)
    if not s then break end
    local p = prefix:lower()
    if p == "fcn" or p == "crv" or p == "dfcn" then
      local match_str = tv:sub(s, e)
      local id_s = match_str:find("%d+")
      if id_s then
        -- Compute 0-indexed column of the numeric id inside raw_line.
        -- tv is trimmed raw_line; s is position inside tv.
        local first_non_space = raw_line:find("%S") or 1
        local trim_offset = first_non_space - 1
        local id_col = trim_offset + s - 1 + id_s - 1
        store_ref("curve", ref_id, id_col)
      else
        local first_non_space = raw_line:find("%S") or 1
        store_ref("curve", ref_id, first_non_space - 1 + s - 1)
      end
    end
    search_pos = e + 1
  end
end
```

列号计算说明：

- `first_non_space`：raw_line 中第一个非空格字符的 1-indexed 位置
- `trim_offset`：前导空格数（`first_non_space - 1`）
- `s`：匹配前缀（如 `crv`）在 `tv`（trimmed line）中的 1-indexed 位置
- `id_s`：数字在 `match_str` 中的 1-indexed 位置
- 最终 `id_col = trim_offset + (s - 1) + (id_s - 1)`，为 0-indexed 列号

### 影响范围

- `gd` / `gr`：现在可在 `*FUNCTION` 表达式中的 `crv(101,x)` / `fcn(1,t)` / `dfcn(2,t)` 上正确跳转
- `ref_marks`：绿色/蓝色/红色下划线现在会出现在 `*FUNCTION` 表达式中的 curve 引用上
- `check_unused_curves`：不再 falsely 警告仅在 `*FUNCTION` 中被引用的 curve
- `check_object_refs_valid`：能正确检测 `*FUNCTION` 中引用了不存在的 curve ID

### 第三轮对话批次文件变更清单

| 文件                         | 变更类型 | 主要内容                                                                                                   |
| -------------------------- | ---- | ------------------------------------------------------------------------------------------------------ |
| `lua/impetus/analysis.lua` | 修改   | `scan_object_refs_from_lines`：`%)` → `[,)]`，新增 `dfcn`；`parse_block_objects`：`fcn/crv/dfcn` 扫描从字段级提升到行级 |

**备份时间戳**：`202604252359`

---

## 三十一、`gd` 在 `crv(101,x)` 上无法跳转 —— `object_under_cursor` fallback 修复

### 问题

即使 `parse_block_objects`（索引层）已能识别 `crv(101,x)`，`gd` 在 `101` 上仍然无法跳转到 `*CURVE 101`。

### 根因

`object_under_cursor`（导航层）使用 `split_csv_outside_quotes` 分割当前行，再对字段做 `value_as_id`：

```lua
local fields = split_csv_outside_quotes(line)
local idv = value_as_id(trim(fields[ctx.field_idx] or ""))
```

对于 `-y*0.005/0.015*crv(101,x)`，`split_csv_outside_quotes` 把逗号当成 CSV 分隔符，拆成：

1. `-y*0.005/0.015*crv(101`
2. `x)`

光标在 `101` 上时 `field_idx = 1`，`value_as_id("-y*0.005/0.015*crv(101")` 返回 `nil`，函数直接 `return nil`，`gd` 失效。

### 修复

在 `idv == nil` 的分支中增加 fallback：检查光标是否恰好位于 `crv(id)` / `fcn(id)` / `dfcn(id)` 的数字参数上。

```lua
  if not idv then
    -- Fallback: cursor might be inside crv(id, x) / fcn(id, t) / dfcn(id, t)
    -- where the comma was split by split_csv_outside_quotes.
    local col1 = col0 + 1
    if line:sub(col1, col1):match("%d") then
      local cursor_num = line:match("%d+", col1)
      if cursor_num then
        local before = line:sub(1, col1 - 1)
        local func_name = before:match("(%a+)%s*%(%s*$")
        if func_name then
          local p = func_name:lower()
          if p == "fcn" or p == "crv" or p == "dfcn" then
            return { obj_type = "curve", id = cursor_num }
          end
        end
      end
    end
    return nil
  end
```

逻辑：

1. `line:sub(col1, col1):match("%d")` — 光标必须在数字字符上
2. `line:match("%d+", col1)` — 提取光标所在位置的完整数字
3. `before:match("(%a+)%s*%(%s*$")` — 检查光标前的文本是否以 `word(` 结尾
4. 前缀为 `fcn`/`crv`/`dfcn` → 返回 `{ obj_type = "curve", id = ... }`

### 第三轮补充文件变更清单

| 文件                         | 变更类型 | 主要内容                                                                          |
| -------------------------- | ---- | ----------------------------------------------------------------------------- |
| `lua/impetus/analysis.lua` | 修改   | `object_under_cursor`：增加 `crv(id,x)` / `fcn(id,t)` / `dfcn(id,t)` fallback 识别 |

**补充备份时间戳**：`202604260007`

---

## 三十二、`*PARAMETER` 未使用参数不报告 warning

### 问题

`*PARAMETER` 下定义 `%ere = 33`，没有任何地方引用它，但 `:Cc` 不报告 "Parameter %ere is defined but never used"。

### 根因

`build_buffer_index` / `build_params_from_lines` 在扫描 `%param` 引用时，使用：

```lua
for p in (raw or ""):gmatch("%%([%a_][%w_]*)") do
  -- 记录为引用
end
```

对于参数定义行 `%ere = 33`，`gmatch` 同样会把行首的 `%ere` 匹配为一次**引用**。因此 `cross.refs["ere"]` 非空，`check_unused_params` 认为该参数已被使用，跳过 warning。

### 修复

在 `check_unused_params` 中，检查引用时排除与定义位于**同一行**的引用（self-reference）：

```lua
for name, defs in pairs(idx.params.defs or {}) do
  local used = false
  if cross and cross.refs[name] then
    for _, ref in ipairs(cross.refs[name]) do
      local is_self_ref = false
      for _, def in ipairs(defs) do
        if ref.row == def.row then
          is_self_ref = true
          break
        end
      end
      if not is_self_ref then
        used = true
        break
      end
    end
  end
  if not used then
    -- 推送 "defined but never used" warning
  end
end
```

### 第三轮补充文件变更清单（续）

| 文件                     | 变更类型 | 主要内容                                                          |
| ---------------------- | ---- | ------------------------------------------------------------- |
| `lua/impetus/lint.lua` | 修改   | `check_unused_params`：排除参数定义行自身的 `%param` 自引用，使真正未使用的参数能被正确检测 |

**补充备份时间戳**：`202604260012`

---

## 三十三、`*PARAMETER` 下输入时关键字颜色变暗

### 问题

在 `*PARAMETER` 关键字的数据行中输入新内容时，`*PARAMETER` 本身的颜色由鲜艳紫色（`#ff00ff`）突变为暗淡的默认紫色。退出 Insert 模式后仍然不恢复，只有打开 info/help 窗口后才恢复。

### 根因

`refresh_completion_palette_burst` 在 `InsertEnter` / `CompleteChanged` / `CompleteDone` / `CompleteDonePre` 时触发，会在 0/20/80/160 ms 多次调用 `refresh_completion_palette`，后者调用 `refresh_main_visuals` → `ensure_impetus_syntax`。

`ensure_impetus_syntax` 每次都执行：

```lua
vim.cmd("silent! syntax clear")
vim.cmd("silent! source " .. syntax_path)
```

`syntax clear` 会清除 `syntax/impetus.vim` 中定义的 `syntax match impetusKeyword ...` 等匹配规则。随后 `source` 本应重新加载这些规则，但在 insert 模式下频繁执行时，Neovim 的 syntax 引擎可能无法可靠地恢复所有规则，导致关键字匹配丢失。

一旦 `impetusKeyword` 的 `syntax match` 规则丢失，`*PARAMETER` 就不再被识别为 `impetusKeyword`，文本回退到默认颜色。`highlight.apply()` 虽然把 `impetusKeyword` 定义为 `#ff00ff`，但没有文本被标记为 `impetusKeyword`，颜色自然无法生效。

打开 info/help 窗口会触发 `BufEnter`/`WinEnter` → `refresh_main_visuals`，此时 `ensure_impetus_syntax` 在 normal 状态下完整执行，`syntax match` 规则被正确恢复，颜色回归。

### 修复

在 `ensure_impetus_syntax` 中添加 guard：如果 `b:current_syntax` 已经是 `"impetus"`，说明 syntax 已经加载且激活，直接跳过，不再重复 `syntax clear`。

```lua
  local function ensure_impetus_syntax(buf)
    ...
    if vim.b[buf].current_syntax == "impetus" then
      return
    end
    ...
  end
```

`syntax/impetus.vim` 末尾设置了 `let b:current_syntax = "impetus"`，因此 buffer 首次加载后该 guard 会持续生效，只有在 syntax 真正缺失时（如 colorscheme 切换后部分清空、或 buffer 首次打开）才会执行完整的 `syntax clear` + `source`。

### 第四轮文件变更清单

| 文件                     | 变更类型 | 主要内容                                                                                           |
| ---------------------- | ---- | ---------------------------------------------------------------------------------------------- |
| `lua/impetus/init.lua` | 修改   | `ensure_impetus_syntax`：添加 `b:current_syntax == "impetus"` guard，避免输入时频繁 `syntax clear` 导致规则丢失 |

**补充备份时间戳**：`202604260020`

---

## 三十四、`*PARAMETER` 下输入时关键字颜色变暗（续）— 禁用弹窗

### 问题演进

上一轮修复（`ensure_impetus_syntax` 添加 `b:current_syntax` guard）未完全解决问题。用户反馈：

- 现象**只发生在 `*PARAMETER` 关键字下方**
- 每次在 `*PARAMETER` 数据行输入时，会有一个**弹窗/提示**自动出现
- 弹窗一旦出现，`*PARAMETER` 本身的颜色就由鲜艳紫色突变为暗紫色
- 该弹窗对参数定义行没有任何实际意义

### 根因推断

`*PARAMETER` 的数据行是参数定义（如 `%ere = 33`），不是标准关键字数据行。在该区域输入时，两个机制会各自触发窗口/菜单：

1. **blink.cmp completion**：`blink_source.lua` 的 trigger characters 包含 `%` 和 `[`。在参数定义行输入 `%` 时会弹出 completion 菜单。
2. **side help auto-display**：`CursorMovedI` autocmd 会在光标移动时自动打开右侧 help pane，显示 `*PARAMETER` 的 help 信息。

其中任何一个窗口的创建/销毁都可能触发 `WinEnter`/`BufEnter` → `refresh_main_visuals` → `ensure_impetus_syntax` 的完整链路。即使 `b:current_syntax` guard 阻止了 `syntax clear`，窗口切换本身仍可能干扰 Neovim 的 syntax highlight 状态（尤其是在 floating window 与主窗口之间频繁切换时）。

### 修复

直接禁用 `*PARAMETER` 块内的两种自动弹窗：

#### 1. `blink_source.lua` — 禁用 completion

在 `get_completions` 开头检测光标是否位于 `*PARAMETER` / `*PARAMETER_DEFAULT` / `*PARAMETER_*` 块内，如果是则直接返回空 items：

```lua
  local row = cursor[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, row, false)
  local in_param_block = false
  for i = #lines, 1, -1 do
    local kw = (lines[i] or ""):match("^%s*%*([%u%d_%-]+)")
    if kw then
      local k = "*" .. kw:upper()
      if k == "*PARAMETER" or k == "*PARAMETER_DEFAULT" or k:match("^%*PARAMETER_") then
        in_param_block = true
      end
      break
    end
  end
  if in_param_block then
    resolve({ is_incomplete_forward = false, is_incomplete_backward = false, items = {} })
    return
  end
```

#### 2. `side_help.lua` — 禁用 auto-display

在 `M.render` 中检测到当前关键字为 `*PARAMETER` 家族时，关闭已打开的 help pane 并直接返回：

```lua
  if keyword then
    local kw_upper = keyword:upper()
    if kw_upper == "*PARAMETER" or kw_upper == "*PARAMETER_DEFAULT" or kw_upper:match("^%*PARAMETER_") then
      M.close_for_current(false)
      return
    end
  end
```

### 第五轮文件变更清单

| 文件                             | 变更类型 | 主要内容                                                               |
| ------------------------------ | ---- | ------------------------------------------------------------------ |
| `lua/impetus/blink_source.lua` | 修改   | `get_completions`：在 `*PARAMETER` 块内返回空 completion，避免 floating menu |
| `lua/impetus/side_help.lua`    | 修改   | `M.render`：检测到 `*PARAMETER` 关键字时自动关闭 help pane                     |

---

## 六、`:clean -s`（Simple Beautify）简单美化命令

### 6.1 需求背景

用户需要一个**只格式化、不删除任何内容**的命令，用于：

- 规范化逗号间距
- 对齐参数定义和数据列
- 规范化表达式中的运算符空格

### 6.2 核心实现：`commands.lua`

#### 1. `normalize_comma_lines(block_lines)`

- 逗号后严格一个空格：`,  `
- 前导逗号前保留一个空格：`, x, y` → ` , x, y`
- 引号内内容不处理

```lua
local function normalize_comma_lines(block_lines)
  local out = {}
  for _, line in ipairs(block_lines or {}) do
    local t = trim(line)
    if t == "" or t:sub(1, 1) == "#" or t:sub(1, 1) == "$" then
      out[#out + 1] = line
    else
      local fields = split_csv_keep_empty(line)
      if #fields > 1 then
        local lead = line:match("^(%s*)") or ""
        local text = trim(fields[1])
        for i = 2, #fields do
          text = text .. ", " .. trim(fields[i])
        end
        if trim(fields[1]) == "" then
          text = " " .. text
        end
        out[#out + 1] = lead .. text
      else
        out[#out + 1] = line
      end
    end
  end
  return out
end
```

#### 2. `normalize_expression_lines(block_lines)`

- `^` 运算符**不加空格**：`a ^ 2` → `a^2`
- `+ - * /` **加空格**（仅二元运算符）
- 引号内内容不处理

```lua
local function normalize_expression_lines(block_lines)
  local out = {}
  for _, line in ipairs(block_lines or {}) do
    -- ... remove spaces around ^, then add spaces around + - * /
    -- (binary only: only when preceded by word/number/%) and followed by word/number/()
  end
  return out
end
```

#### 3. `simple_beautify_buffer()`

| 块类型                                 | 格式化操作                                                                                        |
| ----------------------------------- | -------------------------------------------------------------------------------------------- |
| `*PARAMETER` / `*PARAMETER_DEFAULT` | `format_parameter_definition_lines` + `normalize_expression_lines` + `normalize_comma_lines` |
| `*CURVE` / `*TABLE` / `*PATH`       | `format_curve_data_lines` + `normalize_comma_lines`                                          |
| `*FUNCTION`                         | `normalize_expression_lines` + `normalize_comma_lines`                                       |
| 其他                                  | 不变                                                                                           |

**关键特性**：

- **不删除任何行**（不删除注释、空行、孤立块）
- **不修改关键字行**
- 只修改块内数据行的格式

#### 4. `run_clean_command` 新增 `-s` 分支

```lua
if args == "-s" then
  local changed, entries = simple_beautify_buffer()
  local log_lines = { string.format("[summary] changed=%d", changed) }
  if #entries > 0 then
    log_lines[#log_lines + 1] = "[beautified]"
    for _, e in ipairs(entries) do
      log_lines[#log_lines + 1] = string.format("  L%-5d %-16s  %s  ->  %s", e.row, e.keyword, trim(e.old_line), trim(e.new_line))
    end
  end
  local log_path = append_operation_log("clean -s", log_lines)
  vim.notify(string.format("Impetus clean -s done. Beautified: %d | log: %s", changed, vim.fn.fnamemodify(log_path, ":~:.")), vim.log.levels.INFO)
  return
end
```

用法提示同步更新为：

```lua
vim.notify("Usage: :clean | :clean -c | :clean -a | :clean -s", vim.log.levels.WARN)
```

### 第六轮文件变更清单

| 文件                                      | 变更类型 | 主要内容                                                                                                            |
| --------------------------------------- | ---- | --------------------------------------------------------------------------------------------------------------- |
| `lua/impetus/commands.lua`              | 修改   | 新增 `normalize_comma_lines`、`normalize_expression_lines`、`simple_beautify_buffer`；`run_clean_command` 新增 `-s` 分支 |
| `IMPETUS_NVIM_COMMANDS_SHORTCUTS_v1.md` | 修改   | 新增 2.6 节 `:clean` 命令说明                                                                                          |

### 6.3 修正（2026-04-26）——对齐优先于逗号规范化

用户反馈：`*PARAMETER` 的双引号对齐、`*CURVE`/`*TABLE`/`*PATH` 的列对齐，必须**优先于**`normalize_comma_lines` 的"逗号后一个空格"规则。否则对齐后的结果被二次处理会破坏列宽。

修正后的 `simple_beautify_buffer` 块类型策略：

| 块类型                                 | 格式化操作                                                              | 是否调用 `normalize_comma_lines`      |
| ----------------------------------- | ------------------------------------------------------------------ | --------------------------------- |
| `*PARAMETER` / `*PARAMETER_DEFAULT` | `format_parameter_definition_lines` + `normalize_expression_lines` | ❌ 否（对齐已处理逗号间距）                    |
| `*CURVE` / `*TABLE` / `*PATH`       | `format_curve_data_lines`                                          | ❌ 否（列对齐已处理逗号间距）                   |
| `*FUNCTION`                         | `normalize_expression_lines`                                       | ❌ 否（表达式逗号在括号内，不能用简单 CSV split 处理） |
| 其他一般关键字                             | `normalize_comma_lines` + `normalize_expression_lines`             | ✅ 是                               |

关键改动：移除 `*PARAMETER`、`*CURVE`/`*TABLE`/`*PATH`、`*FUNCTION` 在对齐/表达式处理后的 `normalize_comma_lines` 调用。

### 6.4 修正（2026-04-26）——`format_parameter_definition_lines` 双引号对齐

用户给出的示例：

```
%L1   = 0.06           , "Total length"
%L2   = 0.03           , "Reduced width length"
%W1   = 0.015          , "Full width"
%Nx   = floor(%L1 / %dx) , "Mesh density parameter 1"
```

**问题**：原实现把逗号放在 `rhs_pad` 的空格之后（远离数值），导致逗号位置参差不齐，双引号也不对齐。

**修正**：

1. 新增 `split_param_line()` 辅助函数，从**右往左**找最后一个 `, "desc"` 模式，避免误切表达式中的逗号（如 `crv(1, x)`）。
2. `format_parameter_definition_lines` 重新设计对齐逻辑：
   - 逗号**紧跟** `rhs` 后面：`0.06,` 而不是 `0.06           ,`
   - 计算 `max_prefix_len`：所有带描述行中，从行首到逗号（含）的最长长度
   - 逗号后补空格，使**所有双引号对齐在同一列**

格式化后：

```
%L1 = 0.06,             "Total length"
%L2 = 0.03,             "Reduced width length"
%W1 = 0.015,            "Full width"
%W2 = 0.01,             "Reduced width"
%h  = 0.002,            "Thickness"
%dx = 0.002,            "Element size"
%Nx = floor(%L1 / %dx), "Mesh density parameter 1"
```

所有双引号对齐在第 25 列。

### 第六轮文件变更清单

| 文件                                      | 变更类型 | 主要内容                                                                                                            |
| --------------------------------------- | ---- | --------------------------------------------------------------------------------------------------------------- |
| `lua/impetus/commands.lua`              | 修改   | 新增 `normalize_comma_lines`、`normalize_expression_lines`、`simple_beautify_buffer`；`run_clean_command` 新增 `-s` 分支 |
| `IMPETUS_NVIM_COMMANDS_SHORTCUTS_v1.md` | 修改   | 新增 2.6 节 `:clean` 命令说明                                                                                          |

**补充备份时间戳**：`202604260040`

### 6.5 修正（2026-04-26）——`normalize_comma_lines` 前导逗号空格

问题：当 CSV 行第一个字段为空（前导逗号）时，原实现把 `lead`（原前导空格）和 `"  , "` 拼接，导致逗号前空格数 = 原前导空格数 + 1。

例如输入 `"  , a, b"`（2 个空格 + 逗号）→ 输出 `"   , a, b"`（3 个空格 + 逗号）。

修正：第一个字段为空时，丢弃原 `lead`，确保逗号前**恰好一个空格**：

```lua
if trim(fields[1]) == "" then
  out[#out + 1] = " " .. text
else
  out[#out + 1] = lead .. text
end
```

验证：
| 输入 | 输出 |
|------|------|
| `, a, b` | ` , a, b` |
| `  , a, b` | ` , a, b` |
| `    , a, b` | ` , a, b` |
| `a, b, c` | `a, b, c`（非空前导，保留缩进）|

### 第七轮文件变更清单

| 文件                         | 变更类型 | 主要内容                                                                             |
| -------------------------- | ---- | -------------------------------------------------------------------------------- |
| `lua/impetus/commands.lua` | 修改   | 重写 `format_parameter_definition_lines`（双引号对齐）；修正 `normalize_comma_lines`（前导逗号空格） |

**补充备份时间戳**：`202604260053`
