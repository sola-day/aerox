#!/usr/bin/env bash
# Splice ops/traefik/aerox.dynamic.yml into the shared ginger-traefik dynamic
# configuration, between markers, and verify Traefik reloaded it cleanly.
#
# The shared Traefik runs with --providers.file.filename (a single file, not a
# directory), so aerox cannot drop in its own file; it has to edit that one.
# The edit is additive, delimited, idempotent, and backed up before every write.
# Nothing here touches the Traefik container itself: the file provider watches
# the file and reloads on change, so other routers keep serving throughout.
set -euo pipefail

REPO_FRAGMENT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/aerox.dynamic.yml"
TARGET="${TRAEFIK_DYNAMIC:-/var/lib/docker/volumes/ginger-traefik-data/_data/dynamic.yml}"
CONTAINER="${TRAEFIK_CONTAINER:-ginger-traefik}"
BEGIN='# >>> aerox (managed by aerox/ops/traefik/install.sh) >>>'
END='# <<< aerox <<<'

[[ -f "$REPO_FRAGMENT" ]] || { echo "missing $REPO_FRAGMENT" >&2; exit 1; }
sudo test -f "$TARGET" || { echo "missing $TARGET" >&2; exit 1; }

backup="${TARGET}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
sudo cp -a "$TARGET" "$backup"
echo "backup: $backup"

sudo python3 - "$TARGET" "$REPO_FRAGMENT" "$BEGIN" "$END" <<'PY'
import re, sys
target, fragment, begin, end = sys.argv[1:5]
current = open(target).read()
block = begin + "\n" + open(fragment).read().rstrip("\n") + "\n" + end + "\n"
pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", re.S)
if pattern.search(current):
    # lambda, not the string: re.sub expands backslash escapes in a string
    # replacement, which silently eats the \\. in the HostRegexp rule.
    updated = pattern.sub(lambda _m: block, current)
    action = "replaced"
else:
    updated = current.rstrip("\n") + "\n\n" + block
    action = "appended"
if updated == current:
    print("unchanged")
else:
    open(target, "w").write(updated)
    print(action)
PY

echo "--- traefik log (last 15s) ---"
sleep 3
docker logs "$CONTAINER" --since 15s 2>&1 | tail -20
