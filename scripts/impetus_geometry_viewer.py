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

_UI_BG = "#1a1d23"
_UI_ROW_BG = "#242830"
_UI_ROW_SEL = "#3a4050"
_UI_FG = "#d1d5db"
_UI_FG_DIM = "#9ca3af"
_UI_BORDER = "#4b5563"
_UI_BTN_BG = "#374151"
_UI_BTN_HOVER = "#4b5563"


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


class ViewerState:
    def __init__(self, objects, renderer, interactor, om=None):
        self.objects = objects
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
        self.display_mode = "shadow"  # "framework", "shadow", "shadow_framework"
        self._show_select_mask = []  # bool list for show-select mode
        # Selection-mode interaction state
        self._select_button_down = False
        self._select_has_dragged = False
        self._select_rotation_started = False

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
        is_wireframe_only = (shape not in ("box", "sphere", "cylinder", "pipe"))
        
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
            if edge:
                edge.SetVisibility(1 if obj.get("visible", True) else 0)
            if grid:
                grid.SetVisibility(1 if obj.get("visible", True) else 0)
            if inner:
                inner.SetVisibility(1 if obj.get("visible", True) else 0)
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
        for i, row_info in enumerate(self.panel_rows):
            if i >= len(self.objects):
                continue
            obj = self.objects[i]
            color = obj.get("color", DEFAULT_COLORS[obj.get("color_idx", i) % len(DEFAULT_COLORS)])
            row_info["swatch"].configure(bg="#%02x%02x%02x" % (int(color[0] * 255), int(color[1] * 255), int(color[2] * 255)))
            row_info["var"].set(1 if obj.get("visible", True) else 0)
            if i == self.selected_idx:
                row_info["frame"].configure(bg="#3a4050")
                for child in row_info["frame"].winfo_children():
                    if isinstance(child, tk.Frame):
                        child.configure(bg="#3a4050")
                        for c2 in child.winfo_children():
                            c2.configure(bg="#3a4050")
                    else:
                        child.configure(bg="#3a4050")
            else:
                row_info["frame"].configure(bg="#242830")
                for child in row_info["frame"].winfo_children():
                    if isinstance(child, tk.Frame):
                        child.configure(bg="#242830")
                        for c2 in child.winfo_children():
                            c2.configure(bg="#242830")
                    else:
                        child.configure(bg="#242830")


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

    # Try render_window's own window ID first, fallback to FindWindowW by title
    vtk_hwnd = None
    try:
        vtk_hwnd = render_window.GetWindowId()
    except Exception:
        pass
    if not vtk_hwnd:
        for _ in range(100):
            vtk_hwnd = user32.FindWindowW(None, win_title)
            if vtk_hwnd:
                break
            time.sleep(0.01)

    if not vtk_hwnd:
        return None

    # Reparent first, then fix styles (safer order)
    user32.SetParent(vtk_hwnd, tk_hwnd)
    style = user32.GetWindowLongW(vtk_hwnd, GWL_STYLE)
    style &= ~0x00CF0000
    style |= WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN
    user32.SetWindowLongW(vtk_hwnd, GWL_STYLE, style)
    # Refresh frame so style change takes effect
    user32.SetWindowPos(vtk_hwnd, 0, 0, 0, 0, 0,
                        0x0277)  # SWP_FRAMECHANGED|NOMOVE|NOSIZE|NOZORDER|SHOWWINDOW|NOACTIVATE|NOOWNERZORDER
    user32.RedrawWindow(vtk_hwnd, None, None, 0x0400 | 0x0001 | 0x0080)  # RDW_FRAME|INVALIDATE|ALLCHILDREN
    user32.ShowWindow(vtk_hwnd, 1)
    user32.SetFocus(tk_hwnd)

    def on_resize(event=None):
        w = vtk_frame.winfo_width()
        h = vtk_frame.winfo_height()
        if w > 0 and h > 0:
            render_window.SetPosition(0, 0)
            render_window.SetSize(w, h)
            render_window.Render()

    vtk_frame.bind("<Configure>", on_resize)
    vtk_frame.after(50, on_resize)
    return vtk_hwnd


def populate_panel(state):
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


