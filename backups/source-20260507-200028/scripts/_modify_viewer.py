import re

with open('scripts/impetus_geometry_viewer.py', encoding='utf-8') as f:
    content = f.read()

# 1. Add `import select` after `import sys`
content = content.replace(
    'import json\nimport math\nimport os\nimport sys\n',
    'import json\nimport math\nimport os\nimport select\nimport sys\n'
)

# 2. Add module-level UI constants after DEFAULT_COLORS
ui_constants = '''
_UI_BG = "#1a1d23"
_UI_ROW_BG = "#242830"
_UI_ROW_SEL = "#3a4050"
_UI_FG = "#d1d5db"
_UI_FG_DIM = "#9ca3af"
_UI_BORDER = "#4b5563"
_UI_BTN_BG = "#374151"
_UI_BTN_HOVER = "#4b5563"
'''
content = content.replace(
    '(0.40, 0.75, 0.55),\n]\n\n\ndef get_object_opacity(keyword):',
    '(0.40, 0.75, 0.55),\n]' + ui_constants + '\n\ndef get_object_opacity(keyword):'
)

# 3. Insert populate_panel before build_ui
populate_panel_func = '''def populate_panel(state):
    def rgb_to_hex(rgb):
        return "#%02x%02x%02x" % (int(rgb[0] * 255), int(rgb[1] * 255), int(rgb[2] * 255))

    def on_visibility_toggle(idx):
        obj = state.objects[idx]
        new_val = not obj.get("visible", True)
        state.set_visibility(idx, new_val)

    def on_color_click(idx):
        obj = state.objects[idx]
        current = obj.get("color", DEFAULT_COLORS[obj.get("color_idx", idx) % len(DEFAULT_COLORS)])
        hex_color = rgb_to_hex(current)
        result = colorchooser.askcolor(initialcolor=hex_color, title=f"Color for #{idx + 1}")
        if result and result[1]:
            def hex_to_rgb(hex_str):
                hex_str = hex_str.lstrip("#")
                return tuple(int(hex_str[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
            new_rgb = hex_to_rgb(result[1])
            state.set_color(idx, new_rgb)

    def on_row_click(idx):
        state.select_object(idx)

    for child in state._list_frame.winfo_children():
        child.destroy()
    state.panel_rows.clear()

    # Group objects by keyword prefix
    groups = {"COMPONENT": [], "GEOMETRY": []}
    for i, obj in enumerate(state.objects):
        kw = (obj.get("keyword") or "").upper()
        if kw.startswith("*COMPONENT_"):
            groups["COMPONENT"].append(i)
        elif kw.startswith("*GEOMETRY_"):
            groups["GEOMETRY"].append(i)
        else:
            groups["GEOMETRY"].append(i)

    def _make_group_header(parent, title):
        header = tk.Frame(parent, bg="#1e2229", padx=6, pady=4)
        header.pack(fill="x", pady=(6, 0))
        arrow_lbl = tk.Label(header, text="▼", font=("Segoe UI", 9),
                             bg="#1e2229", fg=_UI_FG_DIM)
        arrow_lbl.pack(side="left")
        title_lbl = tk.Label(header, text=title, font=("Segoe UI", 10, "bold"),
                             bg="#1e2229", fg="#f3f4f6")
        title_lbl.pack(side="left", padx=(4, 0))
        count_lbl = tk.Label(header, text="", font=("Segoe UI", 9),
                             bg="#1e2229", fg=_UI_FG_DIM)
        count_lbl.pack(side="right")
        container = tk.Frame(parent, bg=_UI_BG)
        container.pack(fill="x")
        expanded = True

        def _toggle():
            nonlocal expanded
            expanded = not expanded
            if expanded:
                container.pack(fill="x")
                arrow_lbl.configure(text="▼")
            else:
                container.pack_forget()
                arrow_lbl.configure(text="▶")

        header.bind("<Button-1>", lambda e: _toggle())
        arrow_lbl.bind("<Button-1>", lambda e: _toggle())
        title_lbl.bind("<Button-1>", lambda e: _toggle())
        return container, count_lbl

    group_containers = {}
    group_counts = {}
    for gname, gindices in groups.items():
        if not gindices:
            continue
        container, count_lbl = _make_group_header(state._list_frame, gname)
        group_containers[gname] = container
        group_counts[gname] = count_lbl
        count_lbl.configure(text=f"({len(gindices)})")

    for i, obj in enumerate(state.objects):
        kw = (obj.get("keyword") or "").upper()
        if kw.startswith("*COMPONENT_"):
            parent = group_containers.get("COMPONENT", state._list_frame)
        elif kw.startswith("*GEOMETRY_"):
            parent = group_containers.get("GEOMETRY", state._list_frame)
        else:
            parent = group_containers.get("GEOMETRY", state._list_frame)

        row = tk.Frame(parent, bg=_UI_ROW_BG, padx=6, pady=5)
        row.pack(fill="x", pady=2)

        color = obj.get("color", DEFAULT_COLORS[i % len(DEFAULT_COLORS)])
        color_hex = rgb_to_hex(color)

        # Checkbox
        var = tk.IntVar(value=1)
        cb = tk.Checkbutton(row, variable=var, bg=_UI_ROW_BG,
                            activebackground=_UI_ROW_BG,
                            command=lambda idx=i: on_visibility_toggle(idx))
        cb.pack(side="left", padx=(0, 4))

        # Color swatch
        swatch = tk.Label(row, bg=color_hex, width=2, height=1,
                          relief="solid", bd=1, highlightbackground=_UI_BORDER)
        swatch.pack(side="left", padx=(0, 6))

        # Keyword + ID
        kw_str = obj.get("keyword", "?")
        oid = obj.get("id")
        display = f"{kw_str}  #{i + 1}"
        if oid:
            display = f"ID:{oid}  {display}"
        kw_lbl = tk.Label(row, text=display, font=("Consolas", 10),
                          bg=_UI_ROW_BG, fg=_UI_FG, anchor="w")
        kw_lbl.pack(side="left")

        # Bindings
        swatch.bind("<Button-1>", lambda e, idx=i: on_color_click(idx))
        row.bind("<Button-1>", lambda e, idx=i: on_row_click(idx))
        kw_lbl.bind("<Button-1>", lambda e, idx=i: on_row_click(idx))

        state.panel_rows.append({
            "frame": row,
            "swatch": swatch,
            "var": var,
        })

    state._refresh_panel()

    if hasattr(state, "_total_label") and state._total_label:
        state._total_label.configure(text=f"Total: {len(state.objects)}")


'''
content = content.replace(
    'def build_ui(state, render_window, on_close_callback):',
    populate_panel_func + 'def build_ui(state, render_window, on_close_callback):'
)

# 4. In build_ui: save list_frame and total label, replace row creation with populate_panel(state)
old_build_ui_middle = '''    list_frame = tk.Frame(canvas, bg=BG)

    def on_frame_configure(event):'''
new_build_ui_middle = '''    list_frame = tk.Frame(canvas, bg=BG)
    state._list_frame = list_frame

    def on_frame_configure(event):'''
content = content.replace(old_build_ui_middle, new_build_ui_middle)

old_total_label = '''    tk.Label(header, text=f"Total: {len(state.objects)}", font=("Segoe UI", 9),
             bg=BG, fg=FG_DIM).pack(anchor="w")'''
new_total_label = '''    state._total_label = tk.Label(header, text=f"Total: {len(state.objects)}", font=("Segoe UI", 9),
             bg=BG, fg=FG_DIM)
    state._total_label.pack(anchor="w")'''
