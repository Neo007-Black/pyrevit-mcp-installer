# Security notes

These notes describe checks made on 2026-11-26. They are not an independent audit.

## Claude can run code in Revit

Both methods let an AI agent run Python inside Revit with your Windows permissions. Work on copies, read permission prompts, and do not allow requests you do not understand.

## Routes method

pyRevit Routes is a local web server without its own authentication. The bundled extension therefore:

- listens on `localhost` only (set by the installer);
- requires a random secret key on every extension route;
- turns off pyRevit's Routes "core API".

The key is stored in `%APPDATA%\pyRevit\mcp_routes.key` and sent in the local request address, because pyRevit 6.x does not pass request headers to extensions.

**Limits:** any program running under your Windows account can read the key. Other pyRevit extensions that add their own Routes are not protected by it. Do not use an unmodified copy of the upstream extension with Routes switched on if you need this protection.

## Agent MCP

Built into pyRevit 7.1. The installer leaves approval on `ask` unless you had already chosen something else. This project has not security-tested it.

## The installer

- The EXE is **not code-signed**. Check its SHA-256 against the release page.
- It runs without administrator rights and unpacks to a new temporary folder.
- pyRevit setup files are run only if their SHA-256 and signature check out.
- The pinned Python packages had no advisories listed by [OSV](https://osv.dev) on the date above. This changes over time.

## Reporting a problem

Please use GitHub's private vulnerability reporting if it is enabled for this repository, or ask the owner for a private contact. Do not post keys, config files or project data in public issues.
