# Compare a built rootfs against `docker export`, allowing exactly the paths a
# container runtime is known to add or replace -- and no others.
import hashlib, os, sys

RUNTIME_ADDED = {".dockerenv", "dev/console", "dev/pts", "dev/shm", "etc/resolv.conf"}
RUNTIME_REPLACED = {"etc/hostname", "etc/hosts", "etc/mtab"}

def scan(root):
    out = {}
    for dp, dns, fns in os.walk(root):
        for n in list(dns) + list(fns):
            p = os.path.join(dp, n)
            rel = os.path.relpath(p, root)
            st = os.lstat(p)
            if os.path.islink(p): out[rel] = ("l", oct(st.st_mode & 0o7777), os.readlink(p))
            elif os.path.isdir(p): out[rel] = ("d", oct(st.st_mode & 0o7777), "")
            else:
                h = hashlib.sha256(open(p, "rb").read()).hexdigest()[:16]
                out[rel] = ("f", oct(st.st_mode & 0o7777), h)
    return out

mine, ref = scan(sys.argv[1]), scan(sys.argv[2])
fail = 0
extra_mine = sorted(set(mine) - set(ref))
extra_ref = sorted(set(ref) - set(mine))
changed = sorted(p for p in set(mine) & set(ref) if mine[p] != ref[p])

if extra_mine:
    print(f"  FAIL  {len(extra_mine)} path(s) the image does not have: {extra_mine[:6]}"); fail = 1
else:
    print(f"  ok    nothing in the built rootfs that the image did not describe")

unexpected_ref = [p for p in extra_ref if p not in RUNTIME_ADDED]
if unexpected_ref:
    print(f"  FAIL  {len(unexpected_ref)} path(s) missing that are not runtime artifacts: {unexpected_ref[:6]}"); fail = 1
else:
    print(f"  ok    the only paths missing are the {len(extra_ref)} the runtime adds")

unexpected_changed = [p for p in changed if p not in RUNTIME_REPLACED]
if unexpected_changed:
    print(f"  FAIL  {len(unexpected_changed)} path(s) differ that the runtime does not replace: {unexpected_changed[:6]}"); fail = 1
else:
    print(f"  ok    {len(set(mine) & set(ref)) - len(changed)} shared paths match exactly (type, mode, content, link target)")

# A stale allowance is cover for the next real difference.
stale = (RUNTIME_ADDED - set(extra_ref)) | (RUNTIME_REPLACED - set(changed))
if stale:
    print(f"  FAIL  allowance is stale, these no longer differ: {sorted(stale)}"); fail = 1
else:
    print(f"  ok    every allowed exception is still an actual difference")

print("rootfs PASS" if not fail else "rootfs FAIL")
sys.exit(fail)
