# -*- coding: utf-8 -*-
"""Find the Revit sessions that run pyRevit Routes, and choose which one to use.

Each Revit process gets its own Routes port (48884, then higher ones). This
module reads the Windows table of listening ports and keeps only the ports in
that range that belong to a Revit.exe process, so the secret key is never sent
to another program.

Safety rule: when it is not clear which Revit is meant, nothing is sent.
"""
import asyncio
import ctypes
import ntpath
import re
import socket
import struct
from ctypes import wintypes
from typing import Callable, Dict, List, Optional, Tuple

import httpx

FIRST_PORT = 48884
LAST_PORT = 48983

# The session chosen with select_revit_session, or None. Identified by process id.
_selected: Optional[Dict] = None


# ---------- Windows: who is listening ----------
def _listening_ports() -> List[Tuple[int, int]]:
    """(port, process id) for every IPv4 TCP listener on this computer."""
    get_table = ctypes.WinDLL("iphlpapi").GetExtendedTcpTable
    size = wintypes.DWORD(0)
    af_inet, owner_pid_listeners = 2, 3
    for _ in range(5):  # the table can grow between the two calls
        buffer = ctypes.create_string_buffer(size.value or 1)
        result = get_table(buffer, ctypes.byref(size), False, af_inet, owner_pid_listeners, 0)
        if result == 0:
            break
        if result != 122:  # ERROR_INSUFFICIENT_BUFFER
            raise OSError("Could not read the list of listening ports ({})".format(result))
    else:
        raise OSError("Could not read the list of listening ports")
    count = struct.unpack_from("<I", buffer.raw, 0)[0]
    rows = []
    for index in range(count):
        # state, local address, local port, remote address, remote port, process id
        row = struct.unpack_from("<6I", buffer.raw, 4 + index * 24)
        address = socket.inet_ntoa(struct.pack("<I", row[1]))
        if address in ("127.0.0.1", "0.0.0.0"):
            rows.append((socket.ntohs(row[2] & 0xFFFF), row[5]))
    return rows


def _process_path(pid: int) -> str:
    """Full path of a process, or "" when it cannot be read."""
    kernel = ctypes.WinDLL("kernel32")
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.QueryFullProcessImageNameW.argtypes = [
        wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pid)  # query limited information
    if not handle:
        return ""
    try:
        text = ctypes.create_unicode_buffer(32768)
        length = wintypes.DWORD(len(text))
        ok = kernel.QueryFullProcessImageNameW(handle, 0, text, ctypes.byref(length))
        return text.value if ok else ""
    finally:
        kernel.CloseHandle(handle)


def find_sessions() -> List[Dict]:
    """One entry per Revit process that has a Routes port."""
    found: Dict[int, Dict] = {}
    for port, pid in _listening_ports():
        if not FIRST_PORT <= port <= LAST_PORT:
            continue
        path = _process_path(pid)
        if ntpath.basename(path).lower() != "revit.exe":
            continue
        year = re.search(r"Revit (\d{4})", path)
        session = found.setdefault(pid, {"pid": pid, "year": year.group(1) if year else "unknown", "ports": []})
        session["ports"].append(port)
    for session in found.values():
        session["ports"].sort()
    return sorted(found.values(), key=lambda s: (s["year"], s["pid"]))


# ---------- asking a session about itself ----------
async def probe(port: int, params: Dict) -> Optional[str]:
    """Document title (or a short state) if this port answers as Revit MCP, else None."""
    url = "http://127.0.0.1:{}/revit_mcp/status/".format(port)
    try:
        async with httpx.AsyncClient(timeout=5.0, trust_env=False) as client:
            response = await client.get(url, params=params)
        if response.status_code == 401:
            return "refused the secret key (restart this Revit)"
        data = response.json()
        if data.get("api_name") != "revit_mcp":
            return None
        return data.get("document_title") or "no document open"
    except httpx.TimeoutException:
        return "busy, did not answer"
    except Exception:
        return None


async def describe(with_key: Callable[[], Dict]) -> List[Dict]:
    """All sessions with their document names."""
    sessions = find_sessions()
    for session in sessions:
        answers = await asyncio.gather(*[probe(port, with_key()) for port in session["ports"]])
        answered = [(p, a) for p, a in zip(session["ports"], answers) if a is not None]
        session["port"], session["document"] = answered[0] if answered else (session["ports"][0], "not answering")
        session["selected"] = bool(_selected and _selected["pid"] == session["pid"])
    return sessions


def _listing(sessions: List[Dict]) -> str:
    return "; ".join("Revit {} (process {})".format(s["year"], s["pid"]) for s in sessions) or "none"


async def resolve(with_key: Callable[[], Dict]) -> Tuple[Optional[str], Optional[str]]:
    """(base URL, None) for the Revit to use, or (None, explanation)."""
    try:
        sessions = find_sessions()
    except OSError as error:
        return None, "Error: {}".format(error)

    if _selected:
        match = [s for s in sessions if s["pid"] == _selected["pid"] and s["year"] == _selected["year"]]
        if not match:
            return None, (
                "Error: the selected Revit {} (process {}) is no longer available. Nothing was sent. "
                "Available: {}. Use list_revit_sessions, then select_revit_session."
            ).format(_selected["year"], _selected["pid"], _listing(sessions))
        session = match[0]
    elif len(sessions) == 1:
        session = sessions[0]
    elif not sessions:
        return None, (
            "Error: no Revit with pyRevit Routes was found. Start Revit, open a project, "
            "and check that Routes is enabled in pyRevit Settings."
        )
    else:
        return None, (
            "Error: several Revit sessions are open and none is selected. Nothing was sent. "
            "Available: {}. Ask the user which one to use, then call select_revit_session."
        ).format(_listing(sessions))

    port = session["ports"][0]
    if len(session["ports"]) > 1:
        for candidate in session["ports"]:
            if await probe(candidate, with_key()) is not None:
                port = candidate
                break
    return "http://127.0.0.1:{}/revit_mcp".format(port), None


async def select(target: str, with_key: Callable[[], Dict]) -> Dict:
    """Choose a session by process id or Revit year. "auto" clears the choice."""
    global _selected
    text = str(target).strip().lower().replace("revit", "").strip()
    sessions = await describe(with_key)
    if text in ("", "auto", "none"):
        _selected = None
        return {"status": "success", "message": "Selection cleared.", "sessions": sessions}
    matches = [s for s in sessions if str(s["pid"]) == text] or [s for s in sessions if s["year"] == text]
    if len(matches) != 1:
        problem = "No session matches" if not matches else "More than one session matches; use the process id for"
        return {"status": "error", "error": "{} '{}'. The selection was not changed.".format(problem, target),
                "sessions": sessions}
    _selected = {"pid": matches[0]["pid"], "year": matches[0]["year"]}
    matches[0]["selected"] = True
    for other in sessions:
        other["selected"] = other["pid"] == _selected["pid"]
    return {"status": "success", "selected": matches[0], "sessions": sessions}