content = content.replace(old_total_label, new_total_label)

# Now replace the entire row creation block in build_ui with populate_panel(state)
# This block goes from "def on_visibility_toggle(idx):" to "state._refresh_panel()" inclusive,
# followed by "\n\n    # Bottom controls: Show All / Turn Off All"
old_row_block = '''    def on_visibility_toggle(idx):
        obj = state.objects[idx]
        new_val = not obj.get("visible", True)
        state.set_visibility(idx, new_val)

    def on_color_click(idx):
        obj = state.objects[idx]
        current = obj.get("color", DEFAULT_COLORS[obj.get("color_idx", idx) % len(DEFAULT_COLORS)])
        hex_color = rgb_to_hex(current)
        result = colorchooser.askcolor(initialcolor=hex_color, title=f"Color for #{idx + 1}")
        if result and result[1]:
            new_rgb = hex_to_rgb(result[1])
            state.set_color(idx, new_rgb)

    def on_row_click(idx):
        state.select_object(idx)

    # Group objects by keyword prefix
    groups = {"COMPONENT": [], "GEOMETRY": []}
    for i, obj in enumerate(state.objects):
        kw = (obj.get("keyword") or "").upper()
        if kw.startswith("*COMPONENT_"):
            groups["COMPONENT"].append(i)
        elif kw.startswith("*GEOMETRY_"):
            groups["GEOMETRY"].append(i)
        else:
            groups["GEOMETRY"].append(i)

    def _make_group_header(parent, title):
        header = tk.Frame(parent, bg="#1e2229", padx=6, pady=4)
        header.pack(fill="x", pady=(6, 0))
        arrow_lbl = tk.Label(header, text="▼", font=("Segoe UI", 9),
                             bg="#1e2229", fg=FG_DIM)
        arrow_lbl.pack(side="left")
        title_lbl = tk.Label(header, text=title, font=("Segoe UI", 10, "bold"),
                             bg="#1e2229", fg="#f3f4f6")
        title_lbl.pack(side="left", padx=(4, 0))
        count_lbl = tk.Label(header, text="", font=("Segoe UI", 9),
                             bg="#1e2229", fg=FG_DIM)
        count_lbl.pack(side="right")
        container = tk.Frame(parent, bg=BG)
        container.pack(fill="x")
        expanded = True

        def _toggle():
            nonlocal expanded
            expanded = not expanded
            if expanded:
                container.pack(fill="x")
                arrow_lbl.configure(text="▼")
            else:
                container.pack_forget()
                arrow_lbl.configure(text="▶")

        header.bind("<Button-1>", lambda e: _toggle())
        arrow_lbl.bind("<Button-1>", lambda e: _toggle())
        title_lbl.bind("<Button-1>", lambda e: _toggle())
        return container, count_lbl

    group_containers = {}
    group_counts = {}
    for gname, gindices in groups.items():
        if not gindices:
            continue
        container, count_lbl = _make_group_header(list_frame, gname)
        group_containers[gname] = container
        group_counts[gname] = count_lbl
        count_lbl.configure(text=f"({len(gindices)})")

    for i, obj in enumerate(state.objects):
        kw = (obj.get("keyword") or "").upper()
        if kw.startswith("*COMPONENT_"):
            parent = group_containers.get("COMPONENT", list_frame)
        elif kw.startswith("*GEOMETRY_"):
            parent = group_containers.get("GEOMETRY", list_frame)
        else:
            parent = group_containers.get("GEOMETRY", list_frame)

        row = tk.Frame(parent, bg=ROW_BG, padx=6, pady=5)
        row.pack(fill="x", pady=2)

        color = obj.get("color", DEFAULT_COLORS[i % len(DEFAULT_COLORS)])
        color_hex = rgb_to_hex(color)

        # Checkbox
        var = tk.IntVar(value=1)
        cb = tk.Checkbutton(row, variable=var, bg=ROW_BG,
                            activebackground=ROW_BG,
                            command=lambda idx=i: on_visibility_toggle(idx))
        cb.pack(side="left", padx=(0, 4))

        # Color swatch
        swatch = tk.Label(row, bg=color_hex, width=2, height=1,
                          relief="solid", bd=1, highlightbackground=BORDER)
        swatch.pack(side="left", padx=(0, 6))

        # Keyword + ID
        kw_str = obj.get("keyword", "?")
        oid = obj.get("id")
        display = f"{kw_str}  #{i + 1}"
        if oid:
            display = f"ID:{oid}  {display}"
        kw_lbl = tk.Label(row, text=display, font=("Consolas", 10),
                          bg=ROW_BG, fg=FG, anchor="w")
        kw_lbl.pack(side="left")

        # Bindings
        swatch.bind("<Button-1>", lambda e, idx=i: on_color_click(idx))
        row.bind("<Button-1>", lambda e, idx=i: on_row_click(idx))
        kw_lbl.bind("<Button-1>", lambda e, idx=i: on_row_click(idx))

        state.panel_rows.append({
            "frame": row,
            "swatch": swatch,
            "var": var,
        })

    state._refresh_panel()

    # Bottom controls: Show All / Turn Off All'''
new_row_block = '''    populate_panel(state)

    # Bottom controls: Show All / Turn Off All'''

if old_row_block in content:
    content = content.replace(old_row_block, new_row_block)
else:
    print("WARNING: Could not find old_row_block to replace!")
    # Try to find what's there
    idx = content.find("    def on_visibility_toggle(idx):")
    if idx != -1:
        print(f"Found on_visibility_toggle at position {idx}")
        print("Context:")
        print(repr(content[idx:idx+200]))

