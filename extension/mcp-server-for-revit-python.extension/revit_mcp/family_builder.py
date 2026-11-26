# -*- coding: UTF-8 -*-
"""
Family Builder Module for Revit MCP
Builds family geometry from a JSON geometry spec (boxes, cylinders, hex prisms,
general profile prisms), exports oriented 3D snapshots, and measures geometry.

Routes:
    POST /family_builder/build/     build geometry from a spec
    POST /family_builder/snapshot/  oriented 3D image of a family document
    POST /family_builder/measure/   overall and per-element extents in mm
"""
from pyrevit import routes, DB
import json
import math
import os
import tempfile
import base64
import logging
import traceback
from System.Collections.Generic import List

logger = logging.getLogger(__name__)

MM = 1.0 / 304.8
MIN_SIZE_MM = 0.8  # Revit short-curve tolerance (~0.0026 ft)

AXES = {
    "x": (1, 0, 0), "-x": (-1, 0, 0),
    "y": (0, 1, 0), "-y": (0, -1, 0),
    "z": (0, 0, 1), "-z": (0, 0, -1),
}

VIEW_DIRECTIONS = {
    # forward (looking) direction; family Front = -Y
    "front": (0, 1, 0),
    "back": (0, -1, 0),
    "left": (1, 0, 0),
    "right": (-1, 0, 0),
    "top": (0, 0, -1),
    "bottom": (0, 0, 1),
    "iso": (1, 1, -0.8),            # from front-left-top
    "iso_right": (-1, 1, -0.8),     # from front-right-top
    "iso_back_left": (1, -1, -0.8),
    "iso_back_right": (-1, -1, -0.8),
}


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
def _parse(request):
    data = request.data
    if isinstance(data, str):
        data = json.loads(data) if data else {}
    return data or {}


def _pt(p):
    return DB.XYZ(float(p[0]) * MM, float(p[1]) * MM, float(p[2]) * MM)


def _axis(a):
    if isinstance(a, (list, tuple)):
        v = DB.XYZ(float(a[0]), float(a[1]), float(a[2]))
    else:
        v = DB.XYZ(*AXES[str(a).lower()])
    return v.Normalize()


def _basis(n):
    """In-plane basis (u, v) for a plane normal n.
    axis x -> u=Y, v=Z ; axis y -> u=-X, v=Z ; axis z -> u=X, v=Y"""
    if abs(n.Z) > 0.99:
        u = DB.XYZ.BasisX
    else:
        u = DB.XYZ.BasisZ.CrossProduct(n).Normalize()
    v = n.CrossProduct(u).Normalize()
    return u, v


def _find_doc(app, active_doc, title):
    if not title:
        return active_doc
    for d in app.Documents:
        if d.Title == title or d.Title.startswith(title):
            return d
    raise ValueError("Open document '{}' not found".format(title))


def _find_template(app, template):
    if template and os.path.isfile(template):
        return template
    name = (template or "Metric Generic Model")
    if not name.lower().endswith(".rft"):
        name += ".rft"
    root = app.FamilyTemplatePath
    for dp, dn, fn in os.walk(root):
        for f in fn:
            if f.lower() == name.lower():
                return os.path.join(dp, f)
    raise ValueError("Family template '{}' not found under {}".format(name, root))


def _get_material(doc, name, rgb=None):
    for m in DB.FilteredElementCollector(doc).OfClass(DB.Material):
        if m.Name == name:
            if rgb:
                m.Color = DB.Color(int(rgb[0]), int(rgb[1]), int(rgb[2]))
            return m.Id
    mid = DB.Material.Create(doc, name)
    rgb = rgb or (180, 180, 180)
    doc.GetElement(mid).Color = DB.Color(int(rgb[0]), int(rgb[1]), int(rgb[2]))
    return mid


def _circle_loop(plane, r):
    ca = DB.CurveArray()
    ca.Append(DB.Arc.Create(plane, r * MM, 0, math.pi))
    ca.Append(DB.Arc.Create(plane, r * MM, math.pi, 2 * math.pi))
    return ca


