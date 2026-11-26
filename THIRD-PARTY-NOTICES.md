# Third-party software

The release EXE contains the software below. Each keeps its own license. This project is not affiliated with their authors.

| Component | Version | License | Source |
|---|---|---|---|
| pyRevit setup programs (unmodified) | 6.5.5.26237 and 7.1.0.26319 | GNU GPL v3, text in `licenses/GPL-3.0.txt` | https://github.com/pyrevitlabs/pyRevit (see its releases and tags) |
| mcp-server-for-revit-python (**modified**) | based on commit `0a6e8a7` | MIT, Copyright (c) 2025 Juan Rodriguez; see the `LICENSE` file in `extension/` | https://github.com/mcp-servers-for-revit/mcp-server-for-revit-python |
| CPython, standalone build | 3.13 | PSF License and others; `LICENSE.txt` inside the bundled `python` folder | https://github.com/astral-sh/python-build-standalone |
| Python packages | see `requirements.pinned.txt` | Each package's license is in its `*.dist-info` folder inside the bundled Python | https://pypi.org |

## Changes made to the MCP extension

- Added `revit_mcp/security.py`: a secret key required by every route.
- Changed `startup.py` and `main.py` to use that key.
- Added family builder routes and tools (`revit_mcp/family_builder.py`, `tools/family_builder_tools.py`) and registered them in `tools/__init__.py`.
- Added selection between several Revit sessions (`tools/sessions.py`, `tools/session_tools.py`, `main.py`).
- Included Revit 2019 in the installation list (`tools/launch_tools.py`).
- Left the upstream `tests` folder out.
