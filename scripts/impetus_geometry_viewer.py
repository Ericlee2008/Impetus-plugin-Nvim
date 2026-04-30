#!/usr/bin/env python3
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

try:
    import vtk
except Exception as exc:  # pragma: no cover
    raise SystemExit(f"VTK import failed: {exc}")


def load_payload(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def trim(s: str) -> str:
    return s.strip()


def strip_number_prefix(line: str) -> str:
    import re

    return re.sub(r"^\s*\d+\.\s*", "", line or "")


def parse_keyword(line: str) -> str | None:
    import re

    normalized = trim(strip_number_prefix(line))
    m = re.match(r"^(\*[\w_-]+)", normalized)
    return m.group(1) if m else None


def is_meta_line(line: str) -> bool:
    normalized = trim(strip_number_prefix(line or ""))
    return (
        normalized == ""
        or normalized.startswith("#")
        or normalized.startswith("$")
        or normalized.startswith("~")
        or normalized.startswith("-")
        or normalized == "Variable         Description"
        or normalized == '"Optional title"'
        or (normalized.startswith('"') and normalized.endswith('"'))
    )


def extract_numbers(line: str) -> list[float]:
    import re

    out: list[float] = []
    for token in re.split(r"[,\s]+", line or ""):
        if not token:
            continue
        if re.match(r"^[-+]?\d*\.?\d+[eE][-+]?\d+$", token) or re.match(r"^[-+]?\d*\.?\d+$", token):
            try:
                out.append(float(token))
            except ValueError:
                pass
    return out


def flatten_points(lines: list[str]) -> tuple[list[list[float]], list[float], list[float]]:
    points: list[list[float]] = []
    scalars: list[float] = []
    raw_numbers: list[float] = []
    for line in lines:
        if is_meta_line(line):
            continue
        nums = extract_numbers(line)
        raw_numbers.extend(nums)
        if len(nums) == 1:
            scalars.append(nums[0])
        i = 0
        while i + 2 < len(nums):
            points.append([nums[i], nums[i + 1], nums[i + 2]])
            i += 3
    return points, scalars, raw_numbers


def bbox(points: list[list[float]]) -> tuple[list[float], list[float]]:
    if not points:
        return [-1.0, -1.0, -1.0], [1.0, 1.0, 1.0]
    mins = [min(p[i] for p in points) for i in range(3)]
    maxs = [max(p[i] for p in points) for i in range(3)]
    for i in range(3):
        if abs(maxs[i] - mins[i]) < 1e-9:
            mins[i] -= 0.5
            maxs[i] += 0.5
    return mins, maxs


def shape_from_keyword(keyword: str, lines: list[str]) -> str | None:
    k = (keyword or "").lower()
    if "sphere" in k:
        return "sphere"
    if "cyl" in k:
        return "cylinder"
    if "box" in k:
        return "box"
    first = trim(strip_number_prefix(lines[0] if lines else "")).lower()
    if first in {"box", "sphere", "cylinder"}:
        return first
    return None


def vec_add(a, b):
    return [a[0] + b[0], a[1] + b[1], a[2] + b[2]]


def vec_sub(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def vec_scale(a, s):
    return [a[0] * s, a[1] * s, a[2] * s]


def vec_len(a):
    return math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])


def vec_norm(a):
    l = vec_len(a)
    if l <= 1e-9:
        return [0.0, 0.0, 1.0]
    return [a[0] / l, a[1] / l, a[2] / l]


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]


def point_to_axis_radius(p, a, axis):
    ap = vec_sub(p, a)
    proj = dot(ap, axis)
    perp = vec_sub(ap, vec_scale(axis, proj))
    return vec_len(perp)


def build_box(points, scalars):
    if len(scalars) >= 6:
        mins = scalars[:3]
        maxs = scalars[3:6]
    elif len(points) >= 2:
        mins, maxs = bbox(points[:2])
    else:
        mins, maxs = bbox(points)
    x0, y0, z0 = mins
    x1, y1, z1 = maxs
    verts = [
        [x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0],
        [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1],
    ]
    edges = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7),
    ]
    return verts, edges


