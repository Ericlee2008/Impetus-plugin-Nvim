# Impetus Geometry Preview — Python Viewer 项目文档

> 本文档完整记录 `,v` 快捷键启动的 3D 几何预览器的全部功能、架构设计与实现细节。

---

## 一、项目概述

### 1.1 背景
Impetus 是一个基于关键字（Keyword）的有限元/多物理场仿真前处理语言。用户在编辑 `.k` / `.key` 文件时，需要频繁查看几何模型（Box、Sphere、Cylinder、Pipe 等）的空间分布与相对位置。传统做法依赖外部 CAD 软件或手动想象，效率低下。

### 1.2 目标
在 Neovim 编辑器内通过快捷键 `,v` 一键启动**嵌入式 3D 几何预览器**，实时渲染当前缓冲区中所有 `*COMPONENT_*` 和 `*GEOMETRY_*` 关键字定义的几何对象，并提供完整的交互式查看、选择、过滤、标注功能。

### 1.3 核心特性一览

| 特性 | 说明 |
|------|------|
| **一键预览** | `,v` 快捷键即时启动/更新 3D 视图 |
| **持久化进程** | 后台 Python 进程常驻，后续调用秒开 |
| **多形状支持** | Box、Sphere、Cylinder、Pipe（含空心管） |
| **分组列表** | 左侧对象树按 COMPONENT / GEOMETRY 自动分组 |
| **显隐控制** | 每个对象独立 checkbox + 颜色方块 |
| **三种显示模式** | Framework（线框）、Shadow（表面）、Shadow+Framework（表面+边线） |
| **相机交互** | 左键旋转、右键平移、滚轮缩放、`f` 重置视角 |
| **Hide Select** | `h` 进入，单击或 Alt+框选隐藏对象 |
| **Show Select** | `s` 进入，单击或 Alt+框选标记对象，中键后仅显示已标记 |
| **Identify** | `i` 进入，单击对象显示黄色 ID 标签 |
| **Dockable 工具栏** | 顶部工具栏支持 dock/float 切换 |

---

## 二、系统架构

### 2.1 整体架构图

```
+----------------------------------------------------------+
|  Neovim (Lua)                                            |
|  ┌─────────────────────────────────────────────────────┐ |
|  │  geometry_preview.lua                               │ |
|  │  • 扫描缓冲区关键字块                                │ |
|  │  • 解析 %param 参数引用                              │ |
|  │  • 构建 JSON payload                                 │ |
|  │  • jobstart 启动/管理 Python viewer                  │ |
|  │  • chansend 发送 load/exit 命令                      │ |
|  └─────────────────────────────────────────────────────┘ |
|                           │ stdin (JSON line protocol)   |
|                           ▼                              |
|  +----------------------------------------------------+  |
|  |  Python Viewer (impetus_geometry_viewer.py)        |  |
|  |  • tkinter 主窗口 + 菜单栏 + 左侧面板              |  |
|  |  • VTK RenderWindow 嵌入 tkinter Frame (Win32)     |  |
|  |  • vtkInteractorStyleTrackballCamera 相机控制      |  |
|  |  • 后台线程读取 stdin → queue → on_timer 处理      |  |
|  +----------------------------------------------------+  |
+----------------------------------------------------------+
```

### 2.2 通信协议

Neovim 与 Python viewer 之间通过 **stdin 行协议** 通信：

```json
// 加载场景
{"cmd":"load","payload":{"objects":[...],"file":"...","cursor_row":1}}

// 关闭 viewer
{"cmd":"exit"}
```

Python 端启动一个 daemon 线程阻塞读取 `sys.stdin.readline()`，解析 JSON 后放入 `queue.Queue`，VTK 的 30ms timer (`on_timer`) 从队列取命令并执行。

### 2.3 进程生命周期

| 阶段 | 行为 |
|------|------|
| **首次 `,v`** | Lua 通过 `jobstart` 启动 Python viewer（无参数），等待 500ms 初始化，然后 `chansend` 发送第一个 `load` 命令 |
| **后续 `,v`** | 直接 `chansend` 发送新的 `load` 命令，viewer 热更新场景（秒开） |
| **关闭窗口** | 点击窗口关闭按钮或调用 `close_viewer()` 发送 `exit` 命令 |
| **Neovim 退出** | 若 viewer 仍在运行，由操作系统清理残留进程 |

