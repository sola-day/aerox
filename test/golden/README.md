# Golden corpus

Every file here is an oracle: the value an upstream implementation produced, never
a value we believe is right (VERIFICATION §0, §2). Rules:

- Every file is listed in `MANIFEST.json` with `kind`, `sha256`, `date` and either
  a `source` (`copied`: verbatim from a pinned commit of a reading-room repo, or
  `transcribed`: hand-carried out of a test file, with the file named) or a
  `generator` (`generated`: the command and pinned container image/packages).
- `mix aerox.golden.verify` fails on any file without an entry, any hash mismatch,
  and — when `../bsky` is present — any byte of drift from the pinned upstream commit.
- Regeneration is deliberate and reviewed: `tools/golden/vendor.py` re-copies the
  pinned files; `tools/golden/ts/run.sh` re-runs the generators. Never edit a golden
  by hand to make a test pass.

| Directory | Oracle |
|---|---|
| `syntax/` | `atproto/interop-test-files/syntax` |
| `crypto/` | `atproto/interop-test-files/crypto` (includes high-S negatives) |
| `dagcbor/`, `cid/` | `@ipld/dag-cbor` + `multiformats` via `tools/golden/ts` |
| `dagcbor/invalid/` | hand-written non-canonical mutations (VERIFICATION §3.3) |
| `data-model/` | indigo `atproto/atdata/testdata` |
| `mst/` | `atproto/packages/repo/tests` (`mst.test.ts`, proofs), indigo `mst/testdata` |
| `car/` | `atproto/packages/repo/tests/car-file-fixtures.json` |
| `firehose/` | indigo `atproto/repo/testdata/firehose_commit_*.json` |
| `lexicon/` | indigo `atproto/lexicon/testdata` |
| `plc/` | `did-method-plc/interop_tests/audit_log` |
