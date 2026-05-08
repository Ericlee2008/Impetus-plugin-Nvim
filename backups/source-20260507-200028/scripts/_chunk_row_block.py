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

    # Bottom controls: Show All / Turn Off All