---

## 三、文件结构

```
nvim/
├── lua/impetus/
│   ├── geometry_preview.lua      # Neovim 端：扫描、解析、payload 构建、job 管理
│   └── config.lua              # 配置默认值（含 geometry_preview 配置）
├── scripts/
│   └── impetus_geometry_viewer.py  # Python 端：完整 viewer 实现
└── PYTHON_VIEWER.md             # 本文档
```

---

## 四、Neovim 端实现（Lua）

### 4.1 关键字扫描与解析

`geometry_preview.lua` 扫描当前缓冲区，识别以下几何关键字：

| 关键字 | 形状 | 特殊处理 |
|--------|------|----------|
| `*COMPONENT_BOX` | box | 支持 `splits`（网格分割） |
| `*COMPONENT_SPHERE` | sphere | — |
| `*COMPONENT_CYLINDER` | cylinder | — |
| `*COMPONENT_PIPE` | pipe | `inner=0` 时降级为 cylinder |
| `*GEOMETRY_BOX` | box | — |
| `*GEOMETRY_SPHERE` / `*GEOMETRY_ELLIPSOID` | sphere | — |
| `*GEOMETRY_PIPE` | pipe | 第三行可选覆盖另一端外径/内径 |
| 其他含 shape 关键词的 | 自动推断 | — |

解析逻辑：
- 每个 keyword block 以 `*` 开头，到下一个 `*` 或文件尾结束
- 跳过注释行（`#`、`$`、`~`）、空行、标题行
- 提取数字参数，支持 `%param` 引用（跨文件参数索引）
- 支持 `*COORDINATE_SYSTEM` 坐标系转换

### 4.2 Payload 结构

```lua
{
  objects = {
    {
      keyword = "*COMPONENT_BOX",
      id = 1,                    -- 第一行第一个值
      shape = "box",
      points = {{x1,y1,z1}, {x2,y2,z2}},
      numbers = {...},           -- 原始数值
      scalars = {...},           -- 半径等标量
      splits = {2,2,2},          -- 网格分割（仅 box）
      coordinate_system = 0,     -- 坐标系 ID
    },
    ...
  },
  file = "E:/.../model.k",
  cursor_row = 42,
}
```

### 4.3 Job 管理

```lua
-- 启动 viewer（首次）
M._viewer_job = vim.fn.jobstart({"python", "scripts/impetus_geometry_viewer.py"}, {
  detach = true,
  on_stderr = function(_, data) ... end,
  on_exit = function(_, code) M._viewer_job = nil end,
})

-- 发送数据
vim.fn.chansend(M._viewer_job, vim.json.encode({cmd="load", payload=all_payload}) .. "\n")
```

**Windows 特殊处理：**
- 配置默认 `python_exe = "pyw"`、`python_args = {"-3"}` 被自动解析为实际 `python.exe`
- 启动前 `taskkill` 清理旧 viewer 进程
- 首次启动后 `vim.wait(500)` 等待 VTK 初始化完成再发送数据

---

## 五、Python 端实现

### 5.1 技术栈

- **GUI 框架**：tkinter（主窗口、菜单、面板、工具栏）
- **3D 渲染**：VTK（vtkRenderer、vtkRenderWindow、vtkRenderWindowInteractor）
- **嵌入方案**：Win32 `SetParent` + `SetWindowLongW` 将 VTK native window 嵌入 tkinter Frame
- **相机交互**：vtkInteractorStyleTrackballCamera

### 5.2 窗口嵌入（Win32）

Windows 上 VTK 默认创建独立窗口，通过以下步骤嵌入 tkinter：