def build_sphere(points, scalars):
    center = points[0] if points else [0.0, 0.0, 0.0]
    if len(scalars) >= 1:
        radius = abs(float(scalars[0]))
    elif len(points) >= 2:
        radius = vec_len(vec_sub(points[1], center))
    else:
        radius = 1.0
    radius = max(radius, 1e-3)
    verts = [center]
    edges = []
    seg = 24
    rings = 10
    for r in range(1, rings):
        phi = math.pi * r / rings
        base = len(verts)
        for i in range(seg):
            theta = 2 * math.pi * i / seg
            x = center[0] + radius * math.sin(phi) * math.cos(theta)
            y = center[1] + radius * math.sin(phi) * math.sin(theta)
            z = center[2] + radius * math.cos(phi)
            verts.append([x, y, z])
        for i in range(seg):
            edges.append((base + i, base + (i + 1) % seg))
    for i in range(seg):
        theta = 2 * math.pi * i / seg
        base = len(verts)
        for r in range(rings + 1):
            phi = math.pi * r / rings
            x = center[0] + radius * math.sin(phi) * math.cos(theta)
            y = center[1] + radius * math.sin(phi) * math.sin(theta)
            z = center[2] + radius * math.cos(phi)
            verts.append([x, y, z])
        for r in range(rings):
            edges.append((base + r, base + r + 1))
    return verts, edges


def build_cylinder(points, scalars):
    a = points[0] if len(points) >= 1 else [0.0, 0.0, -0.5]
    b = points[1] if len(points) >= 2 else [0.0, 0.0, 0.5]
    axis = vec_norm(vec_sub(b, a))
    ref = [0.0, 0.0, 1.0] if abs(axis[2]) < 0.9 else [1.0, 0.0, 0.0]
    u = vec_norm(cross(axis, ref))
    v = cross(axis, u)
    if len(scalars) >= 1:
        radius = abs(float(scalars[0]))
    elif len(points) >= 3:
        radius = point_to_axis_radius(points[2], a, axis)
    else:
        radius = 0.5
    radius = max(radius, 1e-3)
    seg = 24
    ring_a = []
    ring_b = []
    for i in range(seg):
        t = 2 * math.pi * i / seg
        offset = vec_add(vec_scale(u, math.cos(t) * radius), vec_scale(v, math.sin(t) * radius))
        ring_a.append(vec_add(a, offset))
        ring_b.append(vec_add(b, offset))
    verts = ring_a + ring_b
    edges = []
    for i in range(seg):
        edges.append((i, (i + 1) % seg))
        edges.append((seg + i, seg + (i + 1) % seg))
        edges.append((i, seg + i))
    return verts, edges


def build_model(payload):
    shape = (payload.get("shape") or "").lower()
    points = payload.get("points") or []
    scalars = payload.get("scalars") or payload.get("numbers") or []
    if shape == "sphere":
        return build_sphere(points, scalars)
    if shape == "cylinder":
        return build_cylinder(points, scalars)
    return build_box(points, scalars)


def vtk_points(verts):
    pts = vtk.vtkPoints()
    for v in verts:
        pts.InsertNextPoint(float(v[0]), float(v[1]), float(v[2]))
    return pts


def build_wireframe_actor(verts, edges):
    pts = vtk_points(verts)
    lines = vtk.vtkCellArray()
    for a, b in edges:
        line = vtk.vtkLine()
        line.GetPointIds().SetId(0, int(a))
        line.GetPointIds().SetId(1, int(b))
        lines.InsertNextCell(line)
    poly = vtk.vtkPolyData()
    poly.SetPoints(pts)
    poly.SetLines(lines)
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputData(poly)
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    actor.GetProperty().SetColor(0.42, 0.78, 1.0)
    actor.GetProperty().SetLineWidth(2.5)
    return actor