# 5. Insert build_scene before show_window
build_scene_func = '''def build_scene(state, payload):
    objects = payload.get("objects")
    if not objects:
        objects = [payload]

    renderer = state.renderer

    # Remove old actors
    for obj in state.objects:
        for key in ("actor", "edge_actor", "grid_actor", "inner_actor", "label_actor"):
            a = obj.get(key)
            if a:
                renderer.RemoveActor(a)

    state.objects.clear()
    state.panel_rows.clear()
    state.selected_idx = -1

    all_verts = []
    viewer_objects = []

    for obj_idx, obj in enumerate(objects):
        shape = (obj.get("shape") or "").lower()
        pts = obj.get("points") or []
        splits = obj.get("splits") or []
        keyword = obj.get("keyword", "")
        color = DEFAULT_COLORS[obj_idx % len(DEFAULT_COLORS)]
        opacity = get_object_opacity(keyword)
        solid = is_solid_keyword(keyword)

        if shape == "box" and pts and len(pts) >= 2:
            mins = pts[0]
            maxs = pts[1]
            all_verts.extend([mins, maxs])
            surface_actor = build_box_surface_actor(mins, maxs, color=color, opacity=opacity)
            edge_actor = build_box_edge_actor(mins, maxs, color=color)
            renderer.AddActor(surface_actor)
            renderer.AddActor(edge_actor)
            grid_actor = build_box_grid_actor(mins, maxs, splits, color=color)
            if grid_actor is not None:
                renderer.AddActor(grid_actor)
            center = [(mins[i] + maxs[i]) / 2.0 for i in range(3)]
            label_actor = build_center_label(str(obj_idx + 1), center, color=color)
            renderer.AddActor(label_actor)
            viewer_objects.append({
                "actor": surface_actor,
                "edge_actor": edge_actor,
                "grid_actor": grid_actor,
                "label_actor": label_actor,
                "keyword": keyword,
                "shape": shape,
                "color_idx": obj_idx % len(DEFAULT_COLORS),
                "color": color,
                "opacity": opacity,
                "visible": True,
                "points": pts,
                "splits": splits,
                "scalars": obj.get("scalars") or [],
                "id": obj.get("id"),
            })
        elif shape == "sphere":
            center = pts[0] if pts else [0.0, 0.0, 0.0]
            radius = abs(float(obj.get("scalars")[0])) if obj.get("scalars") else 1.0
            all_verts.extend([
                [center[0] - radius, center[1] - radius, center[2] - radius],
                [center[0] + radius, center[1] + radius, center[2] + radius],
            ])
            surf = build_sphere_surface_actor(center, radius, color=color, opacity=opacity)
            edge_actor = build_sphere_edge_actor(center, radius, color=color)
            renderer.AddActor(surf)
            renderer.AddActor(edge_actor)
            label_actor = build_center_label(str(obj_idx + 1), center, color=color)
            renderer.AddActor(label_actor)
            viewer_objects.append({
                "actor": surf,
                "edge_actor": edge_actor,
                "grid_actor": None,
                "label_actor": label_actor,
                "keyword": keyword,
                "shape": shape,
                "color_idx": obj_idx % len(DEFAULT_COLORS),
                "color": color,
                "opacity": opacity,
                "visible": True,
                "points": pts,
                "scalars": obj.get("scalars") or [],
                "id": obj.get("id"),
            })
        elif shape == "cylinder" or shape == "pipe":
            a = pts[0] if len(pts) >= 1 else [0.0, 0.0, -0.5]
            b = pts[1] if len(pts) >= 2 else [0.0, 0.0, 0.5]
            scalars = obj.get("scalars") or []
            outer_radius = abs(float(scalars[0])) if len(scalars) >= 1 else 0.5
            inner_radius = abs(float(scalars[1])) if len(scalars) >= 2 else 0.0
            all_verts.extend([a, b])
            # Outer cylinder surface
            surf = build_cylinder_surface_actor(a, b, outer_radius, color=color, opacity=opacity)
            edge_actor = build_cylinder_edge_actor(a, b, outer_radius, color=color)
            renderer.AddActor(surf)
            renderer.AddActor(edge_actor)
            # Inner wireframe if hollow
            inner_actor = None
            if inner_radius > 1e-6:
                inner_verts, inner_edges = build_pipe(pts, scalars)
                inner_actor = build_wireframe_actor(inner_verts, inner_edges, color=color)
                inner_actor.GetProperty().SetLineWidth(1.5)
                renderer.AddActor(inner_actor)
            center = get_object_center(obj)
            label_actor = build_center_label(str(obj_idx + 1), center, color=color)
            renderer.AddActor(label_actor)
            viewer_objects.append({
                "actor": surf,
                "edge_actor": edge_actor,
                "grid_actor": None,
                "inner_actor": inner_actor,
                "label_actor": label_actor,
                "keyword": keyword,
                "shape": shape,
                "color_idx": obj_idx % len(DEFAULT_COLORS),
                "color": color,
                "opacity": opacity,
                "visible": True,
                "points": pts,
                "scalars": scalars,
                "id": obj.get("id"),
            })
        else:
            verts, edges = build_model(obj)
            if verts:
                all_verts.extend(verts)
                wf_actor = build_wireframe_actor(verts, edges, color=color)
                renderer.AddActor(wf_actor)
                center = get_object_center(obj)
                label_actor = build_center_label(str(obj_idx + 1), center, color=color)
                renderer.AddActor(label_actor)
                viewer_objects.append({
                    "actor": wf_actor,
                    "edge_actor": None,
                    "grid_actor": None,
                    "label_actor": label_actor,
                    "keyword": keyword,
                    "shape": shape,
                    "color_idx": obj_idx % len(DEFAULT_COLORS),
                    "color": color,
                    "opacity": opacity,
                    "visible": True,
                    "points": pts,
                    "scalars": obj.get("scalars") or [],
                    "id": obj.get("id"),
                })

    if all_verts:
        mins, maxs = bbox(all_verts)
    else:
        mins, maxs = [0.0, 0.0, 0.0], [1.0, 1.0, 1.0]
    diag = vec_len(vec_sub(maxs, mins))
    if diag <= 1e-9:
        diag = 1.0

    state.objects = viewer_objects

    # Reset camera
    renderer.ResetCamera()
    camera = renderer.GetActiveCamera()
    camera.ParallelProjectionOn()
    camera.Azimuth(30)
    camera.Elevation(20)
    camera.Roll(-12)
    camera.OrthogonalizeViewUp()
    camera.Zoom(1.15)
    camera.SetParallelScale(diag * 0.65)
    renderer.ResetCameraClippingRange()

    populate_panel(state)
    state._request_render()


'''
content = content.replace(
    'def show_window(payload):',
    build_scene_func + 'def show_window():'
)