def _poly_loop(pts):
    ca = DB.CurveArray()
    n = len(pts)
    for i in range(n):
        ca.Append(DB.Line.CreateBound(pts[i], pts[(i + 1) % n]))
    return ca


def _hex_points(center, n, across_flats, rotation_deg):
    u, v = _basis(n)
    R = (across_flats / 2.0) / math.cos(math.radians(30)) * MM
    pts = []
    for k in range(6):
        a = math.radians(30 + 60 * k + rotation_deg)
        pts.append(center + u.Multiply(R * math.cos(a)) + v.Multiply(R * math.sin(a)))
    return pts


def _check_min(label, value):
    if value is not None and abs(float(value)) < MIN_SIZE_MM:
        raise ValueError("{} = {} mm is below Revit's minimum size ({} mm)".format(
            label, value, MIN_SIZE_MM))


def _extrude(doc, loops, plane, depth_mm, solid=True):
    _check_min("depth/length", depth_mm)
    caa = DB.CurveArrArray()
    for l in loops:
        caa.Append(l)
    sp = DB.SketchPlane.Create(doc, plane)
    return doc.FamilyCreate.NewExtrusion(solid, caa, sp, float(depth_mm) * MM)


def _loop_from_spec(loop, plane, n):
    if "circle" in loop:
        c = loop["circle"]
        _check_min("radius", c["radius"])
        pl = DB.Plane.CreateByNormalAndOrigin(n, _pt(c["center"]))
        return _circle_loop(pl, float(c["radius"]))
    if "points" in loop:
        return _poly_loop([_pt(p) for p in loop["points"]])
    if "segments" in loop:
        ca = DB.CurveArray()
        for s in loop["segments"]:
            if "line" in s:
                ca.Append(DB.Line.CreateBound(_pt(s["line"][0]), _pt(s["line"][1])))
            elif "arc" in s:  # [start, end, point_on_arc]
                a = s["arc"]
                ca.Append(DB.Arc.Create(_pt(a[0]), _pt(a[1]), _pt(a[2])))
            else:
                raise ValueError("segment needs 'line' or 'arc'")
        return ca
    raise ValueError("loop needs 'points', 'segments' or 'circle'")


def _loop_origin(loop):
    if "circle" in loop:
        return loop["circle"]["center"]
    if "points" in loop:
        return loop["points"][0]
    if "segments" in loop:
        s = loop["segments"][0]
        return (s.get("line") or s.get("arc"))[0]


def _make_element(doc, el):
    t = el.get("type", "").lower()
    solid = not el.get("void", False)

    if t == "box":
        mn, mx = el["min"], el["max"]
        x1, x2 = sorted([mn[0], mx[0]])
        y1, y2 = sorted([mn[1], mx[1]])
        z1, z2 = sorted([mn[2], mx[2]])
        _check_min("box width", x2 - x1)
        _check_min("box depth", y2 - y1)
        pl = DB.Plane.CreateByNormalAndOrigin(DB.XYZ.BasisZ, _pt((0, 0, z1)))
        pts = [_pt((x1, y1, z1)), _pt((x2, y1, z1)), _pt((x2, y2, z1)), _pt((x1, y2, z1))]
        return _extrude(doc, [_poly_loop(pts)], pl, z2 - z1, solid)

    if t == "cylinder":
        n = _axis(el.get("axis", "z"))
        c = _pt(el["center"])
        _check_min("radius", el["radius"])
        pl = DB.Plane.CreateByNormalAndOrigin(n, c)
        loops = [_circle_loop(pl, float(el["radius"]))]
        if el.get("inner_radius"):
            loops.append(_circle_loop(pl, float(el["inner_radius"])))
        return _extrude(doc, loops, pl, el["length"], solid)

    if t == "hex":
        n = _axis(el.get("axis", "z"))
        c = _pt(el["center"])
        pl = DB.Plane.CreateByNormalAndOrigin(n, c)
        loops = [_poly_loop(_hex_points(c, n, float(el["across_flats"]),
                                        float(el.get("rotation", 0))))]
        if el.get("inner_radius"):
            loops.append(_circle_loop(pl, float(el["inner_radius"])))
        return _extrude(doc, loops, pl, el["length"], solid)

    if t == "prism":
        n = _axis(el["direction"])
        loops_spec = el["loops"]
        origin = _pt(_loop_origin(loops_spec[0]))
        pl = DB.Plane.CreateByNormalAndOrigin(n, origin)
        loops = [_loop_from_spec(l, pl, n) for l in loops_spec]
        return _extrude(doc, loops, pl, el["length"], solid)

    raise ValueError("Unknown element type '{}'".format(t))


