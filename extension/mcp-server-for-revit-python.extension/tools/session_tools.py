# -*- coding: utf-8 -*-
"""Tools for working with several open Revit sessions."""
import json

from mcp.server.fastmcp import Context

from . import sessions


def register_session_tools(mcp, with_key):
    @mcp.tool()
    async def list_revit_sessions(ctx: Context = None) -> str:
        """List the open Revit sessions that accept MCP commands: year, process id,
        port, document title, and which one is selected. Call this when more than
        one Revit may be open."""
        try:
            found = await sessions.describe(with_key)
        except OSError as error:
            return json.dumps({"status": "error", "error": str(error)}, indent=2)
        return json.dumps({"status": "success", "count": len(found), "sessions": found}, indent=2)

    @mcp.tool()
    async def select_revit_session(target: str, ctx: Context = None) -> str:
        """Choose which open Revit all following tools act on. target is a process id,
        a Revit year such as "2024", or "auto" to clear the choice. When several
        sessions are open, ask the user which one to use before selecting it."""
        try:
            result = await sessions.select(target, with_key)
        except OSError as error:
            result = {"status": "error", "error": str(error)}
        return json.dumps(result, indent=2)
