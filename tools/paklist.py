#!/usr/bin/env python3
"""List files in a UE 4.25+ pak (v10/v11, unencrypted index) via its full directory index.
Read-only. Usage: paklist.py <pak> [glob]"""
import fnmatch, struct, sys

MAGIC = b'\xe1\x12\x6f\x5a'


def rstr(f):
    n = struct.unpack('<i', f.read(4))[0]
    if n == 0:
        return ''
    if n < 0:
        return f.read(-n * 2).decode('utf-16-le').rstrip('\x00')
    return f.read(n).decode('latin-1').rstrip('\x00')


def footer(f):
    f.seek(0, 2)
    size = f.tell()
    for tail in range(44, 400):
        f.seek(size - tail)
        if f.read(4) == MAGIC:
            pos = size - tail
            f.seek(pos - 1)
            encrypted = f.read(1)[0]
            f.seek(pos + 4)
            version, off, sz = struct.unpack('<iqq', f.read(20))
            return version, encrypted, off, sz
    raise SystemExit('pak magic not found')


def files(path):
    f = open(path, 'rb')
    version, encrypted, off, _ = footer(f)
    if encrypted:
        raise SystemExit('encrypted index')
    if version < 10:
        raise SystemExit(f'pak v{version}: use a v8 reader')
    f.seek(off)
    mount = rstr(f)
    f.read(4 + 8)                                  # NumEntries, PathHashSeed
    if struct.unpack('<i', f.read(4))[0]:          # has path hash index
        f.read(8 + 8 + 20)
    if not struct.unpack('<i', f.read(4))[0]:
        raise SystemExit('no full directory index')
    dir_off, _ = struct.unpack('<qq', f.read(16))
    f.seek(dir_off)
    for _ in range(struct.unpack('<i', f.read(4))[0]):
        d = rstr(f)
        for _ in range(struct.unpack('<i', f.read(4))[0]):
            name = rstr(f)
            f.read(4)                              # encoded entry location
            yield mount + d + name


if __name__ == '__main__':
    pat = sys.argv[2].lower() if len(sys.argv) > 2 else '*'
    for p in files(sys.argv[1]):
        if fnmatch.fnmatch(p.lower(), pat):
            print(p)