def build_box_surface_actor(mins, maxs):
    cube = vtk.vtkCubeSource()
    cube.SetBounds(mins[0], maxs[0], mins[1], maxs[1], mins[2], maxs[2])
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputConnection(cube.GetOutputPort())
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    actor.GetProperty().SetColor(0.28, 0.56, 0.82)
    actor.GetProperty().SetOpacity(1.0)
    actor.GetProperty().SetEdgeVisibility(0)
    actor.GetProperty().SetInterpolationToPhong()
    actor.GetProperty().BackfaceCullingOn()
    return actor


def build_box_grid_actor(mins, maxs, splits):
    nx = max(1, int(splits[0] if len(splits) > 0 else 1))
    ny = max(1, int(splits[1] if len(splits) > 1 else 1))
    nz = max(1, int(splits[2] if len(splits) > 2 else 1))
    if nx == 1 and ny == 1 and nz == 1:
        return None

    x0, y0, z0 = mins
    x1, y1, z1 = maxs
    dx = x1 - x0
    dy = y1 - y0
    dz = z1 - z0

    pts = vtk.vtkPoints()
    lines = vtk.vtkCellArray()

    def add_segment(a, b):
        ia = pts.InsertNextPoint(float(a[0]), float(a[1]), float(a[2]))
        ib = pts.InsertNextPoint(float(b[0]), float(b[1]), float(b[2]))
        line = vtk.vtkLine()
        line.GetPointIds().SetId(0, ia)
        line.GetPointIds().SetId(1, ib)
        lines.InsertNextCell(line)

    def lerp(t, start, delta):
        return start + delta * t

    # z faces: divide by x and y.
    for i in range(1, nx):
        x = lerp(i / nx, x0, dx)
        add_segment([x, y0, z0], [x, y1, z0])
        add_segment([x, y0, z1], [x, y1, z1])
    for j in range(1, ny):
        y = lerp(j / ny, y0, dy)
        add_segment([x0, y, z0], [x1, y, z0])
        add_segment([x0, y, z1], [x1, y, z1])

    # x faces: divide by y and z.
    for j in range(1, ny):
        y = lerp(j / ny, y0, dy)
        add_segment([x0, y, z0], [x0, y, z1])
        add_segment([x1, y, z0], [x1, y, z1])
    for k in range(1, nz):
        z = lerp(k / nz, z0, dz)
        add_segment([x0, y0, z], [x0, y1, z])
        add_segment([x1, y0, z], [x1, y1, z])

    # y faces: divide by x and z.
    for i in range(1, nx):
        x = lerp(i / nx, x0, dx)
        add_segment([x, y0, z0], [x, y0, z1])
        add_segment([x, y1, z0], [x, y1, z1])
    for k in range(1, nz):
        z = lerp(k / nz, z0, dz)
        add_segment([x0, y0, z], [x1, y0, z])
        add_segment([x0, y1, z], [x1, y1, z])

    poly = vtk.vtkPolyData()
    poly.SetPoints(pts)
    poly.SetLines(lines)
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputData(poly)
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    actor.GetProperty().SetColor(0.88, 0.92, 1.0)
    actor.GetProperty().SetLineWidth(1.2)
    return actor


def build_point_actor(p):
    sphere = vtk.vtkSphereSource()
    sphere.SetCenter(float(p[0]), float(p[1]), float(p[2]))
    sphere.SetRadius(0.04)
    sphere.SetThetaResolution(16)
    sphere.SetPhiResolution(16)
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputConnection(sphere.GetOutputPort())
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    actor.GetProperty().SetColor(1.0, 0.43, 0.57)
    return actor


