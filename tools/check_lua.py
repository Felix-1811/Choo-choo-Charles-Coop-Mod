#!/usr/bin/env python3
"""Syntax-check every .lua file under a folder (compile only, nothing runs). Exit 1 on error."""
import pathlib, sys
from lupa import LuaRuntime

lua = LuaRuntime()
check = lua.eval('function(src, name) local f, err = load(src, "@" .. name); return err end')
bad = 0
for p in sorted(pathlib.Path(sys.argv[1]).rglob('*.lua')):
    src = p.read_text(encoding='utf-8')
    if any(ord(c) < 32 and c not in '\t\r\n' for c in src):
        print(f'{p}: control character in source'); bad += 1
    err = check(src, p.name)
    if err:
        print(err); bad += 1
print('lua check:', 'FAIL' if bad else 'ok')
sys.exit(1 if bad else 0)
