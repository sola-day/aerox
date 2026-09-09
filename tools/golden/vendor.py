#!/usr/bin/env python3
"""Copy upstream test vectors into test/golden/ and record them in MANIFEST.json.

VERIFICATION §2.2: every golden file is listed with where it came from and how
to regenerate it. Files here are copied *verbatim* from a pinned commit of a
reading-room checkout (DEV_PLAN §2.4); `mix aerox.golden.verify` re-reads each
one with `git show <commit>:<path>` and fails on any byte of drift.

Usage: tools/golden/vendor.py [--upstream ../bsky]
"""
import argparse, hashlib, json, os, subprocess, sys, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
GOLDEN = os.path.join(ROOT, "test", "golden")
MANIFEST = os.path.join(GOLDEN, "MANIFEST.json")

# (repo, commit, upstream path, golden path)
ATPROTO = ("atproto", "62f944dd6452d90f6e7ac35eaae970a6042ff544")
INDIGO = ("indigo", "dfe5578fd537e71dd1ed884dd09b876dd768dfd5")
PLC = ("did-method-plc", "1e301e5e29dd419c4dfc7d3100a2a614f9286ebe")

FILES = []
for kind in ["atidentifier", "aturi", "did", "handle", "nsid", "recordkey", "tid"]:
    for v in ["valid", "invalid"]:
        FILES.append((*ATPROTO, f"interop-test-files/syntax/{kind}_syntax_{v}.txt", f"syntax/{kind}_syntax_{v}.txt"))
for n in ["datetime_syntax_valid", "datetime_syntax_invalid", "datetime_parse_invalid"]:
    FILES.append((*ATPROTO, f"interop-test-files/syntax/{n}.txt", f"syntax/{n}.txt"))
for n in ["signature-fixtures.json", "w3c_didkey_K256.json", "w3c_didkey_P256.json"]:
    FILES.append((*ATPROTO, f"interop-test-files/crypto/{n}", f"crypto/{n}"))
FILES += [
    (*ATPROTO, "packages/repo/tests/car-file-fixtures.json", "car/car-file-fixtures.json"),
    (*ATPROTO, "packages/repo/tests/commit-proof-fixtures.json", "mst/commit-proof-fixtures.json"),
    (*INDIGO, "atproto/atdata/testdata/data-model-valid.json", "data-model/data-model-valid.json"),
    (*INDIGO, "atproto/atdata/testdata/data-model-invalid.json", "data-model/data-model-invalid.json"),
    (*INDIGO, "atproto/atdata/testdata/data-model-fixtures.json", "data-model/data-model-fixtures.json"),
    (*INDIGO, "atproto/atdata/testdata/feedpost_record.cbor", "data-model/feedpost_record.cbor"),
    (*INDIGO, "atproto/repo/mst/testdata/example_keys.txt", "mst/example_keys.txt"),
    (*INDIGO, "atproto/repo/testdata/commit-proof-fixtures.json", "mst/commit-proof-fixtures.indigo.json"),
    (*INDIGO, "atproto/lexicon/testdata/lexicon-valid.json", "lexicon/lexicon-valid.json"),
    (*INDIGO, "atproto/lexicon/testdata/lexicon-invalid.json", "lexicon/lexicon-invalid.json"),
    (*INDIGO, "atproto/lexicon/testdata/record-data-valid.json", "lexicon/record-data-valid.json"),
    (*INDIGO, "atproto/lexicon/testdata/record-data-invalid.json", "lexicon/record-data-invalid.json"),
]
for n in ["minimal-procedure", "record", "com_atproto_label_defs", "minimal-query", "subscription", "query"]:
    FILES.append((*INDIGO, f"atproto/lexicon/testdata/catalog/{n}.json", f"lexicon/catalog/{n}.json"))
for seq in ["4621317030", "4621317332", "4621332152", "4623075231"]:
    FILES.append((*INDIGO, f"atproto/repo/testdata/firehose_commit_{seq}.json", f"firehose/firehose_commit_{seq}.json"))
for n in ["bnewbold_robocracy", "bskyapp", "duplicate_rotation_keys", "empty_rotation_keys", "legacy_dholms",
          "nullification", "nullification_at_exactly_72h", "nullification_nontrivial", "nullified_tombstone", "tombstone"]:
    FILES.append((*PLC, f"interop_tests/audit_log/valid/log_{n}.json", f"plc/valid/log_{n}.json"))
for n in ["nullification_reused_key", "nullification_too_slow", "sig_b64_newline", "sig_b64_padding_bits",
          "sig_b64_padding_chars", "sig_der", "sig_k256_high_s", "sig_p256_high_s", "update_nullified", "update_tombstoned"]:
    FILES.append((*PLC, f"interop_tests/audit_log/invalid/log_invalid_{n}.json", f"plc/invalid/log_invalid_{n}.json"))


def sha256(b): return hashlib.sha256(b).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", default=os.path.join(ROOT, "..", "bsky"))
    args = ap.parse_args()
    manifest = json.load(open(MANIFEST)) if os.path.exists(MANIFEST) else {"files": {}}
    today = datetime.date.today().isoformat()
    for repo, commit, src, dst in FILES:
        data = subprocess.check_output(["git", "-C", os.path.join(args.upstream, repo), "show", f"{commit}:{src}"])
        out = os.path.join(GOLDEN, dst)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as f: f.write(data)
        entry = manifest["files"].get(dst, {})
        if entry.get("sha256") != sha256(data):
            entry["date"] = today
        entry.update({"source": {"repo": repo, "commit": commit, "path": src}, "kind": "copied", "sha256": sha256(data)})
        manifest["files"][dst] = entry
    # transcribed / hand-written files: keep their entries, refresh hashes
    for dst, entry in manifest["files"].items():
        if entry.get("kind") in ("transcribed", "handwritten", "generated"):
            with open(os.path.join(GOLDEN, dst), "rb") as f:
                entry["sha256"] = sha256(f.read())
    manifest["files"] = dict(sorted(manifest["files"].items()))
    with open(MANIFEST, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True); f.write("\n")
    print(f"{len(FILES)} files vendored; manifest has {len(manifest['files'])} entries")


if __name__ == "__main__":
    main()
