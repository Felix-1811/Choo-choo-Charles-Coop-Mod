#!/usr/bin/env python3
"""Score two-instance runs from their logs. Usage: score_runs.py <runs dir> [run name prefix ...]
Pass = guest joined, guest got its pawn, host saw the guest move >300 units, no crash dump."""
import math, pathlib, re, sys

CHAR = re.compile(r'(BP_NMCharacter_Player_C_\d+)(\*?)\((-?\d+) (-?\d+) (-?\d+)\)')


def read(p):
    return p.read_text(encoding='utf-8', errors='replace').splitlines() if p.exists() else []


def score(run):
    g, h = read(run / 'probe_guest.log'), read(run / 'probe_host.log')
    joined = any('JOINED host world' in l for l in g)
    pawn = any('has a pawn after the host' in l for l in g)
    crash = [d.parent.parent.name.replace('userdir-', '') for d in run.glob('userdir-*/Saved/Crashes/UE4CC-*')]
    keyed = any('held W' in l for l in read(run / 'procs.log'))
    # guest character on the host: the unstarred one on lines where the host's own is starred
    track = []
    for l in h:
        if 'STATUS[wait_guest]' not in l or 'chars=2' not in l:
            continue
        cs = CHAR.findall(l)
        if any(star for _, star, *_ in cs):
            track += [(int(x), int(y)) for name, star, x, y, _ in cs if not star]
    moved = int(math.dist(track[0], track[-1])) if len(track) > 1 else 0
    ok = joined and pawn and not crash and moved > 300
    return ok, f'{run.name} joined={joined} pawn={pawn} keyed={keyed} moved_on_host={moved} crash={",".join(crash) or "no"}'


if __name__ == '__main__':
    root = pathlib.Path(sys.argv[1])
    prefixes = sys.argv[2:] or ['']
    runs = sorted(r for r in root.iterdir() if r.is_dir() and any(r.name.startswith(p) for p in prefixes))
    passed = 0
    for r in runs:
        ok, line = score(r)
        passed += ok
        print(('PASS ' if ok else 'FAIL ') + line)
    print(f'TOTAL {passed}/{len(runs)}')
