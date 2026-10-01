#!/usr/bin/env python3
"""Regenerate resources/include/lite_xl_plugin_api.h for a given Lua version.

usage: generate_plugin_api.py <lua-src-dir> [existing-header] > new-header

The header is the concatenation of luaconf.h, lua.h, lauxlib.h and lualib.h
where every LUA_API/LUALIB_API/LUAMOD_API function declaration becomes a
SYMBOL_DECLARE() so native plugins resolve the Lua API through the symbol table
that lite-xl passes at load time (see api_require() in src/api/system.c).

The preamble (SYMBOL_* machinery and docs) and the hand written wrappers of the
variadic functions are taken from the existing header, so this script can be
re-run on its own output.

Native plugins take LUA_REGISTRYINDEX, struct layouts and friends from this
header, so it MUST be regenerated whenever the bundled Lua changes.
"""
import re
import sys
from pathlib import Path

lua_dir = Path(sys.argv[1])
old_path = Path(sys.argv[2] if len(sys.argv) > 2 else
                Path(__file__).resolve().parent.parent / "resources/include/lite_xl_plugin_api.h")
old = old_path.read_text(encoding="utf-8")


def src(name):
    return (lua_dir / name).read_text(encoding="utf-8")


def squash(s):
    return re.sub(r"\s+", " ", s).strip()


def norm_ret(s):
    s = squash(s)
    return re.sub(r"\s*\*", " *", s).replace("* *", "**").strip()


lua_h = src("lua.h")
version = ".".join(
    re.search(r'#define LUA_VERSION_%s(?:_N\s+|\s+")(\d+)' % k, lua_h).group(1)
    for k in ("MAJOR", "MINOR", "RELEASE"))

# --- preamble / epilogue from the old header
marker = "\n/*\n** $Id: luaconf.h $"
preamble = old[:old.index(marker)].rstrip("\n") + "\n\n"
m = re.search(r"typical installation of Lua (\d+\.\d+\.\d+)", preamble)
old_version = m.group(1)
preamble = preamble.replace(m.group(0), "typical installation of Lua " + version)
if old_version != version and ("Lua %s:" % old_version) not in preamble:
    permalink = ("\n * - Lua %s: https://github.com/lite-xl/lite-xl/blob/"
                 "ad1597125e7b5751a3c779a886cf24050f6109ba/resources/include/lite_xl_plugin_api.h"
                 % old_version)
    preamble = preamble.replace("\n**/\n#ifndef LITE_XL_PLUGIN_API", permalink + "\n**/\n#ifndef LITE_XL_PLUGIN_API", 1)

import_prelude = old[old.index("#define IMPORT_SYMBOL(name, ret, ...)"):old.index("  IMPORT_SYMBOL(")]
epilogue = old[old.index("}\n\n#undef IMPORT_SYMBOL"):old.rindex("/*****")]


def hand_wrapper(name):
    m = re.search(r"^SYMBOL_WRAP_DECL\([^\n]*\b%s, [^\n]*\.\.\.\) \{\n.*?^\}\n" % name, old, re.M | re.S)
    return m.group(0)


GC_WRAPPER = """SYMBOL_WRAP_DECL(int, lua_gc, lua_State *L, int what, ...) {
  /* there are no straightforward ways of passing data. */
  int r;
  va_list ap;
  va_start(ap, what);
  if (what == LUA_GCSTEP) {
    size_t stepsize = va_arg(ap, size_t);
    r = __lua_gc(L, what, stepsize);
  } else if (what == LUA_GCPARAM) {
    int param = va_arg(ap, int);
    int value = va_arg(ap, int);
    r = __lua_gc(L, what, param, value);
  } else {
    r = __lua_gc(L, what);
  }
  va_end(ap);
  return r;
}
"""
VARARG_WRAPPERS = {
    "lua_pushfstring": hand_wrapper("lua_pushfstring"),
    "luaL_error": hand_wrapper("luaL_error"),
    "lua_gc": GC_WRAPPER,
}

DECL = re.compile(r"^(?:LUA_API|LUALIB_API|LUAMOD_API)\s+([^();]+?)\(\s*(\w+)\s*\)\s*\((.*?)\);",
                  re.M | re.S)
decls = []  # (ret, name, args, vararg)


def convert(text):
    def repl(m):
        ret, name, args = norm_ret(m.group(1)), m.group(2), squash(m.group(3))
        vararg = args.endswith("...")
        if vararg:
            args = args[:-3].rstrip().rstrip(",").strip()
        decls.append((ret, name, args, vararg))
        macro = "SYMBOL_DECLARE_VARARG" if vararg else "SYMBOL_DECLARE"
        return "%s(%s, %s, %s)" % (macro, ret, name, args)
    return DECL.sub(repl, text)


def strip_local_includes(text):
    return re.sub(r'^#include "[^"]+"\n', "", text, flags=re.M)


license_start = lua_h.index("/******")
sections = [
    src("luaconf.h"),
    strip_local_includes(lua_h[:license_start]),
    strip_local_includes(src("lauxlib.h")),
    strip_local_includes(src("lualib.h")),
]
license_text = lua_h[license_start:]
license_text = license_text.replace("PUC-Rio.", "PUC-Rio; Lite XL contributors.", 1)

out = [preamble]
for s in sections:
    out.append("\n" + convert(s))

out.append("\n#ifdef LITE_XL_PLUGIN_ENTRYPOINT\n\n")
for ret, name, args, vararg in decls:
    if vararg:
        out.append(VARARG_WRAPPERS[name])
        continue
    params = [] if args == "void" else [p.strip() for p in args.split(",")]
    names = ", ".join(re.search(r"(\w+)\s*(?:\[\])?$", p).group(1) for p in params)
    call = "SYMBOL_WRAP_CALL(%s%s)" % (name, ", " + names if names else "")
    out.append("SYMBOL_WRAP_DECL(%s, %s, %s) {\n  %s%s;\n}\n"
               % (ret, name, args, "" if ret == "void" else "return ", call))
out.append("\n" + import_prelude)
for ret, name, args, vararg in decls:
    out.append("  IMPORT_SYMBOL(%s, %s, %s%s);\n" % (name, ret, args, ", ..." if vararg else ""))
out.append(epilogue)
out.append(license_text)
sys.stdout.write("".join(out))