# 6. Replace show_window body
old_show_window = '''def show_window(payload):
    objects = payload.get("objects")
    if not objects:
        objects = [payload]

    renderer = vtk.vtkRenderer()
    renderer.SetBackground(0.05, 0.06, 0.09)
    renderer.SetBackground2(0.08, 0.1, 0.14)
    renderer.GradientBackgroundOn()

    # Unique window name so FindWindow can locate it reliably
    win_title = f"ImpetusVTK-{os.getpid()}"
    render_window = vtk.vtkRenderWindow()
    render_window.AddRenderer(renderer)
    render_window.SetWindowName(win_title)

    interactor = vtk.vtkRenderWindowInteractor()
    interactor.SetRenderWindow(render_window)
    style = vtk.vtkInteractorStyleTrackballCamera()
    interactor.SetInteractorStyle(style)

    all_verts = []
    viewer_objects = []

    for obj_idx, obj in enumerate(objects):
        shape = (obj.get("shape") or "").lower()
        pts = obj.get("points") or []
        splits = obj.get("splits") or []
        keyword = obj.get("keyword", "")
        color = DEFAULT_COLORS[obj_idx % len(DEFAULT_COLORS)]
        opacity = get_object_opacity(keyword)
        solid = is_solid_keyword(keyword)

        if shape == "box" and pts and len(pts) >= 2:
            mins = pts[0]
            maxs = pts[1]
            all_verts.extend([mins, maxs])
            surface_actor = build_box_surface_actor(mins, maxs, color=color, opacity=opacity)
            edge_actor = build_box_edge_actor(mins, maxs, color=color)
            renderer.AddActor(surface_actor)
            renderer.AddActor(edge_actor)
            grid_actor = build_box_grid_actor(mins, maxs, splits, color=color)
            if grid_actor is not None:
                renderer.AddActor(grid_actor)
            center = [(mins[i] + maxs[i]) / 2.0 for i in range(3)]
            label_actor = build_center_label(str(obj_idx + 1), center, color=color)
            renderer.AddActor(label_actor)
            viewer_objects.append({
                "actor": surface_actor,
                "edge_actor": edge_actor,
                "grid_actor": grid_actor,
                "label_actor": label_actor,
                "keyword": keyword,
                "shape": shape,
                "color_idx": obj_idx % len(DEFAULT_COLORS),
                "color": color,
                "opacity": opacity,
                "visible": True,
                "points": pts,
                "splits": splits,
                "scalars": obj.get("scalars") or [],
                "id": obj.get("id"),
            })
        elif shape == "sphere":
            center = pts[0] if pts else [0.0, 0.0, 0.0]
            radius = abs(float(obj.get("scalars")[0])) if obj.get("scalars") else 1.0
            all_verts.extend([
                [center[0] - radius, center[1] - radius, center[2] - radius],
                [center[0] + radius, center[1] + radius, center[2] + radius],
            ])
            surf = build_sphere_surface_actor(center, radius, color=color, opacity=opacity)
            edge_actor = build_sphere_edge_actor(center, radius, color=color)
            renderer.AddActor(surf)
            renderer.AddActor(edge_actor)
            label_actor = build_center_label(str(obj_idx + 1), center, color=color)
            renderer.AddActor(label_actor)
            viewer_objects.append({
                "actor": surf,
                "edge_actor": edge_actor,
                "grid_actor": None,
                "label_actor": label_actor,
                "keyword": keyword,
                "shape": shape,
                "color_idx": obj_idx % len(DEFAULT_COLORS),
                "color": color,
                "opacity": opacity,
                "visible": True,
                "points": pts,
                "scalars": obj.get("scalars") or [],
                "id": obj.get("id"),
            })
        elif shape == "cylinder" or shape == "pipe":
            a = pts[0] if len(pts) >= 1 else [0.0, 0.0, -0.5]
            b = pts[1] if len(pts) >= 2 else [0.0, 0.0, 0.5]
            scalars = obj.get("scalars") or []
            outer_radius = abs(float(scalars[0])) if len(scalars) >= 1 else 0.5
            inner_radius = abs(float(scalars[1])) if len(scalars) >= 2 else 0.0
            all_verts.extend([a, b])
            # Outer cylinder surface
            surf = build_cylinder_surface_actor(a, b, outer_radius, color=color, opacity=opacity)
            edge_actor = build_cylinder_edge_actor(a, b, outer_radius, color=color)
            renderer.AddActor(surf)
            renderer.AddActor(edge_actor)
            # Inner wireframe if hollow
            inner_actor = None
            if inner_radius > 1e-6:
                inner_verts, inner_edges = build_pipe(pts, scalars)
                inner_actor = build_wireframe_actor(inner_verts, inner_edges, color=color)
                inner_actor.GetProperty().SetLineWidth(1.5)
                renderer.AddActor(inner_actor)
            center = get_object_center(obj)
            label_actor = build_center_label(str(obj_idx + 1), center, color=color)
            renderer.AddActor(label_actor)
            viewer_objects.append({
                "actor": surf,
                "edge_actor": edge_actor,
                "grid_actor": None,
                "inner_actor": inner_actor,
                "label_actor": label_actor,
                "keyword": keyword,
                "shape": shape,
                "color_idx": obj_idx % len(DEFAULT_COLORS),
                "color": color,
                "opacity": opacity,
                "visible": True,
                "points": pts,
                "scalars": scalars,
                "id": obj.get("id"),
            })
        else:
            verts, edges = build_model(obj)
            if verts:
                all_verts.extend(verts)
                wf_actor = build_wireframe_actor(verts, edges, color=color)
                renderer.AddActor(wf_actor)
                center = get_object_center(obj)
                label_actor = build_center_label(str(obj_idx + 1), center, color=color)
                renderer.AddActor(label_actor)
                viewer_objects.append({
                    "actor": wf_actor,
                    "edge_actor": None,
                    "grid_actor": None,
                    "label_actor": label_actor,
                    "keyword": keyword,
                    "shape": shape,
                    "color_idx": obj_idx % len(DEFAULT_COLORS),
                    "color": color,
                    "opacity": opacity,
                    "visible": True,
                    "points": pts,
                    "scalars": obj.get("scalars") or [],
                    "id": obj.get("id"),
                })

    if all_verts:
        mins, maxs = bbox(all_verts)
    else:
        mins, maxs = [0.0, 0.0, 0.0], [1.0, 1.0, 1.0]
    diag = vec_len(vec_sub(maxs, mins))
    if diag <= 1e-9:
        diag = 1.0

    axes = build_axes_actor()
    om = vtk.vtkOrientationMarkerWidget()
    om.SetOrientationMarker(axes)
    om.SetInteractor(interactor)
    om.SetViewport(0.0, 0.0, 0.18, 0.18)
    om.SetEnabled(True)
    om.InteractiveOff()

    state = ViewerState(viewer_objects, renderer, interactor, om=om)
    state._style = style  # save for mode switching

    # Identify-mode floating label (hidden by default)
    id_actor = vtk.vtkBillboardTextActor3D()
    id_actor.GetTextProperty().SetFontSize(18)
    id_actor.GetTextProperty().SetColor(0.0, 0.0, 0.0)
    id_actor.GetTextProperty().SetBackgroundColor(1.0, 0.92, 0.23)
    id_actor.GetTextProperty().SetBackgroundOpacity(1.0)
    id_actor.GetTextProperty().BoldOn()
    id_actor.GetTextProperty().FrameOn()
    id_actor.GetTextProperty().SetFrameColor(0.0, 0.0, 0.0)
    id_actor.GetTextProperty().SetFrameWidth(2)
    id_actor.PickableOff()
    id_actor.SetVisibility(0)
    renderer.AddActor(id_actor)
    state._identify_actor = id_actor

    # Rubberband lines for box-pick-hide mode
    def display_to_world(display_x, display_y, renderer):
        coord = vtk.vtkCoordinate()
        coord.SetCoordinateSystemToDisplay()
        coord.SetValue(float(display_x), float(display_y), 0.0)
        return coord.GetComputedWorldValue(renderer)

    for _ in range(4):
        line = vtk.vtkLineSource()
        mapper = vtk.vtkPolyDataMapper()
        mapper.SetInputConnection(line.GetOutputPort())
        actor = vtk.vtkActor()
        actor.SetMapper(mapper)
        actor.GetProperty().SetColor(1.0, 0.85, 0.0)
        actor.GetProperty().SetLineWidth(2.5)
        actor.PickableOff()
        actor.SetVisibility(0)
        renderer.AddActor(actor)
        state._rubberband_sources.append(line)
        state._rubberband_actors.append(actor)

    def close_all():
        interactor.SetDone(True)
        try:
            if state.tk_root and state.tk_root.winfo_exists():
                state.tk_root.destroy()
        except Exception:
            pass

    interactor.Initialize()
    render_window.Render()
    render_window.SetWindowName(win_title)  # ensure title is set after window creation

    tk_root = build_ui(state, render_window, close_all)

    def _activate_hide_select():
        if state.selection_mode == "camera":
            state.selection_mode = "hide_select"
            # Do NOT remove interactor style; keep rotation/zoom/pan alive
            if hasattr(state, '_tb_hide_btn') and state._tb_hide_btn:
                state._tb_hide_btn._is_active = True
                state._tb_hide_btn.configure(bg="#4a5568", fg="#fbbf24")

    def _activate_show_select():
        if state.selection_mode == "camera":
            state.selection_mode = "show_select"
            state._show_select_mask = [False] * len(state.objects)
            # Do NOT remove interactor style; keep rotation/zoom/pan alive
            if hasattr(state, '_tb_show_btn') and state._tb_show_btn:
                state._tb_show_btn._is_active = True
                state._tb_show_btn.configure(bg="#4a5568", fg="#fbbf24")

    def on_keypress(obj, event):
        key = obj.GetKeySym()
        if key == "c":
            if state.selected_idx >= 0:
                state.cycle_color_for(state.selected_idx)
        elif key.isdigit():
            idx = int(key) - 1
            if 0 <= idx < len(state.objects):
                state.select_object(idx)
        elif key in ("f", "F"):
            state.renderer.ResetCamera()
            state.renderer.ResetCameraClippingRange()
            state._request_render()
        elif key in ("h", "H"):
            _activate_hide_select()
        elif key in ("s", "S"):
            _activate_show_select()
        elif key in ("i", "I"):
            _toolbar_toggle_identify()
        elif key == "Escape":
            if state.selection_mode in ("hide_select", "show_select", "identify"):
                state._exit_select_mode()
        elif key == "q":
            obj.GetRenderWindow().Finalize()
            sys.exit(0)

    def _exit_select_mode():
        mode = state.selection_mode
        state.selection_mode = "camera"
        state._is_dragging = False
        if state._hover_idx >= 0:
            state._set_hover(state._hover_idx, False)
            state._hover_idx = -1
        for actor in state._rubberband_actors:
            actor.SetVisibility(0)
        if state._identify_actor:
            state._identify_actor.SetVisibility(0)
        state._identify_idx = -1
        if mode == "show_select":
            # Selected parts (marked hidden during selection) become visible;
            # everything else is hidden.
            for i, obj in enumerate(state.objects):
                if i < len(state._show_select_mask) and state._show_select_mask[i]:
                    state.set_visibility(i, True)
                else:
                    state.set_visibility(i, False)
            state._show_select_mask = []
        if hasattr(state, '_tb_hide_btn') and state._tb_hide_btn:
            state._tb_hide_btn.configure(bg="#252a33", fg="#e2e8f0")
        if hasattr(state, '_tb_show_btn') and state._tb_show_btn:
            state._tb_show_btn.configure(bg="#252a33", fg="#e2e8f0")
        if hasattr(state, '_tb_identify_btn') and state._tb_identify_btn:
            state._tb_identify_btn.configure(bg="#252a33", fg="#e2e8f0")
        state._refresh_panel()
        state._request_render()

    def _update_hover(pos):
        picker = vtk.vtkPropPicker()
        picker.Pick(int(pos[0]), int(pos[1]), 0, renderer)
        picked = picker.GetActor()
        new_hover = -1
        if picked:
            for i, obj_data in enumerate(state.objects):
                if obj_data.get("actor") == picked or obj_data.get("inner_actor") == picked:
                    new_hover = i
                    break
        if new_hover != state._hover_idx:
            if state._hover_idx >= 0:
                state._set_hover(state._hover_idx, False)
            state._hover_idx = new_hover
            if state._hover_idx >= 0:
                state._set_hover(state._hover_idx, True)

    def _mark_show_selected(idx):
        if 0 <= idx < len(state.objects) and not state._show_select_mask[idx]:
            state._show_select_mask[idx] = True
            state.set_visibility(idx, False)

    def _mark_show_selected_box(x1, y1, x2, y2):
        for i, obj_data in enumerate(state.objects):
            actor = obj_data.get("actor")
            if not actor:
                continue
            b = actor.GetBounds()
            coord = vtk.vtkCoordinate()
            coord.SetCoordinateSystemToWorld()
            screen_pts = []
            for ix in [b[0], b[1]]:
                for iy in [b[2], b[3]]:
                    for iz in [b[4], b[5]]:
                        coord.SetValue(ix, iy, iz)
                        disp = coord.GetComputedDisplayValue(renderer)
                        screen_pts.append(disp)
            xs = [p[0] for p in screen_pts]
            ys = [p[1] for p in screen_pts]
            sx_min, sx_max = min(xs), max(xs)
            sy_min, sy_max = min(ys), max(ys)
            if sx_max >= x1 and sx_min <= x2 and sy_max >= y1 and sy_min <= y2:
                if not state._show_select_mask[i]:
                    state._show_select_mask[i] = True
                    state.set_visibility(i, False)

    def on_left_button_press(obj, event):
        if state.selection_mode in ("hide_select", "show_select", "identify"):
            pos = obj.GetEventPosition()
            state._drag_start = (int(pos[0]), int(pos[1]))
            state._drag_current = state._drag_start
            state._select_button_down = True
            state._select_has_dragged = False
            state._select_rotation_started = False
            if state.selection_mode in ("hide_select", "show_select"):
                if obj.GetAltKey():
                    if state._hover_idx >= 0:
                        state._set_hover(state._hover_idx, False)
                        state._hover_idx = -1
                    state._is_dragging = True
                else:
                    state._is_dragging = False
                    _update_hover(pos)
            obj.AbortFlagOn()  # block style from starting rotate
            return
        # Normal camera mode: click-to-select
        click_pos = obj.GetEventPosition()
        picker = vtk.vtkPropPicker()
        picker.Pick(click_pos[0], click_pos[1], 0, renderer)
        picked = picker.GetActor()
        if picked:
            for i, obj_data in enumerate(state.objects):
                if obj_data.get("actor") == picked or obj_data.get("inner_actor") == picked:
                    state.select_object(i)
                    break

    def on_mouse_move(obj, event):
        if state.selection_mode not in ("hide_select", "show_select", "identify"):
            return
        pos = obj.GetEventPosition()
        state._drag_current = (int(pos[0]), int(pos[1]))
        if not state._select_button_down:
            return
        dx = abs(state._drag_current[0] - state._drag_start[0])
        dy = abs(state._drag_current[1] - state._drag_start[1])
        if dx > 3 or dy > 3:
            state._select_has_dragged = True
        # Alt+drag => box select (only for hide_select/show_select)
        if state._is_dragging:
            x1, y1 = state._drag_start
            x2, y2 = state._drag_current
            w1 = display_to_world(x1, y1, renderer)
            w2 = display_to_world(x2, y1, renderer)
            w3 = display_to_world(x2, y2, renderer)
            w4 = display_to_world(x1, y2, renderer)
            state._rubberband_sources[0].SetPoint1(w1[0], w1[1], w1[2])
            state._rubberband_sources[0].SetPoint2(w2[0], w2[1], w2[2])
            state._rubberband_sources[1].SetPoint1(w2[0], w2[1], w2[2])
            state._rubberband_sources[1].SetPoint2(w3[0], w3[1], w3[2])
            state._rubberband_sources[2].SetPoint1(w3[0], w3[1], w3[2])
            state._rubberband_sources[2].SetPoint2(w4[0], w4[1], w4[2])
            state._rubberband_sources[3].SetPoint1(w4[0], w4[1], w4[2])
            state._rubberband_sources[3].SetPoint2(w1[0], w1[1], w1[2])
            for actor in state._rubberband_actors:
                actor.SetVisibility(1)
            state._request_render()
            obj.AbortFlagOn()
            return
        # Non-Alt drag => rotate camera (hand style manually)
        if state._select_has_dragged:
            if not state._select_rotation_started:
                state._select_rotation_started = True
                state._style.OnLeftButtonDown()
            return
        # Not dragging yet => hover preview (only for hide/show select)
        if state.selection_mode in ("hide_select", "show_select"):
            _update_hover(pos)

    def on_left_button_release(obj, event):
        if state.selection_mode not in ("hide_select", "show_select", "identify"):
            return
        state._select_button_down = False
        if state._select_has_dragged:
            if state._is_dragging:
                # Alt+drag box select (hide/show only)
                state._is_dragging = False
                for actor in state._rubberband_actors:
                    actor.SetVisibility(0)
                x1, x2 = sorted([state._drag_start[0], state._drag_current[0]])
                y1, y2 = sorted([state._drag_start[1], state._drag_current[1]])
                if state.selection_mode == "hide_select":
                    for i, obj_data in enumerate(state.objects):
                        actor = obj_data.get("actor")
                        if not actor or not obj_data.get("visible", True):
                            continue
                        b = actor.GetBounds()
                        coord = vtk.vtkCoordinate()
                        coord.SetCoordinateSystemToWorld()
                        screen_pts = []
                        for ix in [b[0], b[1]]:
                            for iy in [b[2], b[3]]:
                                for iz in [b[4], b[5]]:
                                    coord.SetValue(ix, iy, iz)
                                    disp = coord.GetComputedDisplayValue(renderer)
                                    screen_pts.append(disp)
                        xs = [p[0] for p in screen_pts]
                        ys = [p[1] for p in screen_pts]
                        sx_min, sx_max = min(xs), max(xs)
                        sy_min, sy_max = min(ys), max(ys)
                        if sx_max >= x1 and sx_min <= x2 and sy_max >= y1 and sy_min <= y2:
                            state.set_visibility(i, False)
                else:  # show_select
                    _mark_show_selected_box(x1, y1, x2, y2)
                state._refresh_panel()
                state._request_render()
                obj.AbortFlagOn()
                return
            # Non-Alt drag => let style finish rotate normally
            state._select_has_dragged = False
            state._select_rotation_started = False
            return
        # Simple click (no drag)
        if state.selection_mode in ("hide_select", "show_select"):
            if state._hover_idx >= 0:
                state._set_hover(state._hover_idx, False)
                state._hover_idx = -1
            release_pos = obj.GetEventPosition()
            picker = vtk.vtkPropPicker()
            picker.Pick(int(release_pos[0]), int(release_pos[1]), 0, renderer)
            picked = picker.GetActor()
            if picked:
                for i, obj_data in enumerate(state.objects):
                    if obj_data.get("actor") == picked or obj_data.get("inner_actor") == picked:
                        if state.selection_mode == "hide_select":
                            state.set_visibility(i, False)
                        else:  # show_select
                            _mark_show_selected(i)
                        break
            state._refresh_panel()
            state._request_render()
            obj.AbortFlagOn()
            return
        # Identify mode: click object to show its ID label
        if state.selection_mode == "identify":
            release_pos = obj.GetEventPosition()
            picker = vtk.vtkPropPicker()
            picker.Pick(int(release_pos[0]), int(release_pos[1]), 0, renderer)
            picked = picker.GetActor()
            found_idx = -1
            if picked:
                for i, obj_data in enumerate(state.objects):
                    if obj_data.get("actor") == picked or obj_data.get("inner_actor") == picked:
                        found_idx = i
                        break
            if found_idx >= 0 and state._identify_actor:
                obj_data = state.objects[found_idx]
                oid = obj_data.get("id")
                label_text = f"ID:{oid}" if oid else f"#{found_idx + 1}"
                # Position label at object center
                actor = obj_data.get("actor")
                if actor:
                    b = actor.GetBounds()
                    cx = (b[0] + b[1]) / 2.0
                    cy = (b[2] + b[3]) / 2.0
                    cz = (b[4] + b[5]) / 2.0
                    state._identify_actor.SetPosition(cx, cy, cz)
                state._identify_actor.SetInput(label_text)
                state._identify_actor.SetVisibility(1)
                state._identify_idx = found_idx
            else:
                if state._identify_actor:
                    state._identify_actor.SetVisibility(0)
                state._identify_idx = -1
            state._request_render()
            obj.AbortFlagOn()

    def on_middle_button_press(obj, event):
        if state.selection_mode in ("hide_select", "show_select", "identify"):
            _exit_select_mode()

    def on_right_button_press(obj, event):
        if state.selection_mode in ("hide_select", "show_select", "identify"):
            _exit_select_mode()

    interactor.AddObserver("KeyPressEvent", on_keypress)
    interactor.AddObserver("LeftButtonPressEvent", on_left_button_press)
    interactor.AddObserver("MouseMoveEvent", on_mouse_move)
    interactor.AddObserver("LeftButtonReleaseEvent", on_left_button_release)
    interactor.AddObserver("MiddleButtonPressEvent", on_middle_button_press)
    interactor.AddObserver("RightButtonPressEvent", on_right_button_press)

    renderer.ResetCamera()
    camera = renderer.GetActiveCamera()
    camera.ParallelProjectionOn()
    camera.Azimuth(30)
    camera.Elevation(20)
    camera.Roll(-12)
    camera.OrthogonalizeViewUp()
    camera.Zoom(1.15)
    camera.SetParallelScale(diag * 0.65)
    renderer.ResetCameraClippingRange()

    # Stable event loop: VTK Start() owns the main thread, timer keeps tkinter alive
    def on_timer(obj, event):
        if state.needs_render:
            state.needs_render = False
            obj.GetRenderWindow().Render()
        if tk_root and tk_root.winfo_exists():
            try:
                tk_root.update_idletasks()
                tk_root.update()
            except tk.TclError:
                interactor.SetDone(True)

    interactor.AddObserver("TimerEvent", on_timer)
    interactor.CreateRepeatingTimer(30)
    interactor.Start()
'''