def build_edge_label(text, pos):
    actor = vtk.vtkBillboardTextActor3D()
    actor.SetInput(text)
    actor.SetPosition(float(pos[0]), float(pos[1]), float(pos[2]))
    prop = actor.GetTextProperty()
    prop.SetColor(0.93, 0.96, 1.0)
    prop.SetFontSize(16)
    prop.BoldOn()
    prop.SetBackgroundColor(0.05, 0.08, 0.11)
    prop.SetBackgroundOpacity(0.8)
    prop.SetFrame(1)
    prop.SetFrameColor(0.42, 0.78, 1.0)
    return actor


def build_axes_actor():
    axes = vtk.vtkAxesActor()
    axes.SetTotalLength(0.8, 0.8, 0.8)
    axes.AxisLabelsOn()
    axes.SetShaftTypeToCylinder()
    return axes


def show_window(payload):
    verts, edges = build_model(payload)
    if not verts:
        verts = [[0.0, 0.0, 0.0]]
    pts = payload.get("points") or []
    mins, maxs = bbox(verts)
    center = [(mins[i] + maxs[i]) / 2.0 for i in range(3)]
    diag = vec_len(vec_sub(maxs, mins))
    if diag <= 1e-9:
        diag = 1.0
    shape = (payload.get("shape") or "").lower()
    splits = payload.get("splits") or []

    renderer = vtk.vtkRenderer()
    renderer.SetBackground(0.05, 0.06, 0.09)
    renderer.SetBackground2(0.08, 0.1, 0.14)
    renderer.GradientBackgroundOn()

    render_window = vtk.vtkRenderWindow()
    render_window.AddRenderer(renderer)
    render_window.SetSize(1280, 840)
    render_window.SetWindowName(f"Impetus Geometry Preview - {payload.get('keyword', '')}")

    interactor = vtk.vtkRenderWindowInteractor()
    interactor.SetRenderWindow(render_window)
    style = vtk.vtkInteractorStyleTrackballCamera()
    interactor.SetInteractorStyle(style)

    if shape == "box":
        renderer.AddActor(build_box_surface_actor(mins, maxs))
        grid_actor = build_box_grid_actor(mins, maxs, splits)
        if grid_actor is not None:
            renderer.AddActor(grid_actor)
    else:
        renderer.AddActor(build_wireframe_actor(verts, edges))

    for p in pts:
      renderer.AddActor(build_point_actor(p))

    if shape == "box":
        dx = maxs[0] - mins[0]
        dy = maxs[1] - mins[1]
        dz = maxs[2] - mins[2]
        label_gap = diag * 0.08
        renderer.AddActor(build_edge_label(f"X: {dx:.3g}", [center[0], mins[1] - label_gap, mins[2] - label_gap]))
        renderer.AddActor(build_edge_label(f"Y: {dy:.3g}", [mins[0] - label_gap, center[1], mins[2] - label_gap]))
        renderer.AddActor(build_edge_label(f"Z: {dz:.3g}", [mins[0] - label_gap, mins[1] - label_gap, center[2]]))
    else:
        for i, (a_idx, b_idx) in enumerate(edges):
            a = verts[a_idx]
            b = verts[b_idx]
            mid = [(a[j] + b[j]) / 2.0 for j in range(3)]
            out = vec_sub(mid, center)
            if vec_len(out) <= 1e-9:
                out = [0.0, 0.0, diag * 0.05]
            else:
                out = vec_scale(vec_norm(out), diag * 0.04)
            label_pos = vec_add(mid, out)
            label = f"{vec_len(vec_sub(b, a)):.3g}"
            renderer.AddActor(build_edge_label(label, label_pos))

    axes = build_axes_actor()
    axes.SetPosition(mins[0], mins[1], mins[2])
    renderer.AddActor(axes)

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

    interactor.Initialize()
    render_window.Render()
    interactor.Start()


def main(argv):
    if len(argv) < 2:
        raise SystemExit("usage: impetus_geometry_viewer.py <payload.json>")
    payload = load_payload(Path(argv[1]))
    show_window(payload)


if __name__ == "__main__":
    main(sys.argv)