def build_ui(state, render_window, on_close_callback):
    def rgb_to_hex(rgb):
        return "#%02x%02x%02x" % (int(rgb[0] * 255), int(rgb[1] * 255), int(rgb[2] * 255))

    def hex_to_rgb(hex_str):
        hex_str = hex_str.lstrip("#")
        return tuple(int(hex_str[i:i + 2], 16) / 255.0 for i in (0, 2, 4))

    BG = "#1a1d23"
    ROW_BG = "#242830"
    ROW_SEL = "#3a4050"
    FG = "#d1d5db"
    FG_DIM = "#9ca3af"
    BORDER = "#4b5563"
    BTN_BG = "#374151"
    BTN_HOVER = "#4b5563"

    root = tk.Tk()
    root.title("Impetus Geometry Preview")
    root.configure(bg=BG)
    root.geometry("1580x840+50+50")
    root.minsize(800, 400)

    # Menu bar
    menubar = tk.Menu(root, bg=BG, fg=FG, activebackground=ROW_SEL, activeforeground=FG)
    file_menu = tk.Menu(menubar, tearoff=0, bg=BG, fg=FG, activebackground=ROW_SEL, activeforeground=FG)
    file_menu.add_command(label="Open...")
    file_menu.add_separator()
    file_menu.add_command(label="Exit", command=on_close_callback)
    menubar.add_cascade(label="File", menu=file_menu)

    view_menu = tk.Menu(menubar, tearoff=0, bg=BG, fg=FG, activebackground=ROW_SEL, activeforeground=FG)

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

    # Left panel
    panel = tk.Frame(root, bg=BG, width=300)
    panel.pack(side="left", fill="y")
    panel.pack_propagate(False)

    header = tk.Frame(panel, bg=BG, height=40)
    header.pack(fill="x", padx=12, pady=(12, 6))
    tk.Label(header, text="Objects", font=("Segoe UI", 15, "bold"),
             bg=BG, fg="#f3f4f6").pack(anchor="w")
    state._total_label = tk.Label(header, text=f"Total: {len(state.objects)}", font=("Segoe UI", 9),
             bg=BG, fg=FG_DIM)
    state._total_label.pack(anchor="w")

    # Scrollable list
    canvas = tk.Canvas(panel, bg=BG, highlightthickness=0)
    scrollbar = tk.Scrollbar(panel, orient="vertical", command=canvas.yview)
    list_frame = tk.Frame(canvas, bg=BG)
    state._list_frame = list_frame

    def on_frame_configure(event):
        canvas.configure(scrollregion=canvas.bbox("all"))

    list_frame.bind("<Configure>", on_frame_configure)
    canvas.create_window((0, 0), window=list_frame, anchor="nw", width=280)
    canvas.configure(yscrollcommand=scrollbar.set)
    canvas.pack(side="left", fill="both", expand=True, padx=(10, 0))
    scrollbar.pack(side="right", fill="y", padx=(0, 5))

    populate_panel(state)

    # Bottom controls: Show All / Turn Off All
    controls = tk.Frame(panel, bg=BG, padx=10, pady=10)
    controls.pack(fill="x", side="bottom")

    def btn_style(btn):
        btn.configure(bg=BTN_BG, fg=FG, font=("Segoe UI", 10),
                      activebackground=BTN_HOVER, activeforeground=FG,
                      relief="flat", bd=0, padx=12, pady=4, cursor="hand2")

    show_all_btn = tk.Button(controls, text="Show All",
                             command=lambda: state.set_all_visibility(True))
    btn_style(show_all_btn)
    show_all_btn.pack(side="left", padx=(0, 6))

    hide_all_btn = tk.Button(controls, text="Turn Off All",
                             command=lambda: state.set_all_visibility(False))
    btn_style(hide_all_btn)
    hide_all_btn.pack(side="left")

    # Right area: container for toolbar + VTK view
    right_area = tk.Frame(root, bg=BG)
    right_area.pack(side="left", fill="both", expand=True)

    # ── Modern Dockable Toolbar ──
    toolbar_container = tk.Frame(right_area, bg=BG, height=0)
    toolbar_container.pack(side="top", fill="x", padx=0, pady=0)

    toolbar_float_win = None
    _docked = True

    TOOL_BG = "#252a33"
    TOOL_HOVER = "#3a4555"
    TOOL_ACTIVE = "#4a5568"
    TOOL_FG = "#e2e8f0"
    TOOL_ACCENT = "#fbbf24"

    def _make_tool_btn(parent, text, tooltip, command, active=False, font=None):
        btn = tk.Label(parent, text=text, font=(font or ("Segoe UI Emoji", 18)),
                       bg=TOOL_ACTIVE if active else TOOL_BG,
                       fg=TOOL_ACCENT if active else TOOL_FG,
                       padx=10, pady=6, cursor="hand2")
        btn.pack(side="left", padx=3, pady=3)
        btn._is_active = active

        def _on_enter(e):
            if not btn._is_active:
                btn.configure(bg=TOOL_HOVER)
        def _on_leave(e):
            if not btn._is_active:
                btn.configure(bg=TOOL_BG)
        def _on_click(e):
            command()

        btn.bind("<Enter>", _on_enter)
        btn.bind("<Leave>", _on_leave)
        btn.bind("<Button-1>", _on_click)
        return btn

    def _set_btn_active(btn, active):
        btn._is_active = active
        btn.configure(bg=TOOL_ACTIVE if active else TOOL_BG,
                      fg=TOOL_ACCENT if active else TOOL_FG)

    # The actual toolbar frame (can be reparented between dock/float)
    toolbar = tk.Frame(toolbar_container, bg=TOOL_BG,
                       highlightbackground="#4b5563",
                       highlightthickness=1, bd=0)
    toolbar.pack(side="left", padx=4, pady=4)

    # Dock / Float toggle
    def _toggle_dock():
        nonlocal _docked, toolbar_float_win
        if _docked:
            # Undock into floating window
            toolbar.pack_forget()
            toolbar_float_win = tk.Toplevel(root)
            toolbar_float_win.overrideredirect(True)
            toolbar_float_win.configure(bg=TOOL_BG)
            toolbar_float_win.attributes("-topmost", True)
            # Position near original toolbar
            x = root.winfo_x() + toolbar_container.winfo_x() + 20
            y = root.winfo_y() + toolbar_container.winfo_y() + 20
            toolbar_float_win.geometry(f"+{x}+{y}")

            # Drag support for floating window
            def _start_drag(event):
                toolbar_float_win._drag_x = event.x_root
                toolbar_float_win._drag_y = event.y_root
            def _do_drag(event):
                dx = event.x_root - toolbar_float_win._drag_x
                dy = event.y_root - toolbar_float_win._drag_y
                toolbar_float_win._drag_x = event.x_root
                toolbar_float_win._drag_y = event.y_root
                nx = toolbar_float_win.winfo_x() + dx
                ny = toolbar_float_win.winfo_y() + dy
                toolbar_float_win.geometry(f"+{nx}+{ny}")

            drag_handle = tk.Frame(toolbar_float_win, bg=TOOL_BG, height=4)
            drag_handle.pack(fill="x")
            drag_handle.bind("<Button-1>", _start_drag)
            drag_handle.bind("<B1-Motion>", _do_drag)

            toolbar.pack(in_=toolbar_float_win, padx=2, pady=(0, 2))
            _dock_btn.configure(text="📍")
            _docked = False
        else:
            # Dock back
            toolbar.pack_forget()
            toolbar.pack(in_=toolbar_container, side="left", padx=4, pady=4)
            if toolbar_float_win:
                toolbar_float_win.destroy()
                toolbar_float_win = None
            _dock_btn.configure(text="📌")
            _docked = True

    _dock_btn = _make_tool_btn(toolbar, "📌", "Dock/Float toolbar", _toggle_dock)

    # Separator
    tk.Frame(toolbar, bg="#4b5563", width=1).pack(side="left", fill="y", padx=4, pady=6)

    # Show-all button (always shows everything, no toggle-off)
    _tb_toggle_btn = None

    def _toolbar_show_all():
        state.set_all_visibility(True)

    _tb_toggle_btn = _make_tool_btn(toolbar, "ALL", "Show all objects", _toolbar_show_all, font=("Segoe UI", 11, "bold"))

    # All Off icon button
    def _toolbar_all_off():
        state.set_all_visibility(False)

    _make_tool_btn(toolbar, "OFF", "Turn off all objects", _toolbar_all_off, font=("Segoe UI", 11, "bold"))

    # Hide Select icon button (click to hide single, Alt+drag for box, middle-click/ESC=exit)
    _tb_hide_btn = None

    def _toolbar_toggle_hide_select():
        if state.selection_mode == "camera":
            state.selection_mode = "hide_select"
            _set_btn_active(_tb_hide_btn, True)
        else:
            state._exit_select_mode()

    _tb_hide_btn = _make_tool_btn(toolbar, "H.S", "Hide Select: click=hide | Alt+drag=box | middle-click/ESC=exit", _toolbar_toggle_hide_select, font=("Segoe UI", 11, "bold"))
    state._tb_hide_btn = _tb_hide_btn

    # Show Select icon button (click to select, Alt+drag for box, middle-click/ESC=apply)
    _tb_show_btn = None

    def _toolbar_toggle_show_select():
        if state.selection_mode == "camera":
            state.selection_mode = "show_select"
            state._show_select_mask = [False] * len(state.objects)
            _set_btn_active(_tb_show_btn, True)
        else:
            state._exit_select_mode()

    _tb_show_btn = _make_tool_btn(toolbar, "S.S", "Show Select: click=select | Alt+drag=box | middle-click/ESC=apply", _toolbar_toggle_show_select, font=("Segoe UI", 11, "bold"))
    state._tb_show_btn = _tb_show_btn

    # Identify icon button (click object to show its ID label)
    _tb_identify_btn = None

    def _toolbar_toggle_identify():
        if state.selection_mode == "camera":
            state.selection_mode = "identify"
            _set_btn_active(_tb_identify_btn, True)
        else:
            state._exit_select_mode()

    _tb_identify_btn = _make_tool_btn(toolbar, "i", "Identify: click object to show ID | middle-click/ESC=exit", _toolbar_toggle_identify, font=("Segoe UI", 11, "bold"))
    state._tb_identify_btn = _tb_identify_btn

    # Separator
    tk.Frame(toolbar, bg="#4b5563", width=1).pack(side="left", fill="y", padx=4, pady=6)

    # Display mode buttons
    _tb_mode_f = None
    _tb_mode_s = None
    _tb_mode_sf = None

    def _set_mode_btn(btn, active):
        btn._is_active = active
        btn.configure(bg=TOOL_ACTIVE if active else TOOL_BG,
                      fg=TOOL_ACCENT if active else TOOL_FG)

    def _toolbar_mode_framework():
        state.set_display_mode("framework")
        _set_mode_btn(_tb_mode_f, True)
        _set_mode_btn(_tb_mode_s, False)
        _set_mode_btn(_tb_mode_sf, False)

    def _toolbar_mode_shadow():
        state.set_display_mode("shadow")
        _set_mode_btn(_tb_mode_f, False)
        _set_mode_btn(_tb_mode_s, True)
        _set_mode_btn(_tb_mode_sf, False)

    def _toolbar_mode_shadow_framework():
        state.set_display_mode("shadow_framework")
        _set_mode_btn(_tb_mode_f, False)
        _set_mode_btn(_tb_mode_s, False)
        _set_mode_btn(_tb_mode_sf, True)

    _tb_mode_f = _make_tool_btn(toolbar, "F", "Framework mode (wireframe)", _toolbar_mode_framework, font=("Segoe UI", 11, "bold"))
    _tb_mode_s = _make_tool_btn(toolbar, "S", "Shadow mode (surface)", _toolbar_mode_shadow, active=True, font=("Segoe UI", 11, "bold"))
    _tb_mode_sf = _make_tool_btn(toolbar, "F+S", "Shadow + Framework mode", _toolbar_mode_shadow_framework, font=("Segoe UI", 11, "bold"))

    # VTK container (below toolbar)
    vtk_frame = tk.Frame(right_area, bg="black")
    vtk_frame.pack(side="top", fill="both", expand=True)

    root.update_idletasks()
    root.update()

    # Reparent VTK native window into the tkinter frame
    _reparent_vtk_into_frame(render_window, vtk_frame)

    root.protocol("WM_DELETE_WINDOW", on_close_callback)
    state.tk_root = root
    return root


def build_scene(renderer, state, payload):
    objects = payload.get("objects")
    if not objects:
        objects = [payload]

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


def show_window():
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
                    interactor.SetDone(True)
                    return
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

    interactor.AddObserver("TimerEvent", on_timer)
    interactor.CreateRepeatingTimer(30)
    interactor.Start()


def main():
    show_window()


if __name__ == "__main__":
    main()
