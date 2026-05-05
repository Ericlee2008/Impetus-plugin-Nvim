#!/usr/bin/env python3
from __future__ import annotations

import json
import math
import os
import queue
import sys
import threading
import time

# Simple debug log
_DEBUG_LOG = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "viewer_debug.log"), "w")
def _log(msg):
    _DEBUG_LOG.write(str(msg) + "\n")
    _DEBUG_LOG.flush()

from pathlib import Path

try:
    import vtk
except Exception as exc:  # pragma: no cover
    raise SystemExit(f"VTK import failed: {exc}")

try:
    import tkinter as tk
    from tkinter import colorchooser
except Exception:
    tk = None  # type: ignore


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
    if "pipe" in k:
        return "pipe"
    first = trim(strip_number_prefix(lines[0] if lines else "")).lower()
    if first in {"box", "sphere", "cylinder", "pipe"}:
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


def build_pipe(points, scalars):
    a = points[0] if len(points) >= 1 else [0.0, 0.0, -0.5]
    b = points[1] if len(points) >= 2 else [0.0, 0.0, 0.5]
    axis = vec_norm(vec_sub(b, a))
    ref = [0.0, 0.0, 1.0] if abs(axis[2]) < 0.9 else [1.0, 0.0, 0.0]
    u = vec_norm(cross(axis, ref))
    v = cross(axis, u)
    outer_radius = abs(float(scalars[0])) if len(scalars) >= 1 else 0.5
    inner_radius = abs(float(scalars[1])) if len(scalars) >= 2 else 0.0
    outer_radius = max(outer_radius, 1e-3)
    inner_radius = max(inner_radius, 0.0)
    seg = 24
    outer_ring_a = []
    outer_ring_b = []
    for i in range(seg):
        t = 2 * math.pi * i / seg
        offset = vec_add(vec_scale(u, math.cos(t) * outer_radius), vec_scale(v, math.sin(t) * outer_radius))
        outer_ring_a.append(vec_add(a, offset))
        outer_ring_b.append(vec_add(b, offset))
    verts = outer_ring_a + outer_ring_b
    edges = []
    for i in range(seg):
        edges.append((i, (i + 1) % seg))
        edges.append((seg + i, seg + (i + 1) % seg))
        edges.append((i, seg + i))
    if inner_radius > 1e-6:
        inner_ring_a = []
        inner_ring_b = []
        for i in range(seg):
            t = 2 * math.pi * i / seg
            offset = vec_add(vec_scale(u, math.cos(t) * inner_radius), vec_scale(v, math.sin(t) * inner_radius))
            inner_ring_a.append(vec_add(a, offset))
            inner_ring_b.append(vec_add(b, offset))
        base = len(verts)
        verts.extend(inner_ring_a + inner_ring_b)
        for i in range(seg):
            edges.append((base + i, base + (i + 1) % seg))
            edges.append((base + seg + i, base + seg + (i + 1) % seg))
            edges.append((base + i, base + seg + i))
            edges.append((i, base + i))
            edges.append((seg + i, base + seg + i))
    return verts, edges


def build_model(payload):
    shape = (payload.get("shape") or "").lower()
    points = payload.get("points") or []
    scalars = payload.get("scalars") or payload.get("numbers") or []
    if shape == "sphere":
        return build_sphere(points, scalars)
    if shape == "cylinder":
        return build_cylinder(points, scalars)
    if shape == "pipe":
        return build_pipe(points, scalars)
    return build_box(points, scalars)


def vtk_points(verts):
    pts = vtk.vtkPoints()
    for v in verts:
        pts.InsertNextPoint(float(v[0]), float(v[1]), float(v[2]))
    return pts


def build_wireframe_actor(verts, edges, color=None):
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
    c = color or (0.42, 0.78, 1.0)
    actor.GetProperty().SetColor(c[0], c[1], c[2])
    actor.GetProperty().SetLineWidth(2.5)
    return actor


def build_box_surface_actor(mins, maxs, color=None, opacity=1.0):
    cube = vtk.vtkCubeSource()
    cube.SetBounds(mins[0], maxs[0], mins[1], maxs[1], mins[2], maxs[2])
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputConnection(cube.GetOutputPort())
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    c = color or (0.28, 0.56, 0.82)
    actor.GetProperty().SetColor(c[0], c[1], c[2])
    actor.GetProperty().SetOpacity(opacity)
    actor.GetProperty().SetInterpolationToPhong()
    actor.GetProperty().BackfaceCullingOn()
    return actor


def build_sphere_surface_actor(center, radius, color=None, opacity=1.0):
    source = vtk.vtkSphereSource()
    source.SetCenter(float(center[0]), float(center[1]), float(center[2]))
    source.SetRadius(float(radius))
    source.SetThetaResolution(32)
    source.SetPhiResolution(32)
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputConnection(source.GetOutputPort())
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    c = color or (0.28, 0.56, 0.82)
    actor.GetProperty().SetColor(c[0], c[1], c[2])
    actor.GetProperty().SetOpacity(opacity)
    actor.GetProperty().SetInterpolationToPhong()
    actor.GetProperty().BackfaceCullingOn()
    return actor


def build_cylinder_surface_actor(a, b, radius, color=None, opacity=1.0):
    height = vec_len(vec_sub(b, a))
    center = [(a[i] + b[i]) / 2.0 for i in range(3)]
    source = vtk.vtkCylinderSource()
    source.SetRadius(float(radius))
    source.SetHeight(float(height))
    source.SetResolution(32)

    transform = vtk.vtkTransform()
    transform.Translate(center[0], center[1], center[2])

    ref = [0.0, 1.0, 0.0]
    axis = vec_norm(vec_sub(b, a))
    dot_prod = dot(ref, axis)

    if abs(dot_prod + 1.0) < 1e-6:
        transform.RotateWXYZ(180, 1, 0, 0)
    elif abs(dot_prod - 1.0) > 1e-6:
        rot_axis = cross(ref, axis)
        rot_angle = math.degrees(math.acos(max(-1.0, min(1.0, dot_prod))))
        transform.RotateWXYZ(rot_angle, rot_axis[0], rot_axis[1], rot_axis[2])

    tf = vtk.vtkTransformPolyDataFilter()
    tf.SetInputConnection(source.GetOutputPort())
    tf.SetTransform(transform)

    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputConnection(tf.GetOutputPort())
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    c = color or (0.28, 0.56, 0.82)
    actor.GetProperty().SetColor(c[0], c[1], c[2])
    actor.GetProperty().SetOpacity(opacity)
    actor.GetProperty().SetInterpolationToPhong()
    actor.GetProperty().BackfaceCullingOn()
    return actor


def build_box_grid_actor(mins, maxs, splits, color=None):
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

    for i in range(1, nx):
        x = lerp(i / nx, x0, dx)
        add_segment([x, y0, z0], [x, y1, z0])
        add_segment([x, y0, z1], [x, y1, z1])
    for j in range(1, ny):
        y = lerp(j / ny, y0, dy)
        add_segment([x0, y, z0], [x1, y, z0])
        add_segment([x0, y, z1], [x1, y, z1])
    for j in range(1, ny):
        y = lerp(j / ny, y0, dy)
        add_segment([x0, y, z0], [x0, y, z1])
        add_segment([x1, y, z0], [x1, y, z1])
    for k in range(1, nz):
        z = lerp(k / nz, z0, dz)
        add_segment([x0, y0, z], [x0, y1, z])
        add_segment([x1, y0, z], [x1, y1, z])
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
    c = color or (0.88, 0.92, 1.0)
    actor.GetProperty().SetColor(c[0], c[1], c[2])
    actor.GetProperty().SetLineWidth(1.2)
    return actor


def build_center_label(text, pos, color=None):
    actor = vtk.vtkBillboardTextActor3D()
    actor.SetInput(text)
    actor.SetPosition(float(pos[0]), float(pos[1]), float(pos[2]))
    actor.PickableOff()
    prop = actor.GetTextProperty()
    c = color or (1.0, 1.0, 1.0)
    prop.SetColor(c[0], c[1], c[2])
    prop.SetFontSize(14)
    prop.BoldOn()
    prop.SetBackgroundColor(0.05, 0.08, 0.12)
    prop.SetBackgroundOpacity(0.5)
    prop.SetFrame(1)
    prop.SetFrameColor(0.3, 0.3, 0.3)
    return actor


def build_axes_actor():
    axes = vtk.vtkAxesActor()
    axes.SetTotalLength(1.0, 1.0, 1.0)
    axes.AxisLabelsOn()
    axes.SetShaftTypeToCylinder()
    axes.SetCylinderRadius(0.05)
    axes.SetConeRadius(0.12)
    axes.SetSphereRadius(0.0)
    return axes


def build_box_edge_actor(mins, maxs, color=None):
    """12 edges of a box."""
    x0, y0, z0 = mins
    x1, y1, z1 = maxs
    edge_pairs = [
        ([x0,y0,z0],[x1,y0,z0]), ([x1,y0,z0],[x1,y1,z0]), ([x1,y1,z0],[x0,y1,z0]), ([x0,y1,z0],[x0,y0,z0]),
        ([x0,y0,z1],[x1,y0,z1]), ([x1,y0,z1],[x1,y1,z1]), ([x1,y1,z1],[x0,y1,z1]), ([x0,y1,z1],[x0,y0,z1]),
        ([x0,y0,z0],[x0,y0,z1]), ([x1,y0,z0],[x1,y0,z1]), ([x1,y1,z0],[x1,y1,z1]), ([x0,y1,z0],[x0,y1,z1]),
    ]
    pts = vtk.vtkPoints()
    lines = vtk.vtkCellArray()
    for a, b in edge_pairs:
        ia = pts.InsertNextPoint(a[0], a[1], a[2])
        ib = pts.InsertNextPoint(b[0], b[1], b[2])
        line = vtk.vtkLine()
        line.GetPointIds().SetId(0, ia)
        line.GetPointIds().SetId(1, ib)
        lines.InsertNextCell(line)
    poly = vtk.vtkPolyData()
    poly.SetPoints(pts)
    poly.SetLines(lines)
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputData(poly)
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    c = color or (0.42, 0.78, 1.0)
    actor.GetProperty().SetColor(c[0], c[1], c[2])
    actor.GetProperty().SetLineWidth(2.0)
    actor.PickableOff()
    return actor


def build_sphere_edge_actor(center, radius, color=None):
    """Latitude + longitude wireframe."""
    seg = 24
    rings = 12
    pts = vtk.vtkPoints()
    lines = vtk.vtkCellArray()
    # Latitude rings
    for r in range(1, rings):
        phi = math.pi * r / rings
        base = pts.GetNumberOfPoints()
        for i in range(seg):
            theta = 2 * math.pi * i / seg
            x = center[0] + radius * math.sin(phi) * math.cos(theta)
            y = center[1] + radius * math.sin(phi) * math.sin(theta)
            z = center[2] + radius * math.cos(phi)
            pts.InsertNextPoint(x, y, z)
        for i in range(seg):
            line = vtk.vtkLine()
            line.GetPointIds().SetId(0, base + i)
            line.GetPointIds().SetId(1, base + (i + 1) % seg)
            lines.InsertNextCell(line)
    # Longitude rings
    for i in range(seg):
        theta = 2 * math.pi * i / seg
        base = pts.GetNumberOfPoints()
        for r in range(rings + 1):
            phi = math.pi * r / rings
            x = center[0] + radius * math.sin(phi) * math.cos(theta)
            y = center[1] + radius * math.sin(phi) * math.sin(theta)
            z = center[2] + radius * math.cos(phi)
            pts.InsertNextPoint(x, y, z)
        for r in range(rings):
            line = vtk.vtkLine()
            line.GetPointIds().SetId(0, base + r)
            line.GetPointIds().SetId(1, base + r + 1)
            lines.InsertNextCell(line)
    poly = vtk.vtkPolyData()
    poly.SetPoints(pts)
    poly.SetLines(lines)
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputData(poly)
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    c = color or (0.42, 0.78, 1.0)
    actor.GetProperty().SetColor(c[0], c[1], c[2])
    actor.GetProperty().SetLineWidth(1.5)
    actor.PickableOff()
    return actor