```python
# 1. 获取 tkinter Frame 的 HWND
tk_hwnd = vtk_frame.winfo_id()

# 2. 获取 VTK 窗口的 HWND（通过 GetWindowId 或 FindWindowW）
vtk_hwnd = render_window.GetWindowId()  # 某些 VTK 版本可能不存在

# 3. SetParent 嵌入
user32.SetParent(vtk_hwnd, tk_hwnd)

# 4. 修改窗口样式为 WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN
style = user32.GetWindowLongW(vtk_hwnd, GWL_STYLE)
style &= ~0x00CF0000
style |= WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN
user32.SetWindowLongW(vtk_hwnd, GWL_STYLE, style)

# 5. 强制刷新
user32.SetWindowPos(vtk_hwnd, 0, 0, 0, 0, 0, 0x0277)
user32.RedrawWindow(vtk_hwnd, None, None, 0x0400 | 0x0001 | 0x0080)
user32.ShowWindow(vtk_hwnd, 1)
user32.SetFocus(tk_hwnd)
```

### 5.3 场景构建

`build_scene(renderer, state, payload)` 函数：

1. **清除旧场景**：遍历 `state.objects`，从 renderer 移除所有 actor
2. **重建对象**：按 payload 遍历，为每个对象创建：
   - `actor`：表面 mesh（vtkActor + vtkPolyDataMapper）
   - `edge_actor`：边线轮廓（vtkActor + vtkPolyDataMapper，线条模式）
   - `grid_actor`：网格线（仅 box，vtkActor + 线段）
   - `inner_actor`：内表面线框（仅 hollow pipe）
   - `label_actor`：中心数字标签（vtkBillboardTextActor3D，PickableOff）
3. **相机重置**：计算 bbox，设置 ParallelProjection、Azimuth(30)、Elevation(20)
4. **重建面板**：调用 `state._populate_panel()` 重建 tkinter 对象列表

### 5.4 交互器事件处理

VTK 的事件通过 `AddObserver` 注册到 `interactor` 上。核心挑战是：**在选择模式下保留旋转/平移/缩放**。

#### 5.4.1 事件拦截策略

进入选择模式（hide_select / show_select / identify）时：
- **不**卸下默认 `vtkInteractorStyleTrackballCamera`
- 在 `LeftButtonPressEvent` 中设置 `AbortFlagOn()`，阻止样式开始旋转
- 记录按下位置 `_drag_start`

`MouseMoveEvent` 中：
- 移动距离 ≤ 3 像素：不处理（等待释放判断为单击）
- 移动距离 > 3 像素且无 Alt：手动调用 `state._style.OnLeftButtonDown()` 启动旋转
- 移动距离 > 3 像素且有 Alt：继续 Abort，显示橡皮筋框选

`LeftButtonReleaseEvent` 中：
- 无拖动 + 无 Alt：处理单击选择（hide/show/identify）
- 拖动 + 无 Alt：让样式正常结束旋转（不 Abort）
- 拖动 + Alt：处理框选，Abort

#### 5.4.2 橡皮筋框选

4 条 `vtkLineSource` + `vtkActor` 组成黄色矩形框：

```python
for _ in range(4):
    line = vtk.vtkLineSource()
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputConnection(line.GetOutputPort())
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    actor.GetProperty().SetColor(1.0, 0.85, 0.0)  # 黄色
    actor.GetProperty().SetLineWidth(2.5)
    actor.PickableOff()
    actor.SetVisibility(0)  # 默认隐藏
    renderer.AddActor(actor)
```

框选逻辑：将每个对象的 bbox 8 个角点投影到屏幕坐标，判断是否与橡皮筋矩形重叠。

### 5.5 对象列表面板（tkinter）

左侧 300px 面板，包含：

1. **头部**：Objects 标题 + 对象总数
2. **滚动列表**（Canvas + Scrollbar）
3. **分组标题行**（COMPONENT / GEOMETRY）
   - 可点击展开/折叠（▼/▶）
   - 右侧显示该分组对象数量 `(N)`
4. **对象行**：
   - Checkbox：控制显隐
   - 颜色方块：显示当前颜色，点击弹出颜色选择器
   - 文本：`ID:xxx  *KEYWORD  #N`
   - 点击整行：选中对象（高亮）

`populate_panel()` 函数可重复调用：先 `destroy()` 所有子 widget，再重新创建。

### 5.6 工具栏

顶部 Dockable 工具栏，按钮从左到右：

