"""Correctness gate: every reply_turnN line in the session output must equal the reference's."""
import re, sys
def turns(path):
    return {m.group(1): m.group(2).strip() for m in re.finditer(r"ARTEMIS_INFO reply_turn(\d+)=(\S*)", open(path).read())}
ref, got = turns(sys.argv[1]), turns(sys.argv[2])
if not ref:
    sys.exit("gate: reference has no reply_turn lines")
bad = [t for t in sorted(ref, key=int) if got.get(t) != ref[t]]
if bad:
    for t in bad[:3]:
        r, g = ref[t].split(","), (got.get(t) or "").split(",")
        i = next((k for k, (a, b) in enumerate(zip(r, g)) if a != b), min(len(r), len(g)))
        print(f"gate: turn {t} differs at token {i} (ref {r[i:i+5]} got {g[i:i+5]})")
    sys.exit(f"gate FAILED: {len(bad)}/{len(ref)} turns differ from the 4k baseline")
print(f"gate passed: {len(ref)} turns identical to the 4k baseline")