def _extents(doc):
    mn = [1e18] * 3
    mx = [-1e18] * 3
    items = []
    for e in DB.FilteredElementCollector(doc).OfClass(DB.GenericForm):
        b = e.get_BoundingBox(None)
        if b is None:
            continue
        lo = [b.Min.X / MM, b.Min.Y / MM, b.Min.Z / MM]
        hi = [b.Max.X / MM, b.Max.Y / MM, b.Max.Z / MM]
        for i in range(3):
            mn[i] = min(mn[i], lo[i])
            mx[i] = max(mx[i], hi[i])
        mat = ""
        p = e.get_Parameter(DB.BuiltInParameter.MATERIAL_ID_PARAM)
        if p and p.AsElementId() != DB.ElementId.InvalidElementId:
            m = doc.GetElement(p.AsElementId())
            mat = m.Name if m else ""
        cmt = e.get_Parameter(DB.BuiltInParameter.ALL_MODEL_INSTANCE_COMMENTS)
        items.append({
            "id": str(e.Id),
            "name": cmt.AsString() if cmt else "",
            "material": mat,
            "min": [round(v, 2) for v in lo],
            "max": [round(v, 2) for v in hi],
        })
    if not items:
        return None, items
    overall = {
        "min": [round(v, 2) for v in mn],
        "max": [round(v, 2) for v in mx],
        "size": [round(mx[i] - mn[i], 2) for i in range(3)],
    }
    return overall, items


