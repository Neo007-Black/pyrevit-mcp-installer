# v1.1.0

## New

- **Routes works with several open Revit sessions.** Ask Claude to list them and pick one. If several are open and none is picked, nothing is sent.
- Running the installer again updates an MCP extension that it added earlier.

## Fixed

- Revit 2019 now appears in the list of installed Revit versions.

## Checked on the author's PC

- Routes: switching between Revit 2019 and Revit 2025, read only
- Agent MCP on Revit 2025: query, view image, dry run and an approved change

**Download:** `PyRevitMCP-Setup.exe` below.

**Install and update guide:** https://github.com/Neo007-Black/pyrevit-mcp-installer/blob/main/docs/TUTORIAL.md

The EXE is not code-signed, so Windows may show a SmartScreen warning. Check the file first.

SHA-256 of `PyRevitMCP-Setup.exe`:

```text
F14FAF96B3235B7A4B43E8F001A8293BCFF7CC1CD2D63D1991CC14961C35DEFB
```

Unofficial project, not made or endorsed by pyRevit Labs, Autodesk or Anthropic. Third-party software and licenses: https://github.com/Neo007-Black/pyrevit-mcp-installer/blob/main/THIRD-PARTY-NOTICES.md