| 按钮 | 文本 | 功能 |
|------|------|------|
| 📌/📍 | Dock/Float | 切换 docked / floating 模式 |
| ALL | ALL | 显示全部对象 |
| OFF | OFF | 关闭全部对象 |
| H.S | H.S | 进入 Hide Select 模式 |
| S.S | S.S | 进入 Show Select 模式 |
| i | i | 进入 Identify 模式 |
| F | F | Framework 显示模式 |
| S | S | Shadow 显示模式 |
| F+S | F+S | Shadow+Framework 显示模式 |

Floating 模式下，工具栏变成无边框悬浮窗口，顶部有 4px 拖动条。

### 5.7 显示模式控制

`apply_display_mode(idx)` 根据当前模式控制每个对象的 actor 显隐：

| 模式 | actor | edge_actor | grid_actor | inner_actor |
|------|-------|-----------|-----------|-------------|
| framework | 隐藏 | 显示 | 显示 | 显示 |
| shadow | 显示 | 隐藏 | 隐藏 | 隐藏 |
| shadow_framework | 显示 | 显示 | 隐藏 | 隐藏 |

非实体形状（自动推断的 wireframe）始终只显示 `actor`。

### 5.8 Identify 模式

黄色高亮 ID 标签：

```python
id_actor = vtk.vtkBillboardTextActor3D()
id_actor.GetTextProperty().SetFontSize(18)
id_actor.GetTextProperty().SetColor(0.0, 0.0, 0.0)  # 黑色文字
id_actor.GetTextProperty().SetBackgroundColor(1.0, 0.92, 0.23)  # 黄色背景
id_actor.GetTextProperty().SetBackgroundOpacity(1.0)
id_actor.GetTextProperty().BoldOn()
id_actor.GetTextProperty().FrameOn()
id_actor.GetTextProperty().SetFrameColor(0.0, 0.0, 0.0)
id_actor.GetTextProperty().SetFrameWidth(2)
id_actor.PickableOff()
```

单击对象时，标签定位到对象几何中心，显示 `ID:xxx` 或 `#N`。

---

## 六、配置选项

在 `lua/impetus/config.lua` 中：

```lua
geometry_preview = {
  enabled = true,           -- 是否启用预览功能
  python_exe = "python",    -- Python 可执行文件（自动解析 py/pyw）
  python_args = {},         -- Python 启动参数
  viewer_script = nil,      -- 自定义 viewer 脚本路径（nil 则使用默认）
}
```

用户可在 `setup()` 中覆盖：

```lua
require("impetus").setup({
  geometry_preview = {
    enabled = true,
    python_exe = "python3",
  }
})
```

---

## 七、快捷键总览

| 快捷键 | 模式 | 功能 |
|--------|------|------|
| `,v` | 全局 | 启动/更新 3D 预览 |
| `f` / `F` | 相机模式 | Fit All（重置相机） |
| `h` / `H` | 相机模式 | 进入 Hide Select 模式 |
| `s` / `S` | 相机模式 | 进入 Show Select 模式 |
| `i` / `I` | 相机模式 | 进入 Identify 模式 |
| `ESC` | 选择模式 | 退出选择模式 |
| 左键单击 | hide_select | 隐藏对象 |
| 左键单击 | show_select | 标记对象 |
| 左键单击 | identify | 显示对象 ID |
| 左键拖动 | 选择模式 | 旋转模型 |
| Alt + 左键拖动 | hide/show 选择模式 | 框选 |
| 右键单击 | 选择模式 | 退出选择模式 |
| 中键单击 | 选择模式 | 退出选择模式 |
| 滚轮 | 全局 | 缩放 |

---

## 八、开发历程与关键决策

### 8.1 从"每次重启"到"持久化进程"

**最初方案**：每次 `,v` 通过 `jobstart` 启动新的 Python 进程，传递临时 JSON 文件路径。
- 问题：Python 冷启动 + VTK 模块导入需要 2-3 秒，体验差。

**改进方案**：持久化后台进程 + stdin IPC。
- Python 启动一次后常驻内存。
- 后续 `,v` 通过 `chansend` 发送 JSON 命令，viewer 热更新场景。
- 时间从 **2-3 秒 → 0.2 秒以内**。