# --------------------------------------------------------------------------
# core functions (usable directly from execute_revit_code for testing)
# --------------------------------------------------------------------------
def build_from_spec(active_doc, uidoc, spec):
    app = active_doc.Application
    result = {"status": "success", "created": 0, "failed": [], "notes": []}

    target = spec.get("target", "active")
    if target == "new":
        tpl = _find_template(app, spec.get("template"))
        fdoc = app.NewFamilyDocument(tpl)
        result["notes"].append("New family from template: " + tpl)
    else:
        fdoc = _find_doc(app, active_doc, spec.get("doc_title"))
    if not fdoc.IsFamilyDocument:
        raise ValueError("Target document '{}' is not a family document".format(fdoc.Title))

    t = DB.Transaction(fdoc, spec.get("transaction_name", "MCP Family Builder"))
    t.Start()
    try:
        if spec.get("category"):
            cat = spec["category"]
            bic = getattr(DB.BuiltInCategory, cat if cat.startswith("OST_") else "OST_" + cat)
            fdoc.OwnerFamily.FamilyCategory = DB.Category.GetCategory(fdoc, bic)
            result["notes"].append("Category: " + cat)

        if spec.get("clear_existing"):
            ids = [e.Id for e in DB.FilteredElementCollector(fdoc).OfClass(DB.GenericForm)]
            for i in ids:
                fdoc.Delete(i)
            result["notes"].append("Removed {} existing forms".format(len(ids)))

        mats = {}
        for name, rgb in (spec.get("materials") or {}).items():
            mats[name] = _get_material(fdoc, name, rgb)

        for idx, el in enumerate(spec.get("elements", [])):
            label = el.get("name") or "{}#{}".format(el.get("type"), idx)
            try:
                ext = _make_element(fdoc, el)
                mname = el.get("material")
                if mname:
                    if mname not in mats:
                        mats[mname] = _get_material(fdoc, mname)
                    p = ext.get_Parameter(DB.BuiltInParameter.MATERIAL_ID_PARAM)
                    if p and not p.IsReadOnly:
                        p.Set(mats[mname])
                if el.get("name"):
                    c = ext.get_Parameter(DB.BuiltInParameter.ALL_MODEL_INSTANCE_COMMENTS)
                    if c and not c.IsReadOnly:
                        c.Set(el["name"])
                result["created"] += 1
            except Exception as ex:
                result["failed"].append({"index": idx, "name": label, "error": str(ex)})

        if spec.get("view_setup", True):
            for v in DB.FilteredElementCollector(fdoc).OfClass(DB.View):
                if v.IsTemplate:
                    continue
                try:
                    v.DetailLevel = DB.ViewDetailLevel.Fine
                    v.DisplayStyle = DB.DisplayStyle.ShadingWithEdges
                except Exception:
                    pass

        status = t.Commit()
        result["commit"] = str(status)
        if status != DB.TransactionStatus.Committed:
            result["status"] = "error"
            result["error"] = "Transaction did not commit (status {})".format(status)
    except Exception:
        if t.HasStarted() and not t.HasEnded():
            t.RollBack()
        raise

    save_path = spec.get("save_path")
    if save_path:
        folder = os.path.dirname(save_path)
        if folder and not os.path.exists(folder):
            os.makedirs(folder)
        so = DB.SaveAsOptions()
        so.OverwriteExistingFile = True
        fdoc.SaveAs(save_path, so)
        result["saved_path"] = save_path
    elif spec.get("save") and fdoc.PathName:
        fdoc.Save()
        result["saved_path"] = fdoc.PathName

    if spec.get("open_in_ui") and fdoc.PathName and uidoc is not None:
        try:
            uidoc.Application.OpenAndActivateDocument(fdoc.PathName)
            result["notes"].append("Activated in UI")
        except Exception as ex:
            result["notes"].append("Could not activate in UI: {}".format(ex))

    result["document"] = fdoc.Title
    overall, _ = _extents(fdoc)
    result["extents_mm"] = overall
    return result


