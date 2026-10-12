#!/usr/bin/env python3
"""Run the Lua test files in tests/ under lupa (Lua 5.2). Usage: python3 tests/run_tests.py [name ...]"""
import glob, os, shutil, sys, tempfile
from lupa.lua52 import LuaRuntime, lua_type

def lupa_is_table(v):
    return lua_type(v) == 'table'

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

def main():
    names = sys.argv[1:]
    files = sorted(glob.glob(os.path.join(HERE, "test_*.lua")))
    if names:
        files = [f for f in files if any(n in os.path.basename(f) for n in names)]
    sandbox = tempfile.mkdtemp(prefix="esssim_")
    failed = 0
    for f in files:
        lua = LuaRuntime(unpack_returned_tuples=True, register_eval=False)
        lua.execute("package.path = ... .. '/?.lua;' .. package.path", HERE)
        g = lua.globals()
        def to_lua(v):
            if isinstance(v, dict):
                return lua.table_from({k: to_lua(x) for k, x in v.items()})
            if isinstance(v, list):
                return lua.table_from([to_lua(x) for x in v])
            return v

        def from_lua(v):
            if lupa_is_table(v):
                keys = list(v.keys())
                if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
                    return [from_lua(v[k]) for k in sorted(keys)]
                return {str(k): from_lua(v[k]) for k in keys}
            return v

        def remove(p):
            if os.path.isdir(p): shutil.rmtree(p, ignore_errors=True)
            elif os.path.exists(p): os.remove(p)

        def move(s, d):
            os.makedirs(os.path.dirname(d), exist_ok=True)
            shutil.move(s, d)

        g.PY = lua.table_from({
            "copytree": lambda s, d: shutil.copytree(s, d),
            "rmtree": lambda p: shutil.rmtree(p, ignore_errors=True),
            "remove": remove,
            "move": move,
            "isdir": lambda p: os.path.isdir(p),
            "makedirs": lambda p: os.makedirs(p, exist_ok=True),
            "listdir": lambda p: lua.table_from(sorted(os.listdir(p))) if os.path.isdir(p) else lua.table_from([]),
            "json_decode": lambda s: to_lua(__import__("json").loads(s)),
            "json_encode": lambda t: __import__("json").dumps(from_lua(t)),
        })
        g.ROOT, g.SANDBOX = ROOT, sandbox
        print("== " + os.path.basename(f))
        try:
            res = lua.execute(open(f).read(), None) if False else lua.eval("function(src, name) local fn, e = load(src, '@'..name) if not fn then error(e) end return fn() end")(open(f).read(), f)
            if res and res != 0:
                failed += int(res)
        except Exception as e:
            print("  CRASH: %s" % e); failed += 1
    shutil.rmtree(sandbox, ignore_errors=True)
    print("\nFAILED: %d" % failed if failed else "\nALL PASSED")
    sys.exit(1 if failed else 0)

main()
