#!/usr/bin/env python3
"""Vendor lexicon JSON files into priv/lexicons/ from pinned upstream commits.

DESIGN §6.6: vendoring is per namespace. The whole com.atproto tree comes from
upstream main; com.atproto.space, com.atproto.simplespace and the permission-set
lexicons (app.bsky.auth*, chat.bsky.authFullChatClient) exist only on the
`permissioned-data` branch (DESIGN §12.6). app.bsky.* files are added per
endpoint by listing them in APP_BSKY below. priv/lexicons/SOURCE.json records
repo, commit and path per file.

Usage: tools/lexicons/vendor.py [--upstream ../bsky]
"""
import argparse, hashlib, json, os, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "priv", "lexicons")
MAIN = "62f944dd6452d90f6e7ac35eaae970a6042ff544"
SPACES = "a90c369508b0c6e1d49bfef0fcaf5dc0ce7d0d6b"  # origin/permissioned-data

# app.bsky.* files vendored so far, one per endpoint/record as they are implemented.
APP_BSKY: list[str] = []


def ls(repo, commit, prefix):
    out = subprocess.check_output(["git", "-C", repo, "ls-tree", "-r", "--name-only", commit, "--", prefix], text=True)
    return [p for p in out.split("\n") if p.endswith(".json")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", default=os.path.join(ROOT, "..", "bsky"))
    args = ap.parse_args()
    repo = os.path.join(args.upstream, "atproto")
    full_spaces = subprocess.check_output(["git", "-C", repo, "rev-parse", "origin/permissioned-data"], text=True).strip()
    if not full_spaces.startswith(SPACES[:9]):
        raise SystemExit(f"origin/permissioned-data moved to {full_spaces}; update SPACES deliberately (DESIGN §12.6)")

    plan = [(MAIN, p) for p in ls(repo, MAIN, "lexicons/com/atproto")]
    for prefix in ["lexicons/com/atproto/space", "lexicons/com/atproto/simplespace", "lexicons/chat/bsky/authFullChatClient.json"]:
        plan += [(full_spaces, p) for p in ls(repo, full_spaces, prefix)]
    plan += [(full_spaces, p) for p in ls(repo, full_spaces, "lexicons/app/bsky") if os.path.basename(p).startswith("auth")]
    plan += [(MAIN, "lexicons/" + p) for p in APP_BSKY]

    source = {"files": {}}
    for commit, path in sorted(set(plan)):
        data = subprocess.check_output(["git", "-C", repo, "show", f"{commit}:{path}"])
        rel = path[len("lexicons/"):]
        dst = os.path.join(OUT, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(data)
        source["files"][rel] = {"repo": "atproto", "commit": commit, "path": path, "sha256": hashlib.sha256(data).hexdigest()}
    with open(os.path.join(OUT, "SOURCE.json"), "w") as f:
        json.dump(source, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"{len(source['files'])} lexicon files vendored")


if __name__ == "__main__":
    main()