### 8.2 Windows 嵌入方案选择

**方案 A**：VTK 独立窗口
- 问题：窗口焦点、Z-order、与 tkinter 主窗口不同步。

**方案 B**：Win32 `SetParent` 嵌入
- 将 VTK native window 嵌入 tkinter Frame。
- 通过 `SetWindowLongW` 修改样式为 `WS_CHILD`。
- 解决焦点和 Z-order 问题。
- **采用此方案**。

### 8.3 选择模式与相机交互的冲突

**最初方案**：进入选择模式时 `SetInteractorStyle(None)`。
- 问题：旋转/平移/缩放全部失效。

**改进方案**：保留 `vtkInteractorStyleTrackballCamera`，通过 `AbortFlag` 精细控制。
- 左键按下时 Abort，记录起点。
- 拖动时判断是否启动旋转（手动调用 `OnLeftButtonDown()`）。
- 实现"单击选择、拖动旋转"共存。

### 8.4 Windows stdin 通信陷阱

**陷阱 1**：`select.select([sys.stdin], [], [], 0)` 在 Windows 上不支持文件/stdin，只支持 socket。
- 解决：改用 `threading.Thread` + `queue.Queue`。

**陷阱 2**：`py.exe` / `pyw.exe` 启动器是中间进程，不会转发 stdin 到实际 `python.exe`。
- 解决：Lua 端自动通过 `py -3 -c "import sys; print(sys.executable)"` 解析为实际 `python.exe` 路径。

**陷阱 3**：`pythonw.exe` 没有控制台，stdin 完全断开。
- 解决：强制使用 `python.exe`（有控制台）。

---

## 九、调试指南

### 9.1 查看 Python 端日志

viewer 运行时会写入日志文件：
```
scripts/viewer_debug.log
```

日志内容示例：
```
[stdin_reader] started
[stdin_reader] read line: '{"cmd":"load","payload":{"objects":[...]}}\n'
[stdin_reader] parsed cmd: load
[on_timer] tick
[on_timer] got cmd: load
[on_timer] load payload has 9 objects
[on_timer] build_scene done
```

### 9.2 查看 Neovim 消息

在 Neovim 中执行 `:messages`，查看 viewer 启动、数据发送的状态信息。

### 9.3 手动测试 Python viewer

```bash
cd /path/to/project
python scripts/impetus_geometry_viewer.py
# 然后手动输入 JSON 行：
# {"cmd":"load","payload":{"objects":[...]}}
```

### 9.4 常见问题

| 现象 | 原因 | 解决 |
|------|------|------|
| 窗口弹出但黑屏 | VTK 初始化失败或嵌入失败 | 检查 `viewer_debug.log` 中的 Win32 API 错误 |
| 模型不加载 | Python 端未收到 stdin 数据 | 检查是否使用了 `pyw` 启动器；检查日志 |
| 两个窗口 | 旧 viewer 进程残留 | 重启 Neovim 前手动 taskkill 旧 pythonw/python 进程 |
| 不能旋转 | InteractorStyle 被移除或 AbortFlag 设置错误 | 检查 `on_timer` 中的样式恢复逻辑 |
| 对象列表为空 | `populate_panel` 未调用或 `state.objects` 为空 | 检查 `build_scene` 是否成功执行 |

---

## 十、未来扩展方向

1. **坐标系变换**：完整支持 `*COORDINATE_SYSTEM` 的旋转/平移矩阵
2. **网格显示**：显示 Box 的 `splits` 分割网格
3. **动画/时间步**：支持 `*TIME` 关键字，按时间步切换几何状态
4. **测量工具**：距离、角度测量
5. **截面剖切**：XYZ 平面剖切显示
6. **材质/颜色预设**：按 keyword 自动分配行业常用配色
7. **多文件支持**：跨文件 `*INCLUDE` 的几何聚合显示

---

## 十一、作者与维护

本项目为 Impetus Neovim 插件的子模块，主要贡献者为 EricLee（用户）。

如有问题或功能建议，请通过项目 Issue 或本文档联系维护者。
