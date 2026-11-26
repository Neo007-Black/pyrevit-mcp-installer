# -*- coding: utf-8 -*-
"""Secret-key check for every Revit MCP route.

pyRevit Routes has no authentication, and pyRevit 6.x does not pass request
headers to handlers, so the key travels as the ``key`` query parameter.
The key file is created here (inside Revit) and read by main.py.
"""
import inspect
import io
import os

from pyrevit import routes

KEY_FILE = os.path.join(os.environ["APPDATA"], "pyRevit", "mcp_routes.key")
MIN_LENGTH = 32


def _read_key():
    try:
        with io.open(KEY_FILE, "r", encoding="ascii") as handle:
            return handle.read().strip()
    except (IOError, OSError, UnicodeError):
        return ""


def _new_key():
    return "".join("{:02x}".format(byte) for byte in bytearray(os.urandom(32)))


def ensure_key():
    """Create the key file once. An existing valid key is kept."""
    if len(_read_key()) >= MIN_LENGTH:
        return
    folder = os.path.dirname(KEY_FILE)
    if not os.path.isdir(folder):
        os.makedirs(folder)
    with io.open(KEY_FILE, "w", encoding="ascii") as handle:
        handle.write(u"" + _new_key())


def is_allowed(request):
    expected = _read_key()
    # No readable key means nothing is allowed.
    if len(expected) < MIN_LENGTH:
        return False
    given = (getattr(request, "query_params", None) or {}).get("key")
    try:
        return str(given) == str(expected)
    except UnicodeError:
        return False


def deny():
    return routes.make_response(
        data={"error": "Unauthorized: missing or wrong MCP key"}, status=401
    )


class GuardedAPI(object):
    """Same ``route`` decorator as routes.API, with the key check added."""

    def __init__(self, api):
        self._api = api
        ensure_key()

    def route(self, pattern, methods=["GET"]):
        register = self._api.route(pattern, methods=methods)

        def decorator(function):
            register(_guard(function))
            return function

        return decorator


def _guard(function):
    # pyRevit chooses what to pass, and which thread to use, from the argument
    # names. So the wrapper has the same names, plus "request".
    names = list(inspect.getargspec(function).args) if hasattr(inspect, "getargspec") \
        else list(inspect.getfullargspec(function).args)
    outer = names if "request" in names else names + ["request"]
    source = (
        "def {name}({outer}):\n"
        "    if not _is_allowed(request):\n"
        "        return _deny()\n"
        "    return _function({inner})\n"
    ).format(
        name=function.__name__,
        outer=", ".join(outer),
        inner=", ".join("{0}={0}".format(n) for n in names),
    )
    namespace = {"_is_allowed": is_allowed, "_deny": deny, "_function": function}
    exec(source, namespace)
    return namespace[function.__name__]