new_show_window = '''def show_window():
    renderer = vtk.vtkRenderer()
    renderer.SetBackground(0.05, 0.06, 0.09)
    renderer.SetBackground2(0.08, 0.1, 0.14)
    renderer.GradientBackgroundOn()

    win_title = "Impetus Geometry Preview"
    render_window = vtk.vtkRenderWindow()
    render_window.AddRenderer(renderer)
    render_window.SetWindowName(win_title)

    interactor = vtk.vtkRenderWindowInteractor()
    interactor.SetRenderWindow(render_window)
    style = vtk.vtkInteractorStyleTrackballCamera()
    interactor.SetInteractorStyle(style)

    axes = build_axes_actor()
    om = vtk.vtkOrientationMarkerWidget()
    om.SetOrientationMarker(axes)
    om.SetInteractor(interactor)
    om.SetViewport(0.0, 0.0, 0.18, 0.18)
    om.SetEnabled(True)
    om.InteractiveOff()

    state = ViewerState([], renderer, interactor, om=om)
    state._style = style  # save for mode switching

    # Identify-mode floating label (hidden by default)
    id_actor = vtk.vtkBillboardTextActor3D()
    id_actor.GetTextProperty().SetFontSize(18)
    id_actor.GetTextProperty().SetColor(0.0, 0.0, 0.0)
    id_actor.GetTextProperty().SetBackgroundColor(1.0, 0.92, 0.23)
    id_actor.GetTextProperty().SetBackgroundOpacity(1.0)
    id_actor.GetTextProperty().BoldOn()
    id_actor.GetTextProperty().FrameOn()
    id_actor.GetTextProperty().SetFrameColor(0.0, 0.0, 0.0)
    id_actor.GetTextProperty().SetFrameWidth(2)
    id_actor.PickableOff()
    id_actor.SetVisibility(0)
    renderer.AddActor(id_actor)
    state._identify_actor = id_actor

    # Rubberband lines for box-pick-hide mode
    def display_to_world(display_x, display_y, renderer):
        coord = vtk.vtkCoordinate()
        coord.SetCoordinateSystemToDisplay()
        coord.SetValue(float(display_x), float(display_y), 0.0)
        return coord.GetComputedWorldValue(renderer)

    for _ in range(4):
        line = vtk.vtkLineSource()
        mapper = vtk.vtkPolyDataMapper()
        mapper.SetInputConnection(line.GetOutputPort())
        actor = vtk.vtkActor()
        actor.SetMapper(mapper)
        actor.GetProperty().SetColor(1.0, 0.85, 0.0)
        actor.GetProperty().SetLineWidth(2.5)
        actor.PickableOff()
        actor.SetVisibility(0)
        renderer.AddActor(actor)
        state._rubberband_sources.append(line)
        state._rubberband_actors.append(actor)

    def close_all():
        interactor.SetDone(True)
        try:
            if state.tk_root and state.tk_root.winfo_exists():
                state.tk_root.destroy()
        except Exception:
            pass

    interactor.Initialize()
    render_window.Render()
    render_window.SetWindowName(win_title)  # ensure title is set after window creation

    tk_root = build_ui(state, render_window, close_all)

    def _activate_hide_select():
        if state.selection_mode == "camera":
            state.selection_mode = "hide_select"
            # Do NOT remove interactor style; keep rotation/zoom/pan alive
            if hasattr(state, '_tb_hide_btn') and state._tb_hide_btn:
                state._tb_hide_btn._is_active = True
                state._tb_hide_btn.configure(bg="#4a5568", fg="#fbbf24")

    def _activate_show_select():
        if state.selection_mode == "camera":
            state.selection_mode = "show_select"
            state._show_select_mask = [False] * len(state.objects)
            # Do NOT remove interactor style; keep rotation/zoom/pan alive
            if hasattr(state, '_tb_show_btn') and state._tb_show_btn:
                state._tb_show_btn._is_active = True
                state._tb_show_btn.configure(bg="#4a5568", fg="#fbbf24")

    def on_keypress(obj, event):
        key = obj.GetKeySym()
        if key == "c":
            if state.selected_idx >= 0:
                state.cycle_color_for(state.selected_idx)
        elif key.isdigit():
            idx = int(key) - 1
            if 0 <= idx < len(state.objects):
                state.select_object(idx)
        elif key in ("f", "F"):
            state.renderer.ResetCamera()
            state.renderer.ResetCameraClippingRange()
            state._request_render()
        elif key in ("h", "H"):
            _activate_hide_select()
        elif key in ("s", "S"):
            _activate_show_select()
        elif key in ("i", "I"):
            _toolbar_toggle_identify()
        elif key == "Escape":
            if state.selection_mode in ("hide_select", "show_select", "identify"):
                state._exit_select_mode()
        elif key == "q":
            obj.GetRenderWindow().Finalize()
            sys.exit(0)

    def _exit_select_mode():
        mode = state.selection_mode
        state.selection_mode = "camera"
        state._is_dragging = False
        if state._hover_idx >= 0:
            state._set_hover(state._hover_idx, False)
            state._hover_idx = -1
        for actor in state._rubberband_actors:
            actor.SetVisibility(0)
        if state._identify_actor:
            state._identify_actor.SetVisibility(0)
        state._identify_idx = -1
        if mode == "show_select":
            # Selected parts (marked hidden during selection) become visible;
            # everything else is hidden.
            for i, obj in enumerate(state.objects):
                if i < len(state._show_select_mask) and state._show_select_mask[i]:
                    state.set_visibility(i, True)
                else:
                    state.set_visibility(i, False)
            state._show_select_mask = []
        if hasattr(state, '_tb_hide_btn') and state._tb_hide_btn:
            state._tb_hide_btn.configure(bg="#252a33", fg="#e2e8f0")
        if hasattr(state, '_tb_show_btn') and state._tb_show_btn:
            state._tb_show_btn.configure(bg="#252a33", fg="#e2e8f0")
        if hasattr(state, '_tb_identify_btn') and state._tb_identify_btn:
            state._tb_identify_btn.configure(bg="#252a33", fg="#e2e8f0")
        state._refresh_panel()
        state._request_render()

    def _update_hover(pos):
        picker = vtk.vtkPropPicker()
        picker.Pick(int(pos[0]), int(pos[1]), 0, renderer)
        picked = picker.GetActor()
        new_hover = -1
        if picked:
            for i, obj_data in enumerate(state.objects):
                if obj_data.get("actor") == picked or obj_data.get("inner_actor") == picked:
                    new_hover = i
                    break
        if new_hover != state._hover_idx:
            if state._hover_idx >= 0:
                state._set_hover(state._hover_idx, False)
            state._hover_idx = new_hover
            if state._hover_idx >= 0:
                state._set_hover(state._hover_idx, True)

    def _mark_show_selected(idx):
        if 0 <= idx < len(state.objects) and not state._show_select_mask[idx]:
            state._show_select_mask[idx] = True
            state.set_visibility(idx, False)

    def _mark_show_selected_box(x1, y1, x2, y2):
        for i, obj_data in enumerate(state.objects):
            actor = obj_data.get("actor")
            if not actor:
                continue
            b = actor.GetBounds()
            coord = vtk.vtkCoordinate()
            coord.SetCoordinateSystemToWorld()
            screen_pts = []
            for ix in [b[0], b[1]]:
                for iy in [b[2], b[3]]:
                    for iz in [b[4], b[5]]:
                        coord.SetValue(ix, iy, iz)
                        disp = coord.GetComputedDisplayValue(renderer)
                        screen_pts.append(disp)
            xs = [p[0] for p in screen_pts]
            ys = [p[1] for p in screen_pts]
            sx_min, sx_max = min(xs), max(xs)
            sy_min, sy_max = min(ys), max(ys)
            if sx_max >= x1 and sx_min <= x2 and sy_max >= y1 and sy_min <= y2:
                if not state._show_select_mask[i]:
                    state._show_select_mask[i] = True
                    state.set_visibility(i, False)

    def on_left_button_press(obj, event):
        if state.selection_mode in ("hide_select", "show_select", "identify"):
            pos = obj.GetEventPosition()
            state._drag_start = (int(pos[0]), int(pos[1]))
            state._drag_current = state._drag_start
            state._select_button_down = True
            state._select_has_dragged = False
            state._select_rotation_started = False
            if state.selection_mode in ("hide_select", "show_select"):
                if obj.GetAltKey():
                    if state._hover_idx >= 0:
                        state._set_hover(state._hover_idx, False)
                        state._hover_idx = -1
                    state._is_dragging = True
                else:
                    state._is_dragging = False
                    _update_hover(pos)
            obj.AbortFlagOn()  # block style from starting rotate
            return
        # Normal camera mode: click-to-select
        click_pos = obj.GetEventPosition()
        picker = vtk.vtkPropPicker()
        picker.Pick(click_pos[0], click_pos[1], 0, renderer)
        picked = picker.GetActor()
        if picked:
            for i, obj_data in enumerate(state.objects):
                if obj_data.get("actor") == picked or obj_data.get("inner_actor") == picked:
                    state.select_object(i)
                    break

    def on_mouse_move(obj, event):
        if state.selection_mode not in ("hide_select", "show_select", "identify"):
            return
        pos = obj.GetEventPosition()
        state._drag_current = (int(pos[0]), int(pos[1]))
        if not state._select_button_down:
            return
        dx = abs(state._drag_current[0] - state._drag_start[0])
        dy = abs(state._drag_current[1] - state._drag_start[1])
        if dx > 3 or dy > 3:
            state._select_has_dragged = True
        # Alt+drag => box select (only for hide_select/show_select)
        if state._is_dragging:
            x1, y1 = state._drag_start
            x2, y2 = state._drag_current
            w1 = display_to_world(x1, y1, renderer)
            w2 = display_to_world(x2, y1, renderer)
            w3 = display_to_world(x2, y2, renderer)
            w4 = display_to_world(x1, y2, renderer)
            state._rubberband_sources[0].SetPoint1(w1[0], w1[1], w1[2])
            state._rubberband_sources[0].SetPoint2(w2[0], w2[1], w2[2])
            state._rubberband_sources[1].SetPoint1(w2[0], w2[1], w2[2])
            state._rubberband_sources[1].SetPoint2(w3[0], w3[1], w3[2])
            state._rubberband_sources[2].SetPoint1(w3[0], w3[1], w3[2])
            state._rubberband_sources[2].SetPoint2(w4[0], w4[1], w4[2])
            state._rubberband_sources[3].SetPoint1(w4[0], w4[1], w4[2])
            state._rubberband_sources[3].SetPoint2(w1[0], w1[1], w1[2])
            for actor in state._rubberband_actors:
                actor.SetVisibility(1)
            state._request_render()
            obj.AbortFlagOn()
            return
        # Non-Alt drag => rotate camera (hand style manually)
        if state._select_has_dragged:
            if not state._select_rotation_started:
                state._select_rotation_started = True
                state._style.OnLeftButtonDown()
            return
        # Not dragging yet => hover preview (only for hide/show select)
        if state.selection_mode in ("hide_select", "show_select"):
            _update_hover(pos)

    def on_left_button_release(obj, event):
        if state.selection_mode not in ("hide_select", "show_select", "identify"):
            return
        state._select_button_down = False
        if state._select_has_dragged:
            if state._is_dragging:
                # Alt+drag box select (hide/show only)
                state._is_dragging = False
                for actor in state._rubberband_actors:
                    actor.SetVisibility(0)
                x1, x2 = sorted([state._drag_start[0], state._drag_current[0]])
                y1, y2 = sorted([state._drag_start[1], state._drag_current[1]])
                if state.selection_mode == "hide_select":
                    for i, obj_data in enumerate(state.objects):
                        actor = obj_data.get("actor")
                        if not actor or not obj_data.get("visible", True):
                            continue
                        b = actor.GetBounds()
                        coord = vtk.vtkCoordinate()
                        coord.SetCoordinateSystemToWorld()
                        screen_pts = []
                        for ix in [b[0], b[1]]:
                            for iy in [b[2], b[3]]:
                                for iz in [b[4], b[5]]:
                                    coord.SetValue(ix, iy, iz)
                                    disp = coord.GetComputedDisplayValue(renderer)
                                    screen_pts.append(disp)
                        xs = [p[0] for p in screen_pts]
                        ys = [p[1] for p in screen_pts]
                        sx_min, sx_max = min(xs), max(xs)
                        sy_min, sy_max = min(ys), max(ys)
                        if sx_max >= x1 and sx_min <= x2 and sy_max >= y1 and sy_min <= y2:
                            state.set_visibility(i, False)
                else:  # show_select
                    _mark_show_selected_box(x1, y1, x2, y2)
                state._refresh_panel()
                state._request_render()
                obj.AbortFlagOn()
                return
            # Non-Alt drag => let style finish rotate normally
            state._select_has_dragged = False
            state._select_rotation_started = False
            return
        # Simple click (no drag)
        if state.selection_mode in ("hide_select", "show_select"):
            if state._hover_idx >= 0:
                state._set_hover(state._hover_idx, False)
                state._hover_idx = -1
            release_pos = obj.GetEventPosition()
            picker = vtk.vtkPropPicker()
            picker.Pick(int(release_pos[0]), int(release_pos[1]), 0, renderer)
            picked = picker.GetActor()
            if picked:
                for i, obj_data in enumerate(state.objects):
                    if obj_data.get("actor") == picked or obj_data.get("inner_actor") == picked:
                        if state.selection_mode == "hide_select":
                            state.set_visibility(i, False)
                        else:  # show_select
                            _mark_show_selected(i)
                        break
            state._refresh_panel()
            state._request_render()
            obj.AbortFlagOn()
            return
        # Identify mode: click object to show its ID label
        if state.selection_mode == "identify":
            release_pos = obj.GetEventPosition()
            picker = vtk.vtkPropPicker()
            picker.Pick(int(release_pos[0]), int(release_pos[1]), 0, renderer)
            picked = picker.GetActor()
            found_idx = -1
            if picked:
                for i, obj_data in enumerate(state.objects):
                    if obj_data.get("actor") == picked or obj_data.get("inner_actor") == picked:
                        found_idx = i
                        break
            if found_idx >= 0 and state._identify_actor:
                obj_data = state.objects[found_idx]
                oid = obj_data.get("id")
                label_text = f"ID:{oid}" if oid else f"#{found_idx + 1}"
                # Position label at object center
                actor = obj_data.get("actor")
                if actor:
                    b = actor.GetBounds()
                    cx = (b[0] + b[1]) / 2.0
                    cy = (b[2] + b[3]) / 2.0
                    cz = (b[4] + b[5]) / 2.0
                    state._identify_actor.SetPosition(cx, cy, cz)
                state._identify_actor.SetInput(label_text)
                state._identify_actor.SetVisibility(1)
                state._identify_idx = found_idx
            else:
                if state._identify_actor:
                    state._identify_actor.SetVisibility(0)
                state._identify_idx = -1
            state._request_render()
            obj.AbortFlagOn()

    def on_middle_button_press(obj, event):
        if state.selection_mode in ("hide_select", "show_select", "identify"):
            _exit_select_mode()

    def on_right_button_press(obj, event):
        if state.selection_mode in ("hide_select", "show_select", "identify"):
            _exit_select_mode()

    interactor.AddObserver("KeyPressEvent", on_keypress)
    interactor.AddObserver("LeftButtonPressEvent", on_left_button_press)
    interactor.AddObserver("MouseMoveEvent", on_mouse_move)
    interactor.AddObserver("LeftButtonReleaseEvent", on_left_button_release)
    interactor.AddObserver("MiddleButtonPressEvent", on_middle_button_press)
    interactor.AddObserver("RightButtonPressEvent", on_right_button_press)

    renderer.ResetCamera()
    camera = renderer.GetActiveCamera()
    camera.ParallelProjectionOn()
    camera.Azimuth(30)
    camera.Elevation(20)
    camera.Roll(-12)
    camera.OrthogonalizeViewUp()
    camera.Zoom(1.15)
    camera.SetParallelScale(0.65)
    renderer.ResetCameraClippingRange()

    # Stable event loop: VTK Start() owns the main thread, timer keeps tkinter alive
    def on_timer(obj, event):
        if state.needs_render:
            state.needs_render = False
            obj.GetRenderWindow().Render()
        if tk_root and tk_root.winfo_exists():
            try:
                tk_root.update_idletasks()
                tk_root.update()
            except tk.TclError:
                interactor.SetDone(True)
        # Poll stdin for commands
        try:
            ready, _, _ = select.select([sys.stdin], [], [], 0)
            if ready:
                line = sys.stdin.readline()
                if line:
                    try:
                        msg = json.loads(line)
                        cmd = msg.get("cmd")
                        if cmd == "load":
                            payload = msg.get("payload", {})
                            build_scene(state, payload)
                        elif cmd == "exit":
                            interactor.SetDone(True)
                    except json.JSONDecodeError:
                        pass
        except (OSError, ValueError):
            pass

    interactor.AddObserver("TimerEvent", on_timer)
    interactor.CreateRepeatingTimer(30)
    interactor.Start()
'''

if old_show_window in content:
    content = content.replace(old_show_window, new_show_window)
else:
    print("WARNING: Could not find old_show_window to replace!")

# 7. Replace main
old_main = '''def main(argv):
    if len(argv) < 2:
        raise SystemExit("usage: impetus_geometry_viewer.py <payload.json>")
    payload = load_payload(Path(argv[1]))
    show_window(payload)


if __name__ == "__main__":
    main(sys.argv)'''
new_main = '''def main():
    show_window()


if __name__ == "__main__":
    main()'''
content = content.replace(old_main, new_main)

with open('scripts/impetus_geometry_viewer.py', 'w', encoding='utf-8') as f:
    f.write(content)

print("Done")
