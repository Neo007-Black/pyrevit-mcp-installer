# -*- coding: utf-8 -*-
"""Family builder tools: build Revit family geometry from a JSON spec,
take oriented snapshots, and measure the result (image-to-family workflow)."""

import base64
import json
from typing import Any, Dict, List, Optional, Union

from mcp.server.fastmcp import Context, Image
from .utils import format_response


def register_family_builder_tools(mcp, revit_get, revit_post):
    """Register family builder tools with the MCP server."""
    _ = revit_get

    @mcp.tool()
    async def build_family_geometry(
        spec: Union[Dict[str, Any], str], ctx: Context = None
    ) -> str:
        """
        Build Revit family geometry from a geometry spec (all sizes in mm).

        Image-to-family workflow (follow these rules in order):
          1. Break down the geometry: identify the views, compute a px->mm scale
             per view, split the object into parts and ESTIMATE every part that
             has no dimension (flats, grooves, shoulders, chamfers, pads, bends,
             tabs, caps). Show the user a breakdown table first.
          2. Call this tool with the spec built from that breakdown.
          3. Ask the user (do not guess) when something critical is unclear.
          4. Compare: call get_family_snapshot (front/left/top/iso) and
             measure_family, compare with the image, then fix and rebuild.

        Coordinates: X = width/length, Y = depth (Front = -Y), Z = up (0 = Ref. Level).
        Minimum size in Revit is about 0.8 mm: no thinner extrusions or edges.

        Spec keys:
          target: "active" (default) | "new"
          template: family template name or path for target "new"
                    (default "Metric Generic Model")
          doc_title: an open family to build in (target "active")
          category: e.g. "MechanicalEquipment", "PipeAccessory", "PipeFitting",
                    "PlumbingFixtures", "GenericModel" (OST_ prefix optional)
          clear_existing: true to delete existing solid/void forms first
          materials: {"Brass": [205,195,160], "Steel": [175,178,182]}
          save_path: "D:\\\\Folder\\\\Name.rfa" (SaveAs, overwrite) | save: true
          open_in_ui: true to open the saved family in the Revit window
          elements: list of parts, each with optional "name", "material", "void":
            {"type":"box", "min":[x,y,z], "max":[x,y,z]}
            {"type":"cylinder", "center":[x,y,z], "axis":"x|-x|y|-y|z|-z|[dx,dy,dz]",
             "radius":r, "length":L, "inner_radius":ri}   # center = start of axis
            {"type":"hex", "center":[x,y,z], "axis":"x", "across_flats":26,
             "length":15, "inner_radius":10.5, "rotation":0}
             # rotation 0 = corners up/down, flats on the sides; 30 = flats up/down
            {"type":"prism", "direction":"y", "length":14, "loops":[
               {"points":[[x,y,z], ...]},                     # polygon
               {"segments":[{"line":[p1,p2]}, {"arc":[start,end,mid]}]},
               {"circle":{"center":[x,y,z], "radius":r}}]}     # extra loops = holes
             # all loop points must lie on the plane through the first point,
             # normal to direction. Use prisms for bent levers, brackets, and
             # bodies with flats.

        Returns: created count, failed parts (name + reason), overall extents,
        and the saved path.
        """
        try:
            if isinstance(spec, str):
                spec = json.loads(spec)
            n = len(spec.get("elements", []))
            if ctx:
                await ctx.info("Building family geometry: {} elements".format(n))
            response = await revit_post(
                "/family_builder/build/", spec, ctx, timeout=180.0
            )
            if isinstance(response, dict) and response.get("status") == "success":
                return json.dumps(response, indent=2)
            return format_response(response)
        except (ConnectionError, ValueError, RuntimeError) as e:
            msg = "Error building family geometry: {}".format(e)
            if ctx:
                await ctx.error(msg)
            return msg

    @mcp.tool()
    async def get_family_snapshot(
        view: str = "iso",
        doc_title: Optional[str] = None,
        direction: Optional[List[float]] = None,
        size: int = 1200,
        ctx: Context = None,
    ):
        """
        Export an oriented, shaded 3D image of a family, used to compare it with
        the source picture. Unlike elevation exports, it frames only the
        geometry, without reference planes.

        view: front | back | left | right | top | bottom | iso | iso_right |
              iso_back_left | iso_back_right   (Front = -Y)
        direction: optional custom look direction [dx, dy, dz]; overrides view
        doc_title: open family document (default: active document)
        size: image width in pixels
        """
        payload = {"view": view, "doc_title": doc_title,
                   "direction": direction, "size": size}
        response = await revit_post(
            "/family_builder/snapshot/", payload, ctx, timeout=120.0
        )
        if isinstance(response, dict) and response.get("image_data"):
            return Image(data=base64.b64decode(response["image_data"]), format="png")
        return format_response(response)

    @mcp.tool()
    async def measure_family(
        doc_title: Optional[str] = None,
        include_elements: bool = True,
        ctx: Context = None,
    ) -> str:
        """
        Measure family geometry in mm: overall min/max/size, plus each form's
        bounding box, material and name. Use it to check overall dimensions
        against the drawing (length, height, width, offsets).
        """
        payload = {"doc_title": doc_title, "include_elements": include_elements}
        response = await revit_post("/family_builder/measure/", payload, ctx)
        if isinstance(response, dict) and response.get("status") == "success":
            return json.dumps(response, indent=2)
        return format_response(response)