def snapshot(active_doc, view="iso", doc_title=None, size=1200, direction=None):
    app = active_doc.Application
    fdoc = _find_doc(app, active_doc, doc_title)

    if direction:
        fwd = DB.XYZ(float(direction[0]), float(direction[1]), float(direction[2])).Normalize()
    else:
        key = (view or "iso").lower()
        if key not in VIEW_DIRECTIONS:
            raise ValueError("view must be one of: " + ", ".join(sorted(VIEW_DIRECTIONS)))
        d = VIEW_DIRECTIONS[key]
        fwd = DB.XYZ(d[0], d[1], d[2]).Normalize()

    if abs(fwd.Z) > 0.99:
        up = DB.XYZ.BasisY if fwd.Z < 0 else DB.XYZ.BasisY.Negate()
    else:
        up = fwd.CrossProduct(DB.XYZ.BasisZ).CrossProduct(fwd).Normalize()

    overall, _ = _extents(fdoc)
    if overall:
        c = DB.XYZ((overall["min"][0] + overall["max"][0]) / 2.0 * MM,
                   (overall["min"][1] + overall["max"][1]) / 2.0 * MM,
                   (overall["min"][2] + overall["max"][2]) / 2.0 * MM)
    else:
        c = DB.XYZ.Zero
    eye = c - fwd.Multiply(30.0)

    t = DB.Transaction(fdoc, "MCP snapshot view")
    t.Start()
    v3 = None
    for v in DB.FilteredElementCollector(fdoc).OfClass(DB.View3D):
        if not v.IsTemplate and v.CanBePrinted:
            v3 = v
            break
    if v3 is None:
        vft = [x for x in DB.FilteredElementCollector(fdoc).OfClass(DB.ViewFamilyType)
               if x.ViewFamily == DB.ViewFamily.ThreeDimensional][0]
        v3 = DB.View3D.CreateIsometric(fdoc, vft.Id)
    v3.SetOrientation(DB.ViewOrientation3D(eye, up, fwd))
    try:
        v3.DetailLevel = DB.ViewDetailLevel.Fine
        v3.DisplayStyle = DB.DisplayStyle.ShadingWithEdges
    except Exception:
        pass
    # Scale to object size so line weights stay thin after zoom-to-fit
    try:
        biggest = max(overall["size"]) if overall else 1000.0
        v3.Scale = max(1, int(round(biggest / 150.0)))
    except Exception:
        pass
    t.Commit()

    folder = os.path.join(tempfile.gettempdir(), "RevitMCPExports", "family_builder")
    if not os.path.exists(folder):
        os.makedirs(folder)
    for f in os.listdir(folder):
        try:
            os.remove(os.path.join(folder, f))
        except Exception:
            pass
    o = DB.ImageExportOptions()
    o.ExportRange = DB.ExportRange.SetOfViews
    ids = List[DB.ElementId]()
    ids.Add(v3.Id)
    o.SetViewsAndSheets(ids)
    o.FilePath = os.path.join(folder, "snap")
    o.ZoomType = DB.ZoomFitType.FitToPage
    o.PixelSize = int(size)
    o.FitDirection = DB.FitDirectionType.Horizontal
    o.HLRandWFViewsFileType = DB.ImageFileType.PNG
    o.ShadowViewsFileType = DB.ImageFileType.PNG
    fdoc.ExportImage(o)
    pngs = [f for f in os.listdir(folder) if f.lower().endswith(".png")]
    if not pngs:
        raise RuntimeError("Image export produced no file")
    with open(os.path.join(folder, pngs[0]), "rb") as fh:
        data = base64.b64encode(fh.read())
    if not isinstance(data, str):
        data = data.decode("ascii")
    return {"status": "success", "image_data": data, "content_type": "image/png",
            "document": fdoc.Title, "view": view, "extents_mm": overall}


def measure(active_doc, doc_title=None, include_elements=True):
    fdoc = _find_doc(active_doc.Application, active_doc, doc_title)
    overall, items = _extents(fdoc)
    res = {"status": "success", "document": fdoc.Title, "count": len(items),
           "extents_mm": overall}
    if include_elements:
        res["elements"] = items
    return res


# --------------------------------------------------------------------------
# routes
# --------------------------------------------------------------------------
def _error(e, status=500):
    return routes.make_response(
        data={"status": "error", "error": str(e), "traceback": traceback.format_exc()},
        status=status)


def register_family_builder_routes(api):
    """Register family builder routes with the API"""

    @api.route("/family_builder/build/", methods=["POST"])
    def fb_build(doc, uidoc, request):
        try:
            spec = _parse(request)
            if isinstance(spec.get("spec"), (dict, str)):
                spec = spec["spec"]
                if isinstance(spec, str):
                    spec = json.loads(spec)
            return routes.make_response(data=build_from_spec(doc, uidoc, spec))
        except Exception as e:
            logger.error("family_builder/build failed: %s", e)
            return _error(e)

    @api.route("/family_builder/snapshot/", methods=["POST"])
    def fb_snapshot(doc, request):
        try:
            d = _parse(request)
            return routes.make_response(data=snapshot(
                doc, d.get("view", "iso"), d.get("doc_title"),
                d.get("size", 1200), d.get("direction")))
        except Exception as e:
            return _error(e)

    @api.route("/family_builder/measure/", methods=["POST"])
    def fb_measure(doc, request):
        try:
            d = _parse(request)
            return routes.make_response(data=measure(
                doc, d.get("doc_title"), d.get("include_elements", True)))
        except Exception as e:
            return _error(e)