def build_cylinder_edge_actor(a, b, radius, color=None):
    """Top circle + bottom circle + 4 generatrices."""
    axis = vec_norm(vec_sub(b, a))
    ref = [0.0, 0.0, 1.0] if abs(axis[2]) < 0.9 else [1.0, 0.0, 0.0]
    u = vec_norm(cross(axis, ref))
    v = cross(axis, u)
    seg = 24
    pts = vtk.vtkPoints()
    lines = vtk.vtkCellArray()
    # Bottom circle
    bb = pts.GetNumberOfPoints()
    for i in range(seg):
        t = 2 * math.pi * i / seg
        offset = vec_add(vec_scale(u, math.cos(t) * radius), vec_scale(v, math.sin(t) * radius))
        p = vec_add(a, offset)
        pts.InsertNextPoint(p[0], p[1], p[2])
    for i in range(seg):
        line = vtk.vtkLine()
        line.GetPointIds().SetId(0, bb + i)
        line.GetPointIds().SetId(1, bb + (i + 1) % seg)
        lines.InsertNextCell(line)
    # Top circle
    bt = pts.GetNumberOfPoints()
    for i in range(seg):
        t = 2 * math.pi * i / seg
        offset = vec_add(vec_scale(u, math.cos(t) * radius), vec_scale(v, math.sin(t) * radius))
        p = vec_add(b, offset)
        pts.InsertNextPoint(p[0], p[1], p[2])
    for i in range(seg):
        line = vtk.vtkLine()
        line.GetPointIds().SetId(0, bt + i)
        line.GetPointIds().SetId(1, bt + (i + 1) % seg)
        lines.InsertNextCell(line)
    # 4 generatrices
    for i in [0, seg // 4, seg // 2, 3 * seg // 4]:
        t = 2 * math.pi * i / seg
        offset = vec_add(vec_scale(u, math.cos(t) * radius), vec_scale(v, math.sin(t) * radius))
        p1 = vec_add(a, offset)
        p2 = vec_add(b, offset)
        i1 = pts.InsertNextPoint(p1[0], p1[1], p1[2])
        i2 = pts.InsertNextPoint(p2[0], p2[1], p2[2])
        line = vtk.vtkLine()
        line.GetPointIds().SetId(0, i1)
        line.GetPointIds().SetId(1, i2)
        lines.InsertNextCell(line)
    poly = vtk.vtkPolyData()
    poly.SetPoints(pts)
    poly.SetLines(lines)
    mapper = vtk.vtkPolyDataMapper()
    mapper.SetInputData(poly)
    actor = vtk.vtkActor()
    actor.SetMapper(mapper)
    c = color or (0.42, 0.78, 1.0)
    actor.GetProperty().SetColor(c[0], c[1], c[2])
    actor.GetProperty().SetLineWidth(2.0)
    actor.PickableOff()
    return actor


DEFAULT_COLORS = [
    (0.20, 0.50, 0.90),
    (0.90, 0.25, 0.25),
    (0.25, 0.80, 0.35),
    (1.00, 0.70, 0.15),
    (0.80, 0.30, 0.80),
    (0.20, 0.80, 0.85),
    (1.00, 0.50, 0.20),
    (0.55, 0.35, 0.85),
    (0.85, 0.60, 0.30),
    (0.40, 0.75, 0.55),
]

# ── Modern Dark Theme Palette ──
_UI_BG = "#0d1117"          # main window bg
_UI_PANEL_BG = "#111720"    # side panel bg
_UI_CARD_BG = "#18202b"     # card / row bg
_UI_CARD_HOVER = "#1e293b"  # row hover
_UI_ROW_SEL = "#1a3452"     # row selected (accent tint)
_UI_FG = "#e6edf3"          # primary text
_UI_FG_DIM = "#848d9a"      # muted text
_UI_ACCENT = "#4493f8"      # accent blue
_UI_ACCENT_DIM = "#2563eb"  # deeper accent
_UI_BORDER = "#212a35"      # subtle border
_UI_BTN_BG = "#1c2331"      # button bg
_UI_BTN_HOVER = "#2a3648"   # button hover
_UI_TREE_LINE = "#252e3b"   # tree connector line color
_UI_TAG_COMP = "#4493f8"    # COMPONENT tag color
_UI_TAG_GEOM = "#7c3aed"    # GEOMETRY tag color


def get_object_opacity(keyword):
    kw = (keyword or "").upper()
    if kw.startswith("*GEOMETRY"):
        return 0.35
    elif kw.startswith("*COMPONENT"):
        return 1.0
    return 0.6


def is_solid_keyword(keyword):
    return (keyword or "").upper().startswith("*COMPONENT")


def get_object_center(obj):
    shape = (obj.get("shape") or "").lower()
    pts = obj.get("points") or []
    if shape == "box" and pts and len(pts) >= 2:
        mins = pts[0]
        maxs = pts[1]
        return [(mins[i] + maxs[i]) / 2.0 for i in range(3)]
    else:
        verts, _ = build_model(obj)
        if verts:
            mins, maxs = bbox(verts)
            return [(mins[i] + maxs[i]) / 2.0 for i in range(3)]
    return [0.0, 0.0, 0.0]


# ══════════════════════════════════════════════════════════
#  Finite element mesh rendering
# ══════════════════════════════════════════════════════════

def build_mesh_surface(payload):
    """Build surface actors from ELEMENT_SOLID + NODE mesh data."""
    nodes = payload.get("nodes") or {}
    elements = payload.get("elements") or []
    _log(f"[mesh] nodes={len(nodes)}, elements={len(elements)}")
    if not nodes or not elements:
        _log("[mesh] empty nodes or elements — skipping")
        return None, None, 0

    # ── Map node IDs to point indices (keys are strings from JSON) ──
    nid_list = sorted(nodes.keys(), key=lambda k: int(k))
    nid_to_idx = {int(nid): i for i, nid in enumerate(nid_list)}

    pts = vtk.vtkPoints()
    for nid_str in nid_list:
        xyz = nodes[nid_str]
        pts.InsertNextPoint(float(xyz[0]), float(xyz[1]), float(xyz[2]))

    # Group elements by part ID for coloring
    part_elements = {}
    for el in elements:
        pid = el.get("pid", 1)
        part_elements.setdefault(pid, []).append(el)
    part_ids = sorted(part_elements.keys())

    # ── Build per-part surface/edge actors ──
    cell_types = {"hex": vtk.VTK_HEXAHEDRON, "penta": vtk.VTK_WEDGE, "tetra": vtk.VTK_TETRA}
    all_actors = []
    part_colors = {}

    _log(f"[mesh] {len(part_ids)} parts, {sum(len(v) for v in part_elements.values())} total elements")

    for pi, pid in enumerate(part_ids):
        els = part_elements[pid]
        etype = els[0].get("etype", "hex") if els else "hex"
        _log(f"[mesh] part {pid}: {len(els)} elements, etype={etype}")
        ugrid = vtk.vtkUnstructuredGrid()
        ugrid.SetPoints(pts)

        cells = vtk.vtkCellArray()
        skipped = 0
        for el in els:
            etype_el = el.get("etype", "hex")
            vtk_cell_type = cell_types.get(etype_el)
            if vtk_cell_type is None:
                skipped += 1
                continue
            enodes = el.get("nodes") or []
            if len(enodes) < 4:
                skipped += 1
                continue

            # Map node IDs to point indices
            indices = [nid_to_idx.get(n, -1) for n in enodes]
            if -1 in indices:
                skipped += 1
                continue

            if vtk_cell_type == vtk.VTK_HEXAHEDRON and len(indices) >= 8:
                cell = vtk.vtkHexahedron()
                for j in range(8):
                    cell.GetPointIds().SetId(j, indices[j])
            elif vtk_cell_type == vtk.VTK_WEDGE and len(indices) >= 6:
                cell = vtk.vtkWedge()
                for j in range(6):
                    cell.GetPointIds().SetId(j, indices[j])
            elif vtk_cell_type == vtk.VTK_TETRA and len(indices) >= 4:
                cell = vtk.vtkTetra()
                for j in range(4):
                    cell.GetPointIds().SetId(j, indices[j])
            else:
                skipped += 1
                continue
            cells.InsertNextCell(cell)

        _log(f"[mesh] part {pid}: {cells.GetNumberOfCells()} cells built, {skipped} skipped")
        if cells.GetNumberOfCells() == 0:
            continue

        ugrid.SetCells(vtk_cell_type, cells)

        # Extract surface of this part
        surface_filter = vtk.vtkDataSetSurfaceFilter()
        surface_filter.SetInputData(ugrid)
        surface_filter.Update()

        # Surface actor (semi-transparent)
        color = DEFAULT_COLORS[pi % len(DEFAULT_COLORS)]
        part_colors[pid] = color

        surf_mapper = vtk.vtkPolyDataMapper()
        surf_mapper.SetInputConnection(surface_filter.GetOutputPort())
        surf_actor = vtk.vtkActor()
        surf_actor.SetMapper(surf_mapper)
        surf_actor.GetProperty().SetColor(color[0], color[1], color[2])
        surf_actor.GetProperty().SetOpacity(0.4)
        surf_actor.GetProperty().SetInterpolationToPhong()
        surf_actor.GetProperty().BackfaceCullingOn()
        surf_actor.GetProperty().SetAmbient(0.2)
        surf_actor.GetProperty().SetDiffuse(0.7)
        surf_actor.GetProperty().SetSpecular(0.3)
        surf_actor.GetProperty().SetSpecularPower(20)

        # Edge actor (wireframe overlay)
        edge_mapper = vtk.vtkPolyDataMapper()
        edge_mapper.SetInputConnection(surface_filter.GetOutputPort())
        edge_actor = vtk.vtkActor()
        edge_actor.SetMapper(edge_mapper)
        edge_actor.GetProperty().SetColor(0.0, 0.0, 0.0)
        edge_actor.GetProperty().SetRepresentationToWireframe()
        edge_actor.GetProperty().SetLineWidth(1.0)
        edge_actor.GetProperty().SetAmbient(1.0)
        edge_actor.GetProperty().SetDiffuse(0.0)

        all_actors.append({
            "pid": pid,
            "surface": surf_actor,
            "edge": edge_actor,
            "color": color,
        })

    # Count totals
    total_els = sum(len(v) for v in part_elements.values())
    return all_actors, part_colors, total_els


class ViewerState:
    def __init__(self, objects, renderer, interactor, om=None):
        self.objects = objects
        self.mesh_actors = []  # list of {surface, edge, color, pid}
        self.selected_idx = -1
        self.renderer = renderer
        self.interactor = interactor
        self.om = om
        self.needs_render = False
        self.panel_rows = []
        self.tk_root = None
        self.selection_mode = "camera"  # "camera", "hide_select", "show_select", "identify"
        self._rubberband_actors = []
        self._rubberband_sources = []
        self._identify_actor = None
        self._identify_idx = -1
        self._drag_start = None
        self._drag_current = None
        self._is_dragging = False
        self._hover_idx = -1
        self._should_exit = False
        self.display_mode = "shadow"  # "framework", "shadow", "shadow_framework"
        self._show_select_mask = []  # bool list for show-select mode
        # Selection-mode interaction state
        self._select_button_down = False
        self._select_has_dragged = False
        self._select_rotation_started = False
        self._press_picked_idx = -1
        self._box_highlight_indices = set()
        self._camera_mode = None
        self._camera_last_pos = None
        self._rotate_marker_actor = None

    def _request_render(self):
        self.needs_render = True

    def set_display_mode(self, mode):
        self.display_mode = mode
        for i in range(len(self.objects)):
            self.apply_display_mode(i)
        self._request_render()

    def apply_display_mode(self, idx):
        obj = self.objects[idx]
        mode = self.display_mode
        shape = (obj.get("shape") or "").lower()
        is_wireframe_only = (shape not in ("box", "sphere", "cylinder", "pipe", "mesh"))
        
        actor = obj.get("actor")
        edge = obj.get("edge_actor")
        grid = obj.get("grid_actor")
        inner = obj.get("inner_actor")
        label = obj.get("label_actor")
        
        if is_wireframe_only:
            # Default wireframe shapes only have a wireframe actor
            if actor:
                actor.SetVisibility(1 if obj.get("visible", True) else 0)
            if edge:
                edge.SetVisibility(0)
            if grid:
                grid.SetVisibility(0)
            if inner:
                inner.SetVisibility(0)
            if label:
                label.SetVisibility(1 if obj.get("visible", True) else 0)
            return
        
        if mode == "framework":
            if actor:
                actor.SetVisibility(0)
            if edge:
                edge.SetVisibility(1 if obj.get("visible", True) else 0)
            if grid:
                grid.SetVisibility(1 if obj.get("visible", True) else 0)
            if inner:
                inner.SetVisibility(1 if obj.get("visible", True) else 0)
            if label:
                label.SetVisibility(1 if obj.get("visible", True) else 0)
        elif mode == "shadow":
            if actor:
                actor.SetVisibility(1 if obj.get("visible", True) else 0)
                actor.GetProperty().SetOpacity(obj.get("opacity", 1.0))
            if edge:
                edge.SetVisibility(0)
            if grid:
                grid.SetVisibility(0)
            if inner:
                inner.SetVisibility(0)
            if label:
                label.SetVisibility(1 if obj.get("visible", True) else 0)
        else:  # shadow_framework
            if actor:
                actor.SetVisibility(1 if obj.get("visible", True) else 0)
                actor.GetProperty().SetOpacity(1.0)
            if edge:
                edge.SetVisibility(1 if obj.get("visible", True) else 0)
            if grid:
                grid.SetVisibility(0)
            if inner:
                inner.SetVisibility(0)
            if label:
                label.SetVisibility(1 if obj.get("visible", True) else 0)

    def select_object(self, idx):
        if idx < 0 or idx >= len(self.objects):
            return
        old_idx = self.selected_idx
        self.selected_idx = idx
        if old_idx >= 0 and old_idx < len(self.objects):
            self._set_highlight(old_idx, False)
        self._set_highlight(idx, True)
        self._request_render()
        self._refresh_panel()

    def _set_highlight(self, idx, on):
        obj = self.objects[idx]
        base_color = obj.get("color", DEFAULT_COLORS[0])
        for key in ("actor", "edge_actor"):
            a = obj.get(key)
            if a:
                if on:
                    hl = (min(1.0, base_color[0] + 0.35), min(1.0, base_color[1] + 0.35), min(1.0, base_color[2] + 0.35))
                    a.GetProperty().SetColor(hl[0], hl[1], hl[2])
                else:
                    a.GetProperty().SetColor(base_color[0], base_color[1], base_color[2])
        actor = obj.get("actor")
        if actor:
            if on:
                actor.GetProperty().SetAmbient(0.6)
                actor.GetProperty().SetSpecular(0.8)
                actor.GetProperty().SetSpecularPower(30)
            else:
                actor.GetProperty().SetAmbient(0.0)
                actor.GetProperty().SetSpecular(0.0)
                actor.GetProperty().SetSpecularPower(1.0)
        inner = obj.get("inner_actor")
        if inner:
            if on:
                hl = (min(1.0, base_color[0] + 0.35), min(1.0, base_color[1] + 0.35), min(1.0, base_color[2] + 0.35))
                inner.GetProperty().SetColor(hl[0], hl[1], hl[2])
            else:
                inner.GetProperty().SetColor(base_color[0], base_color[1], base_color[2])

    def _set_hover(self, idx, on):
        """Temporary hover highlight (press-preview) without affecting selected_idx."""
        if idx < 0 or idx >= len(self.objects):
            return
        obj = self.objects[idx]
        base_color = obj.get("color", DEFAULT_COLORS[0])
        for key in ("actor", "edge_actor"):
            a = obj.get(key)
            if a:
                if on:
                    hl = (min(1.0, base_color[0] + 0.55), min(1.0, base_color[1] + 0.55), min(1.0, base_color[2] + 0.55))
                    a.GetProperty().SetColor(hl[0], hl[1], hl[2])
                else:
                    is_selected = (self.selected_idx == idx)
                    if is_selected:
                        hl = (min(1.0, base_color[0] + 0.35), min(1.0, base_color[1] + 0.35), min(1.0, base_color[2] + 0.35))
                        a.GetProperty().SetColor(hl[0], hl[1], hl[2])
                    else:
                        a.GetProperty().SetColor(base_color[0], base_color[1], base_color[2])
        actor = obj.get("actor")
        if actor:
            if on:
                actor.GetProperty().SetAmbient(0.8)
                actor.GetProperty().SetSpecular(1.0)
                actor.GetProperty().SetSpecularPower(45)
            else:
                is_selected = (self.selected_idx == idx)
                if is_selected:
                    actor.GetProperty().SetAmbient(0.6)
                    actor.GetProperty().SetSpecular(0.8)
                    actor.GetProperty().SetSpecularPower(30)
                else:
                    actor.GetProperty().SetAmbient(0.0)
                    actor.GetProperty().SetSpecular(0.0)
                    actor.GetProperty().SetSpecularPower(1.0)
        inner = obj.get("inner_actor")
        if inner:
            if on:
                hl = (min(1.0, base_color[0] + 0.55), min(1.0, base_color[1] + 0.55), min(1.0, base_color[2] + 0.55))
                inner.GetProperty().SetColor(hl[0], hl[1], hl[2])
            else:
                is_selected = (self.selected_idx == idx)
                if is_selected:
                    hl = (min(1.0, base_color[0] + 0.35), min(1.0, base_color[1] + 0.35), min(1.0, base_color[2] + 0.35))
                    inner.GetProperty().SetColor(hl[0], hl[1], hl[2])
                else:
                    inner.GetProperty().SetColor(base_color[0], base_color[1], base_color[2])
        self._request_render()

    def set_visibility(self, idx, visible):
        if idx < 0 or idx >= len(self.objects):
            return
        obj = self.objects[idx]
        obj["visible"] = visible
        self.apply_display_mode(idx)
        self._request_render()

    def set_color(self, idx, color):
        if idx < 0 or idx >= len(self.objects):
            return
        obj = self.objects[idx]
        obj["color"] = color
        for key in ("actor", "edge_actor", "grid_actor", "inner_actor"):
            a = obj.get(key)
            if a:
                a.GetProperty().SetColor(color[0], color[1], color[2])
        label = obj.get("label_actor")
        if label:
            label.GetTextProperty().SetColor(color[0], color[1], color[2])
        self._request_render()
        self._refresh_panel()

    def cycle_color_for(self, idx):
        if idx < 0 or idx >= len(self.objects):
            return
        obj = self.objects[idx]
        obj["color_idx"] = (obj.get("color_idx", 0) + 1) % len(DEFAULT_COLORS)
        self.set_color(idx, DEFAULT_COLORS[obj["color_idx"]])

    def set_all_visibility(self, visible):
        for i in range(len(self.objects)):
            self.set_visibility(i, visible)
        self._refresh_panel()

    def _refresh_panel(self):
        for row_info in self.panel_rows:
            obj_idx = row_info.get("obj_idx")
            if obj_idx is None or obj_idx >= len(self.objects):
                continue
            obj = self.objects[obj_idx]
            color = obj.get("color", DEFAULT_COLORS[obj.get("color_idx", obj_idx) % len(DEFAULT_COLORS)])
            base_bg = row_info.get("base_bg", _UI_CARD_BG)

            # Update color swatch
            if "swatch" in row_info and row_info["swatch"].winfo_exists():
                swatch_color = "#%02x%02x%02x" % (int(color[0] * 255), int(color[1] * 255), int(color[2] * 255))
                canvas = row_info["swatch"]
                sid = row_info.get("swatch_id")
                if sid is not None:
                    canvas.itemconfig(sid, fill=swatch_color)
                else:
                    canvas.configure(bg=swatch_color)

            # Update checkbox
            if "var" in row_info:
                row_info["var"].set(1 if obj.get("visible", True) else 0)

            # Update row background (selected vs normal)
            is_selected = (obj_idx == self.selected_idx)
            target_bg = _UI_ROW_SEL if is_selected else base_bg
            border_color = _UI_ACCENT if is_selected else _UI_BORDER

            frame = row_info.get("frame")
            if frame and frame.winfo_exists():
                try:
                    frame.configure(bg=target_bg, highlightbackground=border_color)
                    # Cascade background to children that match the base
                    for child in frame.winfo_children():
                        try:
                            cur = child.cget("bg")
                            if isinstance(child, tk.Frame):
                                child.configure(bg=target_bg)
                                for c2 in child.winfo_children():
                                    try:
                                        if c2.cget("bg") in (_UI_CARD_BG, _UI_CARD_HOVER, _UI_ROW_SEL):
                                            c2.configure(bg=target_bg)
                                    except Exception:
                                        pass
                            elif cur in (_UI_CARD_BG, _UI_CARD_HOVER, _UI_ROW_SEL):
                                child.configure(bg=target_bg)
                        except Exception:
                            pass
                except Exception:
                    pass


def _reparent_vtk_into_frame(render_window, vtk_frame):
    import ctypes
    from ctypes import wintypes

    user32 = ctypes.windll.user32
    WS_CHILD = 0x40000000
    WS_CLIPSIBLINGS = 0x04000000
    WS_CLIPCHILDREN = 0x02000000
    GWL_STYLE = -16

    tk_hwnd = vtk_frame.winfo_id()
    win_title = render_window.GetWindowName()
    _log(f"[reparent] tk_hwnd={tk_hwnd:#x}, win_title='{win_title}'")

    # Try render_window's own window ID first, fallback to FindWindowW by title
    vtk_hwnd = None
    try:
        vtk_hwnd = render_window.GetWindowId()
        _log(f"[reparent] GetWindowId() returned {vtk_hwnd:#x}")
    except Exception as exc:
        _log(f"[reparent] GetWindowId() failed: {exc}")
    if not vtk_hwnd:
        _log("[reparent] GetWindowId returned 0/null, trying FindWindowW...")
        for i in range(100):
            vtk_hwnd = user32.FindWindowW(None, win_title)
            if vtk_hwnd:
                _log(f"[reparent] FindWindowW found {vtk_hwnd:#x} at attempt {i}")
                break
            time.sleep(0.01)
        if not vtk_hwnd:
            # Try without the title suffix that VTK sometimes adds (e.g. " - VTK" or " #1")
            _log("[reparent] FindWindowW by full title failed, trying partial match via EnumWindows...")
            WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
            found_hwnds = []
            def _enum_cb(hwnd, _):
                length = user32.GetWindowTextLengthW(hwnd)
                if length == 0:
                    return True
                buf = ctypes.create_unicode_buffer(length + 1)
                user32.GetWindowTextW(hwnd, buf, length + 1)
                title = buf.value
                if "Impetus" in title or "VTK" in title or "vtk" in title:
                    found_hwnds.append((hwnd, title))
                return True
            user32.EnumWindows(WNDENUMPROC(_enum_cb), 0)
            _log(f"[reparent] EnumWindows found candidates: {found_hwnds}")
            for hwnd, title in found_hwnds:
                if "Impetus" in title and "tk" not in title.lower():
                    vtk_hwnd = hwnd
                    _log(f"[reparent] selected VTK window: {vtk_hwnd:#x} title='{title}'")
                    break

    if not vtk_hwnd:
        _log("[reparent] FAILED to find VTK window HWND — embedding skipped")
        return None

    _log(f"[reparent] embedding vtk_hwnd={vtk_hwnd:#x} into tk_hwnd={tk_hwnd:#x}")
    # Reparent first, then fix styles (safer order)
    old_parent = user32.SetParent(vtk_hwnd, tk_hwnd)
    _log(f"[reparent] SetParent returned old_parent={old_parent:#x}")
    style = user32.GetWindowLongW(vtk_hwnd, GWL_STYLE)
    _log(f"[reparent] old style={style:#x}")
    style &= ~0x00CF0000
    style |= WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN
    user32.SetWindowLongW(vtk_hwnd, GWL_STYLE, style)
    # Refresh frame so style change takes effect
    user32.SetWindowPos(vtk_hwnd, 0, 0, 0, 0, 0,
                        0x0277)  # SWP_FRAMECHANGED|NOMOVE|NOSIZE|NOZORDER|SHOWWINDOW|NOACTIVATE|NOOWNERZORDER
    user32.RedrawWindow(vtk_hwnd, None, None, 0x0400 | 0x0001 | 0x0080)  # RDW_FRAME|INVALIDATE|ALLCHILDREN
    user32.ShowWindow(vtk_hwnd, 1)
    user32.SetFocus(tk_hwnd)
    _log("[reparent] embedding complete")

    def _resize_vtk():
        """Fit VTK render window into frame — use multiple fallback methods."""
        w = vtk_frame.winfo_width()
        h = vtk_frame.winfo_height()
        _log(f"[reparent] resize attempt: winfo w={w} h={h}")
        # winfo_width returns 1 for unmapped frames — try alternatives
        if w <= 1:
            w = vtk_frame.winfo_reqwidth()
            _log(f"[reparent] resize fallback reqwidth={w}")
        if h <= 1:
            h = vtk_frame.winfo_reqheight()
            _log(f"[reparent] resize fallback reqheight={h}")
        # Still bad? Use the master container
        if w <= 1:
            master = vtk_frame.master
            w = master.winfo_width()
            _log(f"[reparent] resize fallback master.winfo_width={w}")
        if h <= 1:
            master = vtk_frame.master
            h = master.winfo_height()
            _log(f"[reparent] resize fallback master.winfo_height={h}")
        # Absolute last resort: use root geometry
        root = vtk_frame.winfo_toplevel()
        if w <= 1 and root:
            w = root.winfo_width() - 320  # subtract panel width
            _log(f"[reparent] resize fallback root width={w}")
        if h <= 1 and root:
            h = root.winfo_height() - 80  # subtract toolbar
            _log(f"[reparent] resize fallback root height={h}")
        if w > 10 and h > 10:
            render_window.SetPosition(0, 0)
            render_window.SetSize(w, h)
            render_window.Render()
            _log(f"[reparent] VTK resized to {w}x{h}")
        else:
            _log(f"[reparent] WARNING: final size {w}x{h} too small, retrying in 200ms")
            vtk_frame.after(200, _resize_vtk)

    _resize_vtk()

    def on_resize(event=None):
        w = vtk_frame.winfo_width()
        h = vtk_frame.winfo_height()
        if w > 10 and h > 10:
            render_window.SetPosition(0, 0)
            render_window.SetSize(w, h)
            render_window.Render()

    vtk_frame.bind("<Configure>", on_resize)
    return vtk_hwnd


def populate_panel(state):
    """Build a modern tree view: Group → Sub-category → Item with tree lines."""

    def rgb_to_hex(rgb):
        return "#%02x%02x%02x" % (int(rgb[0] * 255), int(rgb[1] * 255), int(rgb[2] * 255))

    def hex_to_rgb(hex_str):
        hex_str = hex_str.lstrip("#")
        return tuple(int(hex_str[i:i + 2], 16) / 255.0 for i in (0, 2, 4))

    def on_visibility_toggle(idx):
        state.set_visibility(idx, not state.objects[idx].get("visible", True))

    def on_color_click(idx):
        obj = state.objects[idx]
        current = obj.get("color", DEFAULT_COLORS[obj.get("color_idx", idx) % len(DEFAULT_COLORS)])

        # Close any existing picker
        if hasattr(state, '_color_picker') and state._color_picker:
            try:
                state._color_picker.destroy()
            except Exception:
                pass
            state._color_picker = None

        picker = tk.Toplevel(state.tk_root)
        state._color_picker = picker
        picker.title(f"Color for #{idx + 1}")
        picker.configure(bg=_UI_CARD_BG)
        picker.geometry("260x90")
        picker.resizable(False, False)
        picker.transient(state.tk_root)
        picker.grab_set()

        def _apply(color):
            state.set_color(idx, color)
            picker.destroy()
            state._color_picker = None

        # Preset colors
        presets = tk.Frame(picker, bg=_UI_CARD_BG)
        presets.pack(pady=(10, 4))
        for c in DEFAULT_COLORS:
            hex_c = rgb_to_hex(c)
            btn = tk.Canvas(presets, width=22, height=22, bg=_UI_CARD_BG,
                            highlightthickness=0, bd=0)
            btn.create_rectangle(1, 1, 21, 21, fill=hex_c, outline="#333333", width=1)
            btn.pack(side="left", padx=2)
            btn.bind("<Button-1>", lambda e, color=c: _apply(color))

        # Custom hex entry
        row = tk.Frame(picker, bg=_UI_CARD_BG)
        row.pack(pady=4)
        tk.Label(row, text="#", bg=_UI_CARD_BG, fg=_UI_FG, font=("Segoe UI", 9)).pack(side="left")
        entry = tk.Entry(row, width=8, font=("Consolas", 10))
        entry.insert(0, rgb_to_hex(current))
        entry.pack(side="left", padx=2)

        def _apply_custom():
            hex_str = entry.get().strip()
            if hex_str:
                try:
                    _apply(hex_to_rgb(hex_str))
                except Exception:
                    pass

        tk.Button(row, text="OK", command=_apply_custom,
                  bg=_UI_ACCENT, fg=_UI_BG, relief="flat", bd=0,
                  font=("Segoe UI", 9), padx=8, pady=2).pack(side="left", padx=4)
        tk.Button(row, text="Cancel", command=lambda: (picker.destroy(), setattr(state, '_color_picker', None)),
                  bg=_UI_BTN_BG, fg=_UI_FG, relief="flat", bd=0,
                  font=("Segoe UI", 9), padx=8, pady=2).pack(side="left", padx=4)

    def on_row_click(idx):
        state.select_object(idx)

    # Clear old content
    for child in state._list_frame.winfo_children():
        child.destroy()
    state.panel_rows.clear()

    if not state.objects:
        empty = tk.Label(state._list_frame, text="No objects loaded",
                         font=("Segoe UI", 11), bg=_UI_BG, fg=_UI_FG_DIM)
        empty.pack(pady=30)
        if hasattr(state, "_total_label") and state._total_label:
            state._total_label.configure(text="Total: 0")
        return

    # ── Shape type icons ──
    SHAPE_ICONS = {
        "box": "▣", "sphere": "●", "cylinder": "▮", "pipe": "◉",
    }
    SHAPE_LABELS = {
        "box": "Box", "sphere": "Sphere", "cylinder": "Cylinder", "pipe": "Pipe",
    }

    # ── Group objects: COMPONENT / GEOMETRY / MESH → shape type → items ──
    # Structure: groups[group_name][shape_label] = [idx, ...]
    groups = {"COMPONENT": {}, "GEOMETRY": {}, "MESH": {}}
    for i, obj in enumerate(state.objects):
        kw = (obj.get("keyword") or "").upper()
        shape = (obj.get("shape") or "").lower()

        if shape == "mesh":
            groups["MESH"].setdefault("Element", []).append(i)
        else:
            shape_label = SHAPE_LABELS.get(shape, "Wire")
            if kw.startswith("*COMPONENT_"):
                grp = groups["COMPONENT"]
            else:
                grp = groups["GEOMETRY"]
            grp.setdefault(shape_label, []).append(i)

    # ── Group header colors & icons ──
    GROUP_STYLE = {
        "COMPONENT": {"accent": _UI_TAG_COMP, "icon": "◆", "desc": "Solid parts"},
        "GEOMETRY": {"accent": _UI_TAG_GEOM, "icon": "◇", "desc": "Wireframe geometry"},
        "MESH":      {"accent": "#22c55e", "icon": "▥", "desc": "Finite element mesh"},
    }

    # Mesh is always last
    GROUP_ORDER = ["COMPONENT", "GEOMETRY", "MESH"]

    def _tree_line(is_last, has_more, indent):
        """Return a tree-drawing prefix like '│  ├─' or '   └─'."""
        parts = []
        for lvl in indent:
            parts.append("│  " if lvl else "   ")
        if is_last:
            parts.append("└─ " if not has_more else "├─ ")
        return "".join(parts)

    # ── Build tree ──
    group_order = [g for g in GROUP_ORDER if groups[g]]
    total_visible_groups = len(group_order)

    for gi, gname in enumerate(group_order):
        shape_map = groups[gname]
        gstyle = GROUP_STYLE[gname]
        total_in_group = sum(len(v) for v in shape_map.values())
        is_last_group = (gi == total_visible_groups - 1)

        # ── Group header ──
        g_header = tk.Frame(state._list_frame, bg=_UI_CARD_BG,
                            highlightbackground=_UI_BORDER, highlightthickness=1)
        g_header.pack(fill="x", pady=(8 if gi > 0 else 0, 0))
        g_hdr_inner = tk.Frame(g_header, bg=_UI_CARD_BG, padx=10, pady=6)
        g_hdr_inner.pack(fill="x")

        g_arrow = tk.Label(g_hdr_inner, text="▼", font=("Segoe UI", 8),
                          bg=_UI_CARD_BG, fg=_UI_FG_DIM, width=1)
        g_arrow.pack(side="left")
        g_icon_lbl = tk.Label(g_hdr_inner, text=gstyle["icon"], font=("Segoe UI", 11),
                              bg=_UI_CARD_BG, fg=gstyle["accent"])
        g_icon_lbl.pack(side="left", padx=(4, 0))
        g_title = tk.Label(g_hdr_inner, text=gname, font=("Segoe UI", 10, "bold"),
                          bg=_UI_CARD_BG, fg=gstyle["accent"])
        g_title.pack(side="left", padx=(4, 0))
        g_count = tk.Label(g_hdr_inner, text=str(total_in_group),
                          font=("Segoe UI", 9), bg=_UI_CARD_BG, fg=_UI_FG_DIM)
        g_count.pack(side="right")

        g_container = tk.Frame(state._list_frame, bg=_UI_BG)
        g_container.pack(fill="x")
        g_exp_state = [True]  # mutable to avoid nonlocal sharing across loop iterations

        def _make_group_toggle(container, arrow, state_ref):
            def _toggle(e=None):
                state_ref[0] = not state_ref[0]
                if state_ref[0]:
                    container.pack(fill="x")
                    arrow.configure(text="▼")
                else:
                    container.pack_forget()
                    arrow.configure(text="▶")
            return _toggle

        g_toggle = _make_group_toggle(g_container, g_arrow, g_exp_state)
        for w in (g_header, g_hdr_inner, g_arrow, g_icon_lbl, g_title, g_count):
            w.bind("<Button-1>", g_toggle)

        # ── Sub-categories within the group ──
        shape_order = sorted(shape_map.keys())
        for si, shape_label in enumerate(shape_order):
            indices = shape_map[shape_label]
            is_last_shape = (si == len(shape_order) - 1)

            # Sub-category header — s_exp_state MUST be defined before s_arrow
            s_exp_state = [True]  # mutable to avoid nonlocal sharing across loop iterations

            s_header = tk.Frame(g_container, bg=_UI_BG, padx=0, pady=2)
            s_header.pack(fill="x")
            s_hdr_row = tk.Frame(s_header, bg=_UI_BG)
            s_hdr_row.pack(fill="x", padx=(20, 4))
            s_arrow = tk.Label(s_hdr_row, text="▼" if s_exp_state[0] else "▶", font=("Segoe UI", 7),
                              bg=_UI_BG, fg=_UI_FG_DIM, width=1)
            s_arrow.pack(side="left")
            s_icon = SHAPE_ICONS.get(shape_label.lower(), "▪")
            s_lbl = tk.Label(s_hdr_row, text=f"{s_icon}  {shape_label}",
                            font=("Segoe UI", 9), bg=_UI_BG, fg=_UI_FG_DIM)
            s_lbl.pack(side="left")
            s_cnt = tk.Label(s_hdr_row, text=str(len(indices)), font=("Segoe UI", 8),
                            bg=_UI_BG, fg=_UI_FG_DIM)
            s_cnt.pack(side="right")

            s_container = tk.Frame(g_container, bg=_UI_BG)
            s_container.pack(fill="x")

            def _make_shape_toggle(cont, arr, state_ref):
                def _toggle(e=None):
                    state_ref[0] = not state_ref[0]
                    if state_ref[0]:
                        cont.pack(fill="x")
                        arr.configure(text="▼")
                    else:
                        cont.pack_forget()
                        arr.configure(text="▶")
                return _toggle

            s_toggle = _make_shape_toggle(s_container, s_arrow, s_exp_state)
            for w in (s_header, s_hdr_row, s_arrow, s_lbl, s_cnt):
                w.bind("<Button-1>", s_toggle)

            # ── Tree lines / indent for items ──
            _log(f"[populate_panel] building items for {gname}/{shape_label}: {len(indices)} items")
            for oi, obj_idx in enumerate(indices):
                obj = state.objects[obj_idx]
                is_last_item = (oi == len(indices) - 1)
                indent = [not is_last_shape, True]  # group-level, shape-level indent

                # Build tree prefix
                prefix_parts = ["   "]  # group indent
                prefix_parts.append("│  " if not is_last_shape else "   ")  # shape indent
                prefix_parts.append("└─ " if is_last_item else "├─ ")  # item indent
                tree_prefix = "".join(prefix_parts)

                row = tk.Frame(s_container, bg=_UI_CARD_BG, padx=4, pady=3)
                row.pack(fill="x", pady=1)
                _bg_ref = [_UI_CARD_BG]

                # Tree line label
                tree_lbl = tk.Label(row, text=tree_prefix, font=("Consolas", 7),
                                   bg=_UI_CARD_BG, fg=_UI_TREE_LINE)
                tree_lbl.pack(side="left")

                color = obj.get("color", DEFAULT_COLORS[obj_idx % len(DEFAULT_COLORS)])
                color_hex = rgb_to_hex(color)

                # Checkbox
                var = tk.IntVar(value=1 if obj.get("visible", True) else 0)
                cb = tk.Checkbutton(row, variable=var, bg=_UI_CARD_BG,
                                    activebackground=_UI_CARD_BG,
                                    selectcolor=_UI_CARD_BG,
                                    command=lambda idx=obj_idx: on_visibility_toggle(idx))
                cb.pack(side="left", padx=(0, 2))

                # Color swatch (canvas-drawn for crisp visible square)
                swatch = tk.Canvas(row, width=16, height=16, bg=_UI_CARD_BG,
                                   highlightthickness=0, bd=0)
                swatch_id = swatch.create_rectangle(1, 1, 15, 15, fill=color_hex,
                                                    outline="#555555", width=1)
                swatch.pack(side="left", padx=(0, 6))

                # # Number badge
                num_lbl = tk.Label(row, text=f"#{obj_idx + 1}",
                                  font=("Segoe UI", 8, "bold"),
                                  bg=_UI_CARD_BG, fg=_UI_FG_DIM, width=3, anchor="e")
                num_lbl.pack(side="left", padx=(0, 3))

                # Keyword label — mesh parts show Part ID
                if obj.get("shape") == "mesh":
                    mesh_pid = obj.get("mesh_pid", "?")
                    kw_lbl = tk.Label(row, text=f"Part {mesh_pid}",
                                     font=("Consolas", 9),
                                     bg=_UI_CARD_BG, fg="#22c55e", anchor="w")
                else:
                    kw_str = obj.get("keyword", "?")
                    kw_short = kw_str.lstrip("*")
                    kw_lbl = tk.Label(row, text=kw_short, font=("Consolas", 9),
                                     bg=_UI_CARD_BG, fg=_UI_ACCENT, anchor="w")
                kw_lbl.pack(side="left")

                # ID badge
                oid = obj.get("id")
                if oid:
                    id_lbl = tk.Label(row, text=f"ID:{oid}", font=("Segoe UI", 8),
                                     bg=_UI_CARD_BG, fg=_UI_FG_DIM, padx=4)
                    id_lbl.pack(side="right")

                # Hover effect helpers
                def _on_enter(e, r=row, bg=_UI_CARD_BG, hover=_UI_CARD_HOVER):
                    if r.winfo_exists():
                        try:
                            r.configure(bg=hover)
                            for c in r.winfo_children():
                                try:
                                    cur = c.cget("bg")
                                    if cur == bg:
                                        c.configure(bg=hover)
                                except Exception:
                                    pass
                        except Exception:
                            pass

                def _on_leave(e, r=row, bg=_UI_CARD_BG):
                    if r.winfo_exists():
                        try:
                            r.configure(bg=bg)
                            for c in r.winfo_children():
                                try:
                                    cur = c.cget("bg")
                                    if cur == _UI_CARD_HOVER:
                                        c.configure(bg=bg)
                                except Exception:
                                    pass
                        except Exception:
                            pass

                # Bindings
                swatch.bind("<Button-1>", lambda e, idx=obj_idx: on_color_click(idx))
                for w in (row, tree_lbl, kw_lbl, num_lbl):
                    w.bind("<Enter>", _on_enter)
                    w.bind("<Leave>", _on_leave)
                    w.bind("<Button-1>", lambda e, idx=obj_idx: on_row_click(idx))

                state.panel_rows.append({
                    "frame": row,
                    "swatch": swatch,
                    "swatch_id": swatch_id,
                    "var": var,
                    "kw_lbl": kw_lbl,
                    "num_lbl": num_lbl,
                    "base_bg": _UI_CARD_BG,
                    "obj_idx": obj_idx,
                })

    _log(f"[populate_panel] done — {len(state.objects)} objects, {len(state.panel_rows)} rows")
    state._refresh_panel()

    if hasattr(state, "_total_label") and state._total_label:
        state._total_label.configure(text=f"Total: {len(state.objects)} objects")

    # Force scroll region update after tree rebuild
    if hasattr(state, "_tree_canvas") and state._tree_canvas:
        state._list_frame.update_idletasks()
        state._tree_canvas.configure(scrollregion=state._tree_canvas.bbox("all"))


# ═══════════════════════════════════════════════════════════════
#  Icon Library — canvas-drawn geometric icons (24×24 logical)
# ═══════════════════════════════════════════════════════════════

def _icon_dock(c, color, fill=None, sz=24):
    """Two overlapping rectangles — dock/undock symbol."""
    m = 3; g = 4
    # Back panel
    c.create_rectangle(m, m, sz-m, sz-m-g, outline=color, width=1.8, fill=fill or '')
    # Front panel
    c.create_rectangle(m+g, m+g, sz-m+g, sz-m+g, outline=color, width=1.8,
                       fill=_UI_CARD_BG if not fill else fill)

def _icon_eye(c, color, fill=None, sz=24):
    """Eye — show all."""
    import math
    cx, cy = sz/2, sz/2
    r = sz/2 - 3
    pts = []
    n = 24
    for i in range(n):
        angle = math.pi * i / (n - 1)
        x = cx + r * math.cos(angle)
        y = cy - r * 0.55 * math.sin(angle)
        pts.extend([x, y])
    if fill:
        c.create_polygon(pts, fill=fill, outline=color, width=1.5, smooth=True)
    else:
        c.create_line(pts, fill=color, width=1.8, capstyle="round", smooth=True)
    # Pupil
    c.create_oval(cx-3, cy-2, cx+3, cy+2, outline=color, width=1.5,
                  fill=color if fill else '')

def _icon_eye_off(c, color, fill=None, sz=24):
    """Eye with slash — hide all."""
    _icon_eye(c, _UI_FG_DIM, fill=None, sz=sz)
    # Slash
    c.create_line(4, 18, 19, 5, fill="#ef4444", width=2.0, capstyle="round")

def _icon_box_hide(c, color, fill=None, sz=24):
    """Box with slash — hide selected."""
    m = 4
    c.create_rectangle(m, m, sz-m, sz-m, outline=color, width=1.8, fill=fill or '')
    c.create_line(m, m, sz-m, sz-m, fill=color if not fill else _UI_BG, width=1.8, capstyle="round")

def _icon_box_show(c, color, fill=None, sz=24):
    """Box with sparkle — show/isolate selected."""
    m = 4
    c.create_rectangle(m, m, sz-m, sz-m, outline=color, width=1.8)
    # Fill the top-left quadrant lightly
    c.create_rectangle(m+1, m+1, sz/2, sz/2, fill=fill or color, outline='',
                       stipple='gray25' if not fill else '')
    # Sparkle dot
    cr = sz/2 + 1
    c.create_oval(cr-2, cr-2, cr+2, cr+2, fill=color, outline='')

def _icon_crosshair(c, color, fill=None, sz=24):
    """Crosshair — pick/identify."""
    cx, cy = sz/2, sz/2; r = 5
    c.create_oval(cx-r, cy-r, cx+r, cy+r, outline=color, width=1.5)
    # Cross lines
    c.create_line(cx, 4, cx, cy-r-1, fill=color, width=1.5, capstyle="round")
    c.create_line(cx, cy+r+1, cx, sz-4, fill=color, width=1.5, capstyle="round")
    c.create_line(4, cy, cx-r-1, cy, fill=color, width=1.5, capstyle="round")
    c.create_line(cx+r+1, cy, sz-4, cy, fill=color, width=1.5, capstyle="round")

def _icon_cube_wire(c, color, fill=None, sz=24):
    """3D wireframe cube."""
    m = 4; d = 5
    # Front face
    c.create_rectangle(m, m+d, sz-m-d, sz-m, outline=color, width=1.5)
    # Back face (offset up-left)
    c.create_rectangle(m+d, m, sz-m, sz-m-d, outline=color, width=1.5)
    # Connecting edges
    c.create_line(m, m+d, m+d, m, fill=color, width=1.5)
    c.create_line(sz-m-d, m+d, sz-m, m, fill=color, width=1.5)
    c.create_line(m, sz-m, m+d, sz-m-d, fill=color, width=1.5)
    c.create_line(sz-m-d, sz-m, sz-m, sz-m-d, fill=color, width=1.5)

def _icon_cube_solid(c, color, fill=None, sz=24):
    """Filled/shaded 3D cube."""
    m = 4; d = 5
    # Top face (brightest)
    c.create_polygon(m+d, m, sz-m, m, sz-m, m+d, m, m+d,
                     fill=fill or color, outline=color, width=1.2)
    # Front face (medium)
    c.create_rectangle(m, m+d, sz-m-d, sz-m,
                       fill=_UI_CARD_BG if not fill else _lighten(fill, 0.7),
                       outline=color, width=1.2)
    # Right face (darkest)
    c.create_polygon(sz-m-d, m+d, sz-m, m+d, sz-m, sz-m,
                     sz-m-d, sz-m,
                     fill=_UI_BG if not fill else _darken(fill, 0.6),
                     outline=color, width=1.2)

def _icon_cube_both(c, color, fill=None, sz=24):
    """Wireframe + solid hybrid."""
    m = 4; d = 5
    # Filled top
    c.create_polygon(m+d, m, sz-m, m, sz-m, m+d, m, m+d,
                     fill=fill or color, outline=color, width=1.5)
    # Wire front + right (not filled)
    c.create_rectangle(m, m+d, sz-m-d, sz-m, outline=color, width=1.5)
    c.create_polygon(sz-m-d, m+d, sz-m, m+d, sz-m, sz-m, sz-m-d, sz-m,
                     outline=color, width=1.5, fill='')
    # Edges
    c.create_line(m, sz-m, m+d, sz-m-d, fill=color, width=1.5)
    c.create_line(sz-m-d, sz-m, sz-m, sz-m-d, fill=color, width=1.5)

def _icon_measure(c, color, fill=None, sz=24):
    """Ruler — measurement tool."""
    m = 3; cx = sz/2
    # Horizontal bar
    c.create_line(m, sz-5, sz-m, sz-5, fill=color, width=2.5, capstyle="round")
    # Vertical ticks
    for i, h in enumerate([4, 6, 4, 6, 4]):
        x = m + 3 + i * 4
        c.create_line(x, sz-5-h, x, sz-5, fill=color, width=1.2, capstyle="round")
    # Arrow heads
    c.create_line(m, sz-5, m+3, sz-8, fill=color, width=1.5, capstyle="round")
    c.create_line(sz-m, sz-5, sz-m-3, sz-8, fill=color, width=1.5, capstyle="round")

def _icon_section(c, color, fill=None, sz=24):
    """Cube with cutting plane — section cut."""
    m = 4; d = 4
    # Wireframe cube (dim)
    c.create_rectangle(m, m+d, sz-m-d, sz-m, outline=_UI_FG_DIM, width=1.0)
    c.create_rectangle(m+d, m, sz-m, sz-m-d, outline=_UI_FG_DIM, width=1.0)
    c.create_line(m, m+d, m+d, m, fill=_UI_FG_DIM, width=1.0)
    c.create_line(sz-m-d, m+d, sz-m, m, fill=_UI_FG_DIM, width=1.0)
    c.create_line(m, sz-m, m+d, sz-m-d, fill=_UI_FG_DIM, width=1.0)
    c.create_line(sz-m-d, sz-m, sz-m, sz-m-d, fill=_UI_FG_DIM, width=1.0)
    # Cutting plane (accent)
    c.create_line(m+2, sz-3, sz-5, m+2, fill=color, width=2.0, capstyle="round")
    c.create_line(sz-7, m+2, sz-5, m, fill=color, width=1.5, capstyle="round")
    c.create_line(sz-7, m+2, sz-5, m+4, fill=color, width=1.5, capstyle="round")

def _icon_transform(c, color, fill=None, sz=24):
    """3-axis arrows — coordinate transform."""
    cx, cy = sz/2, sz/2; r = 3
    c.create_oval(cx-r, cy-r, cx+r, cy+r, fill=color, outline=color)
    # X axis (right)
    c.create_line(cx+r, cy, sz-3, cy, fill=color, width=1.8, capstyle="round", arrow="last")
    # Y axis (up)
    c.create_line(cx, cy-r, cx, 3, fill=color, width=1.8, capstyle="round", arrow="last")
    # Z axis (diagonal down-left)
    c.create_line(cx-r, cy+r, 4, sz-3, fill=color, width=1.8, capstyle="round", arrow="last")

def _icon_play(c, color, fill=None, sz=24):
    """Play triangle — animation."""
    m = 5
    c.create_polygon(m, m, sz-m, sz/2, m, sz-m,
                     fill=fill or color, outline=color, width=1.5, smooth=True)

def _icon_export(c, color, fill=None, sz=24):
    """Down-arrow into tray — export."""
    cx = sz/2; m = 3
    # Tray
    c.create_rectangle(m, sz-6, sz-m, sz-m, outline=color, width=1.5, fill=fill or '')
    # Arrow shaft
    c.create_line(cx, m+2, cx, sz-8, fill=color, width=1.8, capstyle="round")
    # Arrow head
    c.create_line(cx-5, sz-10, cx, sz-4, fill=color, width=1.8, capstyle="round")
    c.create_line(cx+5, sz-10, cx, sz-4, fill=color, width=1.8, capstyle="round")

def _icon_settings(c, color, fill=None, sz=24):
    """Gear — settings."""
    import math
    cx, cy = sz/2, sz/2
    ro, ri = 7.5, 3.5; teeth = 8
    pts = []
    for i in range(teeth * 2):
        angle = i * math.pi / teeth - math.pi / 2
        r = ro if i % 2 == 0 else ri
        pts.extend([cx + r * math.cos(angle), cy + r * math.sin(angle)])
    c.create_polygon(pts, outline=color, width=1.5, fill=fill or '', smooth=True)
    c.create_oval(cx-2, cy-2, cx+2, cy+2, fill=color, outline='')

def _icon_info(c, color, fill=None, sz=24):
    """Info circle with 'i'."""
    cx, cy = sz/2, sz/2; r = 7
    c.create_oval(cx-r, cy-r, cx+r, cy+r, outline=color, width=1.5)
    c.create_text(cx, cy, text='i', fill=color, font=('Segoe UI', 10, 'bold'))

# ── Color helpers for icons ──
def _lighten(hex_color, factor=0.8):
    """Lighten a hex color by blending with white."""
    r = int(hex_color[1:3], 16); g = int(hex_color[3:5], 16); b = int(hex_color[5:7], 16)
    r = int(r + (255 - r) * factor); g = int(g + (255 - g) * factor); b = int(b + (255 - b) * factor)
    return f'#{r:02x}{g:02x}{b:02x}'

def _darken(hex_color, factor=0.6):
    """Darken a hex color."""
    r = int(hex_color[1:3], 16); g = int(hex_color[3:5], 16); b = int(hex_color[5:7], 16)
    r = int(r * factor); g = int(g * factor); b = int(b * factor)
    return f'#{r:02x}{g:02x}{b:02x}'

# ── Icon registry ──
ICONS = {
    'dock':       _icon_dock,
    'eye':        _icon_eye,
    'eye_off':    _icon_eye_off,
    'hide':       _icon_box_hide,
    'show':       _icon_box_show,
    'crosshair':  _icon_crosshair,
    'cube_wire':  _icon_cube_wire,
    'cube_solid': _icon_cube_solid,
    'cube_both':  _icon_cube_both,
    'measure':    _icon_measure,
    'section':    _icon_section,
    'transform':  _icon_transform,
    'play':       _icon_play,
    'export':     _icon_export,
    'settings':   _icon_settings,
    'info':       _icon_info,
}

# ═══════════════════════════════════════════════════════════════
#  IconButton — canvas-based button with hover/active states
# ═══════════════════════════════════════════════════════════════

class IconButton:
    """A modern toolbar button with a canvas-drawn icon.

    Usage:
        btn = IconButton(toolbar, 'crosshair', tooltip='Pick object',
                         command=lambda: print('click'), toggle=True)
        btn.set_active(True)   # for toggle buttons
        btn.set_visible(True)  # show/hide
    """

    _tooltip_win = None  # shared tooltip window

    def __init__(self, parent, icon_name, tooltip='', command=None,
                 toggle=False, size=24, pad=6):
        self.parent = parent
        self.icon_name = icon_name
        self.tooltip = tooltip
        self.command = command
        self.toggle = toggle
        self.size = size
        self.pad = pad
        self._active = False
        self._hovered = False
        self._visible = True

        canvas_w = size + pad * 2
        canvas_h = size + pad * 2
        self.canvas = tk.Canvas(
            parent, width=canvas_w, height=canvas_h,
            bg=_UI_CARD_BG, highlightthickness=0, cursor='hand2')
        self.canvas.pack(side='left', padx=1, pady=1)
        self._draw()

        # Bindings
        self.canvas.bind('<Enter>', self._on_enter)
        self.canvas.bind('<Leave>', self._on_leave)
        self.canvas.bind('<Button-1>', self._on_click)

    def _get_colors(self):
        """Return (stroke_color, fill_color) based on current state."""
        if self._active:
            return _UI_ACCENT, _UI_ROW_SEL
        elif self._hovered:
            return _UI_FG, _UI_BTN_HOVER
        else:
            return _UI_FG_DIM, None

    def _draw(self):
        """Redraw the icon entirely."""
        self.canvas.delete('all')
        stroke, fill = self._get_colors()
        fn = ICONS.get(self.icon_name)
        if fn:
            fn(self.canvas, stroke, fill, self.size)
        if self._active:
            # Active indicator: subtle accent bottom border
            self.canvas.configure(bg=_UI_ROW_SEL,
                                  highlightbackground=_UI_ACCENT,
                                  highlightthickness=1)
        elif self._hovered:
            self.canvas.configure(bg=_UI_BTN_HOVER,
                                  highlightbackground=_UI_ACCENT_DIM,
                                  highlightthickness=1)
        else:
            self.canvas.configure(bg=_UI_CARD_BG,
                                  highlightbackground=_UI_BORDER,
                                  highlightthickness=1)

    def _on_enter(self, e):
        self._hovered = True
        self._draw()
        self._show_tooltip()

    def _on_leave(self, e):
        self._hovered = False
        self._draw()
        self._hide_tooltip()

    def _on_click(self, e):
        if self.command:
            if self.toggle:
                self.set_active(not self._active)
            self.command()

    def _show_tooltip(self):
        if not self.tooltip:
            return
        if IconButton._tooltip_win:
            IconButton._tooltip_win.destroy()
        tw = tk.Toplevel(self.canvas)
        tw.overrideredirect(True)
        tw.attributes('-topmost', True)
        tw.configure(bg=_UI_BG)
        # Position below the button
        x = self.canvas.winfo_rootx() + self.canvas.winfo_width() // 2
        y = self.canvas.winfo_rooty() + self.canvas.winfo_height() + 2
        lbl = tk.Label(tw, text=self.tooltip, bg=_UI_CARD_BG, fg=_UI_FG,
                       font=('Segoe UI', 9), padx=8, pady=3,
                       highlightbackground=_UI_BORDER, highlightthickness=1)
        lbl.pack()
        tw.update_idletasks()
        tw.geometry(f'+{x - tw.winfo_width() // 2}+{y}')
        IconButton._tooltip_win = tw

    def _hide_tooltip(self):
        if IconButton._tooltip_win:
            IconButton._tooltip_win.destroy()
            IconButton._tooltip_win = None

    def set_active(self, active):
        """Set toggle state — redraws with active colors."""
        self._active = active
        self._draw()

    def set_visible(self, visible):
        """Show or hide the button."""
        if visible and not self._visible:
            self.canvas.pack(in_=self.parent, side='left', padx=1, pady=1)
        elif not visible and self._visible:
            self.canvas.pack_forget()
        self._visible = visible

    def configure_text(self, text):
        """Update tooltip text."""
        self.tooltip = text

# ═══════════════════════════════════════════════════════════════

def build_ui(state, render_window, on_close_callback):
    """Build the complete modern UI: panel + toolbar + VTK viewport."""
    _log("[build_ui] start")

    root = tk.Tk()
    _log("[build_ui] root created")
    root.title("Impetus Geometry Preview")
    root.configure(bg=_UI_BG)
    root.geometry("1580x920+80+40")
    root.minsize(960, 500)

    # ── Menu bar ──
    menubar = tk.Menu(root, bg=_UI_BG, fg=_UI_FG,
                      activebackground=_UI_ROW_SEL, activeforeground=_UI_FG,
                      relief="flat", bd=0)
    file_menu = tk.Menu(menubar, tearoff=0, bg=_UI_CARD_BG, fg=_UI_FG,
                        activebackground=_UI_ROW_SEL, activeforeground=_UI_FG)
    file_menu.add_command(label="Open...")
    file_menu.add_separator()
    file_menu.add_command(label="Exit", command=on_close_callback)
    menubar.add_cascade(label="File", menu=file_menu)

    view_menu = tk.Menu(menubar, tearoff=0, bg=_UI_CARD_BG, fg=_UI_FG,
                        activebackground=_UI_ROW_SEL, activeforeground=_UI_FG)

    def do_reset_camera():
        state.renderer.ResetCamera()
        state.renderer.ResetCameraClippingRange()
        state._request_render()

    def do_toggle_axes():
        om_enabled = getattr(state, "_om_enabled", True)
        state._om_enabled = not om_enabled
        if state.interactor and state.om:
            state.om.SetEnabled(not om_enabled)
            state._request_render()

    view_menu.add_command(label="Reset Camera", command=do_reset_camera)
    view_menu.add_command(label="Toggle Axes", command=do_toggle_axes)
    menubar.add_cascade(label="View", menu=view_menu)
    root.config(menu=menubar)

    # ── Left Panel ──
    panel = tk.Frame(root, bg=_UI_PANEL_BG, width=320)
    panel.pack(side="left", fill="y")
    panel.pack_propagate(False)

    # Panel header
    panel_hdr = tk.Frame(panel, bg=_UI_PANEL_BG, padx=14, pady=14)
    panel_hdr.pack(fill="x")
    tk.Label(panel_hdr, text="Scene Browser", font=("Segoe UI", 14, "bold"),
             bg=_UI_PANEL_BG, fg=_UI_FG).pack(anchor="w")
    state._total_label = tk.Label(panel_hdr, text=f"{len(state.objects)} objects",
                                   font=("Segoe UI", 9), bg=_UI_PANEL_BG, fg=_UI_FG_DIM)
    state._total_label.pack(anchor="w")

    # Separator line under header
    sep = tk.Frame(panel, bg=_UI_BORDER, height=1)
    sep.pack(fill="x", padx=12)

    # Scrollable tree
    canvas = tk.Canvas(panel, bg=_UI_PANEL_BG, highlightthickness=0, bd=0)
    scrollbar_y = tk.Scrollbar(panel, orient="vertical", command=canvas.yview)
    # Minimal scrollbar style
    try:
        scrollbar_y.configure(troughcolor=_UI_BG, bg=_UI_BORDER,
                              activebackground=_UI_ACCENT, relief="flat",
                              borderwidth=0, width=6)
    except Exception:
        pass
    list_frame = tk.Frame(canvas, bg=_UI_PANEL_BG)
    state._list_frame = list_frame
    state._tree_canvas = canvas

    def on_frame_configure(event):
        canvas.configure(scrollregion=canvas.bbox("all"))

    list_frame.bind("<Configure>", on_frame_configure)
    canvas.create_window((0, 0), window=list_frame, anchor="nw", width=296)
    canvas.configure(yscrollcommand=scrollbar_y.set)
    canvas.pack(side="left", fill="both", expand=True, padx=(10, 0))
    scrollbar_y.pack(side="right", fill="y", padx=(0, 4))

    _log("[build_ui] before populate_panel")
    populate_panel(state)
    _log("[build_ui] after populate_panel")

    # ── Bottom action bar ──
    controls = tk.Frame(panel, bg=_UI_PANEL_BG, padx=10, pady=10)
    controls.pack(fill="x", side="bottom")
    # Subtle top border
    tk.Frame(controls, bg=_UI_BORDER, height=1).pack(fill="x", pady=(0, 8))

    def _btn_style(btn, accent=False):
        btn.configure(
            bg=_UI_ACCENT if accent else _UI_BTN_BG,
            fg=_UI_BG if accent else _UI_FG,
            font=("Segoe UI", 10),
            activebackground=_UI_ACCENT_DIM if accent else _UI_BTN_HOVER,
            activeforeground=_UI_BG if accent else _UI_FG,
            relief="flat", bd=0, padx=14, pady=5, cursor="hand2")

    show_all_btn = tk.Button(controls, text="Show All",
                             command=lambda: state.set_all_visibility(True))
    _btn_style(show_all_btn)
    show_all_btn.pack(side="left", padx=(0, 6))

    hide_all_btn = tk.Button(controls, text="Hide All",
                             command=lambda: state.set_all_visibility(False))
    _btn_style(hide_all_btn, accent=True)
    hide_all_btn.pack(side="left")

    # ── Right area ──
    right_area = tk.Frame(root, bg=_UI_BG)
    right_area.pack(side="left", fill="both", expand=True)

    # ── Toolbar ──
    toolbar_container = tk.Frame(right_area, bg=_UI_BG)
    toolbar_container.pack(side="top", fill="x")

    toolbar_float_win = None
    _docked = True

    toolbar = tk.Frame(toolbar_container, bg=_UI_CARD_BG,
                       highlightbackground=_UI_BORDER, highlightthickness=1)
    toolbar.pack(side="left", padx=6, pady=4)

    # ── Dock / Float toggle ──
    def _toggle_dock():
        nonlocal _docked, toolbar_float_win
        if _docked:
            toolbar.pack_forget()
            toolbar_float_win = tk.Toplevel(root)
            toolbar_float_win.overrideredirect(True)
            toolbar_float_win.configure(bg=_UI_CARD_BG)
            toolbar_float_win.attributes("-topmost", True)
            x = root.winfo_x() + toolbar_container.winfo_x() + 20
            y = root.winfo_y() + toolbar_container.winfo_y() + 20
            toolbar_float_win.geometry(f"+{x}+{y}")

            def _start_drag(event):
                toolbar_float_win._drag_x = event.x_root
                toolbar_float_win._drag_y = event.y_root
            def _do_drag(event):
                dx = event.x_root - toolbar_float_win._drag_x
                dy = event.y_root - toolbar_float_win._drag_y
                toolbar_float_win._drag_x = event.x_root
                toolbar_float_win._drag_y = event.y_root
                toolbar_float_win.geometry(f"+{toolbar_float_win.winfo_x() + dx}+{toolbar_float_win.winfo_y() + dy}")

            drag_handle = tk.Frame(toolbar_float_win, bg=_UI_CARD_BG, height=4)
            drag_handle.pack(fill="x")
            drag_handle.bind("<Button-1>", _start_drag)
            drag_handle.bind("<B1-Motion>", _do_drag)

            toolbar.pack(in_=toolbar_float_win, padx=2, pady=(0, 2))
            _dock_btn.set_active(True)
            _docked = False
        else:
            toolbar.pack_forget()
            toolbar.pack(in_=toolbar_container, side="left", padx=6, pady=4)
            if toolbar_float_win:
                toolbar_float_win.destroy()
                toolbar_float_win = None
            _dock_btn.set_active(False)
            _docked = True

    _dock_btn = IconButton(toolbar, 'dock', tooltip='Undock toolbar', command=_toggle_dock, toggle=True)

    # Separator helper
    def _tool_sep(parent):
        tk.Frame(parent, bg=_UI_BORDER, width=1).pack(side="left", fill="y", padx=4, pady=5)

    _tool_sep(toolbar)

    # ── Visibility group ──
    def _toolbar_show_all():
        state.set_all_visibility(True)

    IconButton(toolbar, 'eye', tooltip='Show all objects', command=_toolbar_show_all)

    def _toolbar_hide_all():
        state.set_all_visibility(False)

    IconButton(toolbar, 'eye_off', tooltip='Hide all objects', command=_toolbar_hide_all)

    _tool_sep(toolbar)

    # ── Selection tools ──
    _tb_hide_btn = None
    def _toolbar_toggle_hide_select():
        if state.selection_mode == "hide_select":
            state._exit_select_mode()
        else:
            state._exit_select_mode()
            state.selection_mode = "hide_select"
            if _tb_hide_btn: _tb_hide_btn.set_active(True)

    _tb_hide_btn = IconButton(toolbar, 'hide', tooltip='Hide-click to conceal | drag=box | Esc to exit',
                              command=_toolbar_toggle_hide_select, toggle=True)
    state._tb_hide_btn = _tb_hide_btn

    _tb_show_btn = None
    def _toolbar_toggle_show_select():
        if state.selection_mode == "show_select":
            state._exit_select_mode()
        else:
            state._exit_select_mode()
            state.selection_mode = "show_select"
            state._show_select_mask = [False] * len(state.objects)
            if _tb_show_btn: _tb_show_btn.set_active(True)

    _tb_show_btn = IconButton(toolbar, 'show', tooltip='Show-select to isolate | drag=box | Esc to apply',
                              command=_toolbar_toggle_show_select, toggle=True)
    state._tb_show_btn = _tb_show_btn

    _tb_identify_btn = None
    def _toolbar_toggle_identify():
        if state.selection_mode == "identify":
            state._exit_select_mode()
        else:
            state._exit_select_mode()
            state.selection_mode = "identify"
            if _tb_identify_btn: _tb_identify_btn.set_active(True)

    _tb_identify_btn = IconButton(toolbar, 'crosshair', tooltip='Identify: click object to show ID | Esc to exit',
                                  command=_toolbar_toggle_identify, toggle=True)
    state._tb_identify_btn = _tb_identify_btn

    _tool_sep(toolbar)

    # ── Display mode group ──
    _tb_mode_f = None
    _tb_mode_s = None
    _tb_mode_sf = None

    def _toolbar_mode_framework():
        state.set_display_mode("framework")
        _tb_mode_f.set_active(True)
        _tb_mode_s.set_active(False)
        _tb_mode_sf.set_active(False)

    def _toolbar_mode_shadow():
        state.set_display_mode("shadow")
        _tb_mode_f.set_active(False)
        _tb_mode_s.set_active(True)
        _tb_mode_sf.set_active(False)

    def _toolbar_mode_shadow_framework():
        state.set_display_mode("shadow_framework")
        _tb_mode_f.set_active(False)
        _tb_mode_s.set_active(False)
        _tb_mode_sf.set_active(True)

    _tb_mode_f = IconButton(toolbar, 'cube_wire', tooltip='Wireframe only',
                            command=_toolbar_mode_framework, toggle=True)
    _tb_mode_s = IconButton(toolbar, 'cube_solid', tooltip='Solid surface',
                            command=_toolbar_mode_shadow, toggle=True)
    _tb_mode_sf = IconButton(toolbar, 'cube_both', tooltip='Solid + Wireframe',
                             command=_toolbar_mode_shadow_framework, toggle=True)
    _tb_mode_s.set_active(True)  # default: solid mode

    # ── VTK viewport ──
    vtk_frame = tk.Frame(right_area, bg="#05080d",
                         highlightbackground=_UI_BORDER, highlightthickness=1)
    vtk_frame.pack(side="top", fill="both", expand=True, padx=2, pady=2)

    root.update_idletasks()
    root.update()

    # Reparent VTK native window into the tkinter frame
    _log("[build_ui] before reparent")
    _reparent_vtk_into_frame(render_window, vtk_frame)
    _log("[build_ui] after reparent")

    root.protocol("WM_DELETE_WINDOW", on_close_callback)
    # Also bind <Destroy> as a fallback in case WM_DELETE_WINDOW is not triggered
    root.bind("<Destroy>", lambda e: on_close_callback() if e.widget is root else None)
    state.tk_root = root
    return root


def build_scene(renderer, state, payload):
    objects = payload.get("objects")
    if not objects:
        objects = [payload]

    # Remove old geometry actors
    for obj in state.objects:
        for key in ("actor", "edge_actor", "grid_actor", "inner_actor", "label_actor"):
            a = obj.get(key)
            if a:
                renderer.RemoveActor(a)
    # Remove old mesh actors
    for ma in state.mesh_actors:
        if ma.get("surface"):
            renderer.RemoveActor(ma["surface"])
        if ma.get("edge"):
            renderer.RemoveActor(ma["edge"])
    state.mesh_actors.clear()

    state.objects.clear()
    state.panel_rows.clear()
    state.selected_idx = -1

    all_verts = []
    viewer_objects = []

    # ── Handle mesh-type payload ──
    for obj_idx, obj in enumerate(objects):
        if obj.get("type") == "mesh":
            _log("[build_scene] processing mesh payload")
            mesh_actors, part_colors, nel = build_mesh_surface(obj)
            if mesh_actors:
                for ma in mesh_actors:
                    if ma.get("surface"):
                        renderer.AddActor(ma["surface"])
                    if ma.get("edge"):
                        renderer.AddActor(ma["edge"])
                state.mesh_actors = mesh_actors
                # Add node positions for camera bounding box
                nodes = obj.get("nodes") or {}
                for xyz in nodes.values():
                    all_verts.append([float(xyz[0]), float(xyz[1]), float(xyz[2])])
                # Register mesh parts as tree objects
                for ma in mesh_actors:
                    pid = ma.get("pid", "?")
                    color = ma.get("color", DEFAULT_COLORS[0])
                    viewer_objects.append({
                        "actor": ma.get("surface"),
                        "edge_actor": ma.get("edge"),
                        "grid_actor": None,
                        "inner_actor": None,
                        "label_actor": None,
                        "keyword": f"MESH_PART",
                        "shape": "mesh",
                        "color_idx": 0,
                        "color": color,
                        "opacity": 0.4,
                        "visible": True,
                        "id": pid,
                        "mesh_pid": pid,
                    })
            _log(f"[build_scene] mesh done: {nel} elements in {len(mesh_actors)} parts")
            continue

        # ── Handle geometry-type payload ──
        shape = (obj.get("shape") or "").lower()

    for obj_idx, obj in enumerate(objects):
        if obj.get("type") == "mesh":
            continue
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
            viewer_objects.append({
                "actor": surface_actor,
                "edge_actor": edge_actor,
                "grid_actor": grid_actor,
                "label_actor": None,
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
            label_actor = None  # labels disabled by default; use Identify tool instead
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
            label_actor = None  # labels disabled by default; use Identify tool instead
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


def show_window():
    _log("[show_window] start")
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

    axes = build_axes_actor()
    om = vtk.vtkOrientationMarkerWidget()
    om.SetOrientationMarker(axes)
    om.SetInteractor(interactor)
    om.SetViewport(0.0, 0.0, 0.18, 0.18)
    om.SetEnabled(True)
    om.InteractiveOff()

    state = ViewerState([], renderer, interactor, om=om)

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
        state._should_exit = True
        interactor.SetDone(True)
        try:
            render_window.Finalize()
        except Exception:
            pass
        try:
            if state.tk_root and state.tk_root.winfo_exists():
                state.tk_root.destroy()
        except Exception:
            pass
        try:
            _DEBUG_LOG.close()
        except Exception:
            pass
        # Force exit immediately to prevent VTK's event loop from hanging on Windows
        import os
        os._exit(0)

    interactor.Initialize()
    render_window.Render()
    # Use a unique VTK window title so FindWindowW won't match the tkinter root
    vtk_win_title = win_title + " [render]"
    render_window.SetWindowName(vtk_win_title)

    tk_root = build_ui(state, render_window, close_all)

    def _activate_hide_select():
        if state.selection_mode == "camera":
            state.selection_mode = "hide_select"
            if hasattr(state, '_tb_hide_btn') and state._tb_hide_btn:
                state._tb_hide_btn.set_active(True)

    def _activate_show_select():
        if state.selection_mode == "camera":
            state.selection_mode = "show_select"
            state._show_select_mask = [False] * len(state.objects)
            if hasattr(state, '_tb_show_btn') and state._tb_show_btn:
                state._tb_show_btn.set_active(True)

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
            try:
                _DEBUG_LOG.close()
            except Exception:
                pass
            import os
            os._exit(0)

    def _exit_select_mode():
        mode = state.selection_mode
        state.selection_mode = "camera"
        state._is_dragging = False
        if state._hover_idx >= 0:
            state._set_hover(state._hover_idx, False)
            state._hover_idx = -1
        _clear_box_highlight()
        state._press_picked_idx = -1
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
        for attr in ('_tb_hide_btn', '_tb_show_btn', '_tb_identify_btn'):
            btn = getattr(state, attr, None)
            if btn is not None:
                btn.set_active(False)
        state._refresh_panel()
        state._request_render()

    state._exit_select_mode = _exit_select_mode

    def _pick_object_idx(pos):
        picker = vtk.vtkPropPicker()
        picker.Pick(int(pos[0]), int(pos[1]), 0, renderer)
        picked = picker.GetActor()
        if picked:
            for i, obj_data in enumerate(state.objects):
                if obj_data.get("actor") == picked or obj_data.get("inner_actor") == picked:
                    return i
        return -1

    def _set_rotation_center_at_click(interactor, renderer):
        pos = interactor.GetEventPosition()
        picker = vtk.vtkCellPicker()
        picker.Pick(pos[0], pos[1], 0, renderer)
        if picker.GetActor():
            pick_point = picker.GetPickPosition()
            camera = renderer.GetActiveCamera()
            old_fp = camera.GetFocalPoint()
            old_pos = camera.GetPosition()
            dx = old_fp[0] - old_pos[0]
            dy = old_fp[1] - old_pos[1]
            dz = old_fp[2] - old_pos[2]
            dist = math.sqrt(dx*dx + dy*dy + dz*dz)
            if dist > 1e-9:
                camera.SetFocalPoint(pick_point)
                camera.SetPosition(
                    pick_point[0] - dx / dist * dist,
                    pick_point[1] - dy / dist * dist,
                    pick_point[2] - dz / dist * dist,
                )
            # Show a red sphere marker at the rotation center
            if state._rotate_marker_actor is None:
                sphere = vtk.vtkSphereSource()
                sphere.SetPhiResolution(16)
                sphere.SetThetaResolution(16)
                mapper = vtk.vtkPolyDataMapper()
                mapper.SetInputConnection(sphere.GetOutputPort())
                actor = vtk.vtkActor()
                actor.SetMapper(mapper)
                actor.GetProperty().SetColor(1.0, 0.0, 0.0)
                actor.GetProperty().SetOpacity(0.8)
                actor.PickableOff()
                renderer.AddActor(actor)
                state._rotate_marker_actor = actor
            # Compute radius so the marker always appears ~6 px on screen
            camera = renderer.GetActiveCamera()
            size = renderer.GetRenderWindow().GetSize()
            pixel_radius = 6.0
            if camera.GetParallelProjection():
                world_radius = pixel_radius * 2.0 * camera.GetParallelScale() / size[1]
            else:
                fov = camera.GetViewAngle()
                world_radius = dist * pixel_radius * math.radians(fov) / size[1]
            world_radius = max(world_radius, 0.1)
            state._rotate_marker_actor.SetPosition(pick_point)
            state._rotate_marker_actor.SetScale(world_radius, world_radius, world_radius)
            state._rotate_marker_actor.SetVisibility(1)
            state._request_render()

    def _update_box_highlight():
        x1, x2 = sorted([state._drag_start[0], state._drag_current[0]])
        y1, y2 = sorted([state._drag_start[1], state._drag_current[1]])
        new_set = set()
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
                new_set.add(i)
        for i in (state._box_highlight_indices - new_set):
            state._set_highlight(i, False)
        for i in (new_set - state._box_highlight_indices):
            state._set_highlight(i, True)
        state._box_highlight_indices = new_set

    def _clear_box_highlight():
        for i in list(state._box_highlight_indices):
            state._set_highlight(i, False)
        state._box_highlight_indices.clear()

    def _do_rotate(renderer, dx, dy, motion_factor=10.0):
        size = renderer.GetRenderWindow().GetSize()
        delta_elevation = -20.0 / size[1]
        delta_azimuth = -20.0 / size[0]
        rxf = dx * delta_azimuth * motion_factor
        ryf = dy * delta_elevation * motion_factor
        camera = renderer.GetActiveCamera()
        camera.Azimuth(rxf)
        camera.Elevation(ryf)
        camera.OrthogonalizeViewUp()
        renderer.ResetCameraClippingRange()

    def _do_pan(renderer, dx, dy):
        camera = renderer.GetActiveCamera()
        fp = list(camera.GetFocalPoint())
        pos = list(camera.GetPosition())
        view_up = camera.GetViewUp()
        dop = camera.GetDirectionOfProjection()
        # view_right = dop × view_up
        view_right = [
            dop[1] * view_up[2] - dop[2] * view_up[1],
            dop[2] * view_up[0] - dop[0] * view_up[2],
            dop[0] * view_up[1] - dop[1] * view_up[0],
        ]
        import math
        len_r = math.sqrt(sum(v * v for v in view_right))
        if len_r > 1e-9:
            view_right = [v / len_r for v in view_right]
        size = renderer.GetRenderWindow().GetSize()
        parallel_scale = camera.GetParallelScale()
        world_per_pixel = 2.0 * parallel_scale / size[1]
        mx = -dx * world_per_pixel
        my = -dy * world_per_pixel
        for i in range(3):
            delta = mx * view_right[i] + my * view_up[i]
            fp[i] += delta
            pos[i] += delta
        camera.SetFocalPoint(fp[0], fp[1], fp[2])
        camera.SetPosition(pos[0], pos[1], pos[2])

    def _do_zoom(renderer, dy, motion_factor=10.0):
        center = renderer.GetCenter()
        dyf = motion_factor * dy / center[1]
        factor = pow(1.1, dyf)
        camera = renderer.GetActiveCamera()
        if camera.GetParallelProjection():
            camera.SetParallelScale(camera.GetParallelScale() / factor)
        else:
            camera.Dolly(factor)
            renderer.ResetCameraClippingRange()

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
        ctrl = obj.GetControlKey()
        if ctrl:
            _set_rotation_center_at_click(obj, renderer)
            state._camera_mode = "rotate"
            state._camera_last_pos = obj.GetEventPosition()
            return
        if state.selection_mode in ("hide_select", "show_select", "identify"):
            if state._box_highlight_indices:
                _clear_box_highlight()
                state._refresh_panel()
                state._request_render()
            pos = obj.GetEventPosition()
            state._drag_start = (int(pos[0]), int(pos[1]))
            state._drag_current = state._drag_start
            state._select_button_down = True
            state._select_has_dragged = False
            state._select_rotation_started = False
            if state.selection_mode in ("hide_select", "show_select"):
                state._press_picked_idx = _pick_object_idx(pos)
                _update_hover(pos)
                state._is_dragging = True
            elif state.selection_mode == "identify":
                state._is_dragging = False
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
        if state._camera_mode == "rotate":
            pos = obj.GetEventPosition()
            last_pos = state._camera_last_pos
            _do_rotate(renderer, pos[0] - last_pos[0], pos[1] - last_pos[1])
            state._camera_last_pos = pos
            obj.Render()
            return
        elif state._camera_mode == "pan":
            pos = obj.GetEventPosition()
            last_pos = state._camera_last_pos
            _do_pan(renderer, pos[0] - last_pos[0], pos[1] - last_pos[1])
            state._camera_last_pos = pos
            obj.Render()
            return
        elif state._camera_mode == "zoom":
            pos = obj.GetEventPosition()
            last_pos = state._camera_last_pos
            _do_zoom(renderer, pos[1] - last_pos[1])
            state._camera_last_pos = pos
            obj.Render()
            return
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
        # Box-drag select (hide_select/show_select only)
        if state._is_dragging and state._select_has_dragged:
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
            if state.selection_mode in ("hide_select", "show_select"):
                _update_box_highlight()
            state._request_render()
            return
        # Not dragging yet => hover preview
        if state.selection_mode in ("hide_select", "show_select"):
            _update_hover(pos)

    def on_left_button_release(obj, event):
        if state._camera_mode is not None:
            state._camera_mode = None
            state._camera_last_pos = None
            if state._rotate_marker_actor:
                state._rotate_marker_actor.SetVisibility(0)
                state._request_render()
            return
        if state.selection_mode not in ("hide_select", "show_select", "identify"):
            return
        state._select_button_down = False
        if state._select_has_dragged:
            if state._is_dragging:
                state._is_dragging = False
                for actor in state._rubberband_actors:
                    actor.SetVisibility(0)
                # Keep box highlight for middle-click confirmation; only hide rubberband
                state._refresh_panel()
                state._request_render()
                return
            state._select_has_dragged = False
            state._select_rotation_started = False
            return
        # Simple click (no drag)
        if state.selection_mode in ("hide_select", "show_select"):
            if state._hover_idx >= 0:
                state._set_hover(state._hover_idx, False)
                state._hover_idx = -1
            found_idx = state._press_picked_idx
            state._press_picked_idx = -1
            if found_idx >= 0:
                if state.selection_mode == "hide_select":
                    state.set_visibility(found_idx, False)
                else:  # show_select
                    _mark_show_selected(found_idx)
            state._refresh_panel()
            state._request_render()
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
                actor = obj_data.get("actor")
                if actor:
                    b = actor.GetBounds()
                    cx = (b[0] + b[1]) / 2.0
                    cy = (b[2] + b[3]) / 2.0
                    cz = (b[4] + b[5]) / 2.0
                    state._identify_actor.SetPosition(cx, cy, cz)
                state._identify_actor.SetInput(label_text)
                state._identify_actor.SetVisibility(1)
                state.select_object(found_idx)
                state._identify_idx = found_idx
            else:
                if state._identify_actor:
                    state._identify_actor.SetVisibility(0)
                if state.selected_idx >= 0:
                    state._set_highlight(state.selected_idx, False)
                    state.selected_idx = -1
                    state._refresh_panel()
                state._identify_idx = -1
            state._request_render()

    def on_middle_button_press(obj, event):
        if obj.GetControlKey():
            state._camera_mode = "pan"
            state._camera_last_pos = obj.GetEventPosition()
            return
        if state.selection_mode in ("hide_select", "show_select", "identify"):
            if state._box_highlight_indices:
                if state.selection_mode == "hide_select":
                    for i in list(state._box_highlight_indices):
                        state.set_visibility(i, False)
                else:  # show_select
                    x1, x2 = sorted([state._drag_start[0], state._drag_current[0]])
                    y1, y2 = sorted([state._drag_start[1], state._drag_current[1]])
                    _mark_show_selected_box(x1, y1, x2, y2)
                _clear_box_highlight()
                state._refresh_panel()
                state._request_render()
                return
            _exit_select_mode()

    def on_middle_button_release(obj, event):
        if state._camera_mode == "pan":
            state._camera_mode = None
            state._camera_last_pos = None

    def on_right_button_press(obj, event):
        if obj.GetControlKey():
            state._camera_mode = "zoom"
            state._camera_last_pos = obj.GetEventPosition()
            return
        if state.selection_mode in ("hide_select", "show_select", "identify"):
            _exit_select_mode()

    def on_right_button_release(obj, event):
        if state._camera_mode == "zoom":
            state._camera_mode = None
            state._camera_last_pos = None

    def on_mouse_wheel(obj, event):
        if not obj.GetControlKey():
            return
        factor = 1.2 if event == "MouseWheelForwardEvent" else 0.8
        camera = renderer.GetActiveCamera()
        if camera.GetParallelProjection():
            camera.SetParallelScale(camera.GetParallelScale() / factor)
        else:
            camera.Dolly(factor)
            renderer.ResetCameraClippingRange()
        obj.Render()

    interactor.AddObserver("KeyPressEvent", on_keypress)
    interactor.AddObserver("LeftButtonPressEvent", on_left_button_press)
    interactor.AddObserver("MouseMoveEvent", on_mouse_move)
    interactor.AddObserver("LeftButtonReleaseEvent", on_left_button_release)
    interactor.AddObserver("MiddleButtonPressEvent", on_middle_button_press)
    interactor.AddObserver("MiddleButtonReleaseEvent", on_middle_button_release)
    interactor.AddObserver("RightButtonPressEvent", on_right_button_press)
    interactor.AddObserver("RightButtonReleaseEvent", on_right_button_release)
    interactor.AddObserver("MouseWheelForwardEvent", on_mouse_wheel)
    interactor.AddObserver("MouseWheelBackwardEvent", on_mouse_wheel)

    # Use an empty style so we handle all camera motion manually
    style = vtk.vtkInteractorStyle()
    interactor.SetInteractorStyle(style)
    state._style = style

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

    # Background thread reads stdin and puts commands into a queue
    cmd_queue = queue.Queue()

    def _stdin_reader():
        _log("[stdin_reader] started")
        while True:
            try:
                line = sys.stdin.readline()
                _log("[stdin_reader] read line: " + repr(line))
                if not line:
                    break
                cmd = json.loads(line.strip())
                _log("[stdin_reader] parsed cmd: " + str(cmd.get("cmd")))
                cmd_queue.put(cmd)
            except Exception as exc:
                _log("[stdin_reader] error: " + str(exc))
                pass

    threading.Thread(target=_stdin_reader, daemon=True).start()

    # Stable event loop: VTK Start() owns the main thread, timer keeps tkinter alive
    def on_timer(obj, event):
        _log("[on_timer] tick")
        # Process any pending commands from stdin
        while True:
            try:
                cmd = cmd_queue.get_nowait()
                _log("[on_timer] got cmd: " + str(cmd.get("cmd")))
                if cmd.get("cmd") == "exit":
                    state._should_exit = True
                    interactor.SetDone(True)
                    try:
                        render_window.Finalize()
                    except Exception:
                        pass
                    try:
                        _DEBUG_LOG.close()
                    except Exception:
                        pass
                    import os
                    os._exit(0)
                elif cmd.get("cmd") == "load":
                    payload = cmd.get("payload")
                    _log("[on_timer] load payload has " + str(len(payload.get("objects", []))) + " objects")
                    if payload:
                        try:
                            build_scene(renderer, state, payload)
                            _log("[on_timer] build_scene done")
                        except Exception as exc:
                            _log("[on_timer] build_scene error: " + str(exc))
                            import traceback
                            _log(traceback.format_exc())
            except queue.Empty:
                break

        if state.needs_render:
            state.needs_render = False
            obj.GetRenderWindow().Render()
        if tk_root and tk_root.winfo_exists():
            try:
                tk_root.update_idletasks()
                tk_root.update()
            except tk.TclError:
                interactor.SetDone(True)
        else:
            # Window was destroyed without triggering WM_DELETE_WINDOW; force exit
            try:
                render_window.Finalize()
            except Exception:
                pass
            try:
                _DEBUG_LOG.close()
            except Exception:
                pass
            import os
            os._exit(0)

    interactor.AddObserver("TimerEvent", on_timer)
    interactor.CreateRepeatingTimer(30)
    interactor.Start()


def main():
    show_window()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        _log("[FATAL] " + str(exc))
        import traceback
        _log(traceback.format_exc())
        sys.exit(1)
