# Impetus Neovim 命令与快捷键手册（精简版）

本文档基于当前 `impetus.nvim` 实现，目标是把常用操作变成短命令与高频快捷键。

## 1. 快捷键（Buffer Local）

默认使用 `<localleader>`，你当前配置中是 `,`。

### 1.1 关键字块编辑

| 快捷键 | 功能 |
| ---- | ------------------ |
| `,c` | 注释/反注释当前关键字块（自动切换） |
| `dk` | 删除当前关键字块 |
| `,y` | 复制当前关键字块到下方 |
| `,j` | 当前关键字块下移 |
| `,k` | 当前关键字块上移 |
| `,n` | 跳到下一个关键字 |
| `,N` | 跳到上一个关键字 |
| `,I` | 插入当前关键字模板 |
| `,Q` | 关闭 popup / quickfix |
| `gh` | 显示 intrinsic 函数/变量悬浮文档 |
| `<C-Space>` | 触发 Impetus 补全 |

### 1.2 折叠

| 快捷键 | 功能 |
| ---- | ----------------- |
| `,f` | 折叠/展开全部关键字块（自动切换） |
| `,t` | 切换当前折叠 |
| `,F` | 折叠/展开全部控制块（~if/~repeat/~convert） |
| `,T` | 切换当前控制块折叠 |
| `,z` | 折叠/展开全部关键字 + 控制块 |

### 1.3 帮助与补全

| 快捷键 | 功能 |
| ---- | ------------------------------------ |
| `,h` | 切换右侧帮助窗口 |
| `,,` | 触发引用/选项补全（omnifunc） |
| `,R` | 同 `,,` |
| `,i` | 切换信息面板 |
| `,r` | 重载帮助数据库 |
| `,q` | 关闭当前窗口（force） |
| `,o` | 在左侧分屏打开 `*INCLUDE/*SCRIPT_PYTHON` 文件 |
| `K` | 光标下文档 |

### 1.4 导航与外部文件

| 快捷键 | 功能 |
| ---- | --------------------- |
| `gd` | 跳转到参数定义（支持 `fcn(id)` / `crv(id)`） |
| `gr` | 列出参数引用（quickfix，支持 `fcn(id)` / `crv(id)`） |
| `%` | 匹配跳转（控制指令 / 括号） |
| `,m` | 跳转到匹配的控制块（~if/~end_if 等） |
| `,b` | 检查未匹配的控制块 |
| `,O` | 在 Impetus GUI 中打开当前文件 |

## 2. 短命令（C* 系列）

### 2.1 检查与帮助

| 命令 | 等效命令 | 功能 |
| ----------------- | -------------------- | ------------------- |
| `:Ccheck` / `:Cc` / `:Chk` | `:ImpetusLint` | 模型检查（Error / Warning / Suspicion 三级） |
| `:Chelp` | `:ImpetusCheatSheet` | 打开快速帮助弹出窗口 |
| `:Ch` | `:ImpetusHelpToggle` | 切换帮助窗口 |
| `:Cinfo` / `:Ci` | `:ImpetusInfo` | 模型统计信息 |

### 2.2 注册表与刷新

| 命令 | 等效命令 | 功能 |
| -------------------- | ----------------- | -------------- |
| `:Cregistry` / `:Cr` | `:ImpetusObjects` | 查看当前文件对象 ID 汇总 |
| `:Crefresh` / `:CR` | `:ImpetusRefresh` | 一键刷新插件与帮助数据库 |
| `:Creload` / `:Crl` | `:ImpetusReload` | 只重载帮助数据库 |

### 2.3 引用导航

| 命令 | 等效命令 | 功能 |
| ---------------- | --------------------- | ------ |
| `:Cgoto` / `:Cg` | `:ImpetusParamDef` | 跳转参数定义 |
| `:Cfind` / `:Cw` | `:ImpetusParamRefs` | 查找参数引用 |
| `:Cref` / `:Cf` | `:ImpetusRefComplete` | 触发引用补全 |

### 2.4 折叠与诊断

| 命令 | 等效命令 | 功能 |
| --------------------------- | ----------------- | -------------------- |
| `:Cblock` | `:ImpetusCheckBlocks` | 检查未匹配控制块 |
| `:Cfoldbounds` | `:ImpetusFoldBounds` | 显示折叠边界分析 |
| `:Ctrykwfold` | `:ImpetusTryKeywordFold` | 尝试当前关键字块折叠 |
| `:Ctryctlfold` | `:ImpetusTryControlFold` | 尝试当前控制块折叠 |
| `:Cfolddbg` | `:ImpetusFoldDoctor` | 打开折叠诊断视图 |

### 2.5 外部打开

| 命令 | 等效命令 | 功能 |
| --------------------------- | ----------------- | -------------------- |
| `:gui` / `:Cgui` / `:Copen` / `:Co` | `:ImpetusOpenGUI` | 在 Impetus GUI 打开当前文件 |

## 3. 已集成能力（和命令联动）

- 关键字折叠（按 `*KEYWORD` 分块）
- 参数定义/引用索引
- 对象 ID 数据库（part/material/function/geometry/command/curve/prop_damage/prop_thermal/eos）
- 上下文 ID 补全（例如 `typeid` 可建议已有 `part id`）
- 条件与迭代块基础合法性检查：
  - `~if/~else_if/~else/~end_if`
  - `~repeat/~end_repeat`
  - `~convert_from_/~end_convert`
- **`gd` / `gr` 支持 `fcn(id)` / `crv(id)` 跳转**：当光标位于函数或曲线引用上时，可直接跳转到对应的 `*FUNCTION` / `*CURVE` 定义
- **Intrinsic 语法高亮与文档**：
  - `intrinsic.k` 中的函数和变量自动高亮（绿色函数、黄色变量）
  - 按 `gh` 可在悬浮窗口查看 intrinsic 的签名、类型和说明
- **物理合理性检查（`:Ccheck`）**：
  - 自动检测 `*UNIT_SYSTEM` 单位制
  - 对 `*MAT_*` / `*MAT_OBJECT` 的密度、杨氏模量等进行数量级校验
  - 对坐标/尺寸、速度、质量等进行常识性边界检查
  - 示例：SI 单位制下钢材密度应为 ~7800 kg/m³，若输入 7.8 会报 Suspicion

## 4. 建议使用流

1. 录入关键字：`*` 触发补全，`Tab` 跳字段。
2. 参数/引用阶段：`,,` 触发候选弹窗（对象ID/选项），`gd/gr` 跳转定义与引用。
3. 结构整理阶段：`,f` 折叠、`,n`/`,N` 导航、`,j`/`,k` 移块。
4. 校验阶段：`:Cc`，按 quickfix 逐项修复（Error → Warning → Suspicion）。

## 5. 备注

- 所有快捷键均为 Impetus 文件类型下的 buffer-local 映射，不污染其他文件。
- 若你修改了 `maplocalleader`，请将表中的 `,` 替换为你的 localleader。
- `:Ccheck` 的三级诊断：
  - **Error**（`E`）：结构错误、未定义引用、重复 ID、缺少必要字段
  - **Warning**（`W`）：未知关键字、空块、未使用参数、字段数不符
  - **Suspicion**（`?`）：物理值超出常识范围（密度/模量/尺度/速度等）
