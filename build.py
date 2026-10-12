#!/usr/bin/env python3
"""
Assemble the deployable computer trees for cc-power-link.

    python3 build.py [--base-url <address>] [--out dist]

Produces dist/sender and dist/display. Each is the complete file tree for one ComputerCraft computer
(copy the contents to the computer's root). The bundled third-party libraries (third_party/) are not copied wholesale: every
require() is followed from this project's own files, and only the vendored modules that are actually
reachable are included.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# every static require("a.b.c") or require "a.b.c"
REQUIRE_RE = re.compile(r'require\s*\(?\s*["\']([^"\']+)["\']')

# modules that ship with ComputerCraft itself, or are handled by the bootloader
BUILTIN_PREFIXES = ("cc.",)
BUILTIN_EXACT = {
    "/initenv", "initenv",
    # standard library modules (lockbox requires some of these by name)
    "string", "math", "table", "os", "io", "bit", "bit32", "utf8", "coroutine", "debug", "package",
}

ROLES = {
    "sender": {
        "startup": "sender/startup.lua",
        # our own library modules this role uses
        "ccpl": ["clock.lua", "config.lua", "protocol.lua", "link.lua", "storage.lua", "configure.lua"],
    },
    "display": {
        "startup": "display/startup.lua",
        "ccpl": ["clock.lua", "config.lua", "protocol.lua", "link.lua", "calc.lua", "ui/style.lua", "ui/panel.lua", "configure.lua"],
    },
}


def module_candidates(mod):
    """Possible file paths (relative to a Lua root) for a module name."""
    base = mod.replace(".", "/")
    return [base + ".lua", base + "/init.lua"]


def find_in(root, mod):
    for cand in module_candidates(mod):
        if os.path.isfile(os.path.join(root, cand)):
            return cand
    return None


def requires_of(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    # drop comment lines so a commented-out require is not followed
    text = "\n".join(line for line in text.splitlines() if not line.strip().startswith("--"))
    return REQUIRE_RE.findall(text)


def build_role(role, spec, vendor, out_root):
    out = os.path.join(out_root, role)
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)

    copied = {}  # dest relative path -> source absolute path
    missing = []

    def add(dest, src):
        copied[dest] = src

    # the role's entry point becomes the computer's startup file
    add("startup.lua", os.path.join(HERE, spec["startup"]))

    # our own library modules, namespaced under ccpl/
    for rel in spec["ccpl"]:
        add("ccpl/" + rel, os.path.join(HERE, "lib", "ccpl", rel))

    # the bootloader helper the bundled libraries expect
    add("initenv.lua", os.path.join(vendor, "initenv.lua"))

    # follow requires from everything we have so far
    queue = list(copied.items())
    seen = set()

    while queue:
        dest, src = queue.pop()
        if src in seen:
            continue
        seen.add(src)

        for mod in requires_of(src):
            if mod in BUILTIN_EXACT or mod.startswith(BUILTIN_PREFIXES):
                continue

            # our own modules
            if mod.startswith("ccpl."):
                rel = find_in(os.path.join(HERE, "lib"), mod)
                if rel is None:
                    missing.append((src, mod))
                    continue
                if rel not in [("ccpl/" + r) for r in spec["ccpl"]] and rel not in copied:
                    # a module in lib/ccpl that the role spec did not list
                    missing.append((src, mod + "  (not listed for role '" + role + "')"))
                continue

            # bundled third-party modules
            rel = find_in(vendor, mod)
            if rel is None:
                missing.append((src, mod))
                continue
            if rel not in copied:
                add(rel, os.path.join(vendor, rel))
                queue.append((rel, os.path.join(vendor, rel)))

    if missing:
        print("ERROR: unresolved requires for role '%s':" % role)
        for src, mod in missing:
            print("  %s -> %s" % (os.path.relpath(src, HERE) if src.startswith(HERE) else src, mod))
        sys.exit(1)

    total = 0
    for dest, src in sorted(copied.items()):
        target = os.path.join(out, dest)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(src, target)
        total += os.path.getsize(src)

    # the configuration tool for this role
    with open(os.path.join(HERE, "tools", "configure.lua"), encoding="utf-8") as f:
        configure_src = f.read().replace("@ROLE@", role)
    with open(os.path.join(out, "configure.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(configure_src)
    copied["configure.lua"] = os.path.join(out, "configure.lua")

    # the bundled libraries are MIT licensed, the license must travel with the copied files
    shutil.copyfile(os.path.join(vendor, "LICENSE"), os.path.join(out, "LICENSE-cc-mek-scada"))
    for lb in ("lockbox/LICENSE",):
        if os.path.isfile(os.path.join(vendor, lb)):
            os.makedirs(os.path.join(out, "lockbox"), exist_ok=True)
            shutil.copyfile(os.path.join(vendor, lb), os.path.join(out, lb))

    # provenance of the vendored code
    commit = "unknown"
    try:
        with open(os.path.join(vendor, "SOURCE.txt")) as sf:
            m = re.search(r"commit (\w+)", sf.read())
            if m: commit = m.group(1)
    except Exception:
        pass
    with open(os.path.join(out, "VENDOR.txt"), "w") as f:
        f.write("cc-power-link %s build\nthird-party library commit: %s\n" % (role, commit))

    vendored = sorted(d for d in copied if not d.startswith("ccpl/") and d not in ("startup.lua", "initenv.lua"))
    print("%-8s %3d files, %6.1f KB   (%d vendored modules)" % (role, len(copied), total / 1000.0, len(vendored)))
    return copied


def adler32(data):
    a, b = 1, 0
    for byte in data:
        a = (a + byte) % 65521
        b = (b + a) % 65521
    return (b << 16) | a


def file_entry(root, rel):
    with open(os.path.join(root, rel), "rb") as f:
        data = f.read()
    return {"path": rel.replace(os.sep, "/"), "size": len(data), "sum": adler32(data)}


def write_manifest(out_root, base_url):
    """Write install.lua (with the download address filled in) and manifest.json for publishing."""
    with open(os.path.join(HERE, "VERSION")) as f:
        version = f.read().strip()

    with open(os.path.join(HERE, "tools", "install.lua"), encoding="utf-8") as f:
        installer = f.read().replace("@BASE_URL@", base_url)
    with open(os.path.join(out_root, "install.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(installer)

    manifest = {"version": version, "installer": file_entry(out_root, "install.lua"), "roles": {}}

    for role in ROLES:
        role_root = os.path.join(out_root, role)
        files = []
        for dirpath, _, names in os.walk(role_root):
            for name in names:
                files.append(file_entry(role_root, os.path.relpath(os.path.join(dirpath, name), role_root)))
        files.sort(key=lambda e: e["path"])
        manifest["roles"][role] = {"files": files}

    with open(os.path.join(out_root, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)

    print("manifest version %s: %s" % (version, ", ".join("%s %d files" % (r, len(v["files"])) for r, v in manifest["roles"].items())))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vendor", default=os.path.join(HERE, "third_party", "cc-mek-scada"), help="folder holding the bundled third-party Lua libraries")
    ap.add_argument("--out", default=os.path.join(HERE, "dist"))
    ap.add_argument("--base-url", default="", help="address the published dist folder will be served from, for the installer")
    args = ap.parse_args()

    vendor = os.path.abspath(args.vendor)
    if not os.path.isfile(os.path.join(vendor, "scada-common", "comms.lua")):
        print("ERROR: %s does not contain the bundled libraries" % vendor)
        sys.exit(1)

    for role, spec in ROLES.items():
        build_role(role, spec, vendor, os.path.abspath(args.out))

    write_manifest(os.path.abspath(args.out), args.base_url)


if __name__ == "__main__":
    main()
