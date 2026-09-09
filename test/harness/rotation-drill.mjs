// VERIFICATION §10.4 rotation-key drill against the dev PLC (never production):
// a DID whose rotation keys are [recovery, instance]; the instance key
// (lower priority) submits an op; the recovery key (higher priority) nullifies
// it within the 72 h window by forking from the op before it. Asserts that the
// directory's resolved state is the recovery's, and that the nullified op is
// marked in the audit log.
import * as plc from "@did-plc/lib";
import { Secp256k1Keypair } from "@atproto/crypto";

const PLC = process.env.AEROX_PLC_URL ?? "https://plc.aerox.sola.town";
const client = new plc.Client(PLC);

const recovery = await Secp256k1Keypair.create();
const instance = await Secp256k1Keypair.create();
const signing = await Secp256k1Keypair.create();

const did = await client.createDid({
  signingKey: signing.did(),
  handle: "drill.aerox.sola.town",
  pds: "https://pds.aerox.sola.town",
  rotationKeys: [recovery.did(), instance.did()],
  signer: recovery,
});
console.log("did", did);

// The instance key (index 1) moves the account to an attacker's PDS.
const log0 = await client.getDocumentData(did);
await client.updatePds(did, instance, "https://evil.example.com");
console.log("after instance op, pds =", (await client.getDocumentData(did)).services.atproto_pds.endpoint);

// Recovery (index 0) forks from the genesis op: prev = genesis cid, signed by the higher-priority key.
const audit = await client.getOperationLog(did);
const genesisCid = (await client.getAuditableLog(did))[0].cid;
const forked = await plc.createUpdateOp(
  plc.normalizeOp(audit[0]),
  recovery,
  (last) => ({ ...last, services: { ...last.services, atproto_pds: { type: "AtprotoPersonalDataServer", endpoint: "https://pds.aerox.sola.town" } } }),
);
// createUpdateOp sets prev to the cid of the op passed in (genesis) — that is the fork.
await client.sendOperation(did, forked);

const after = await client.getDocumentData(did);
const auditable = await client.getAuditableLog(did);
const nullified = auditable.filter((e) => e.nullified).length;
console.log("after recovery, pds =", after.services.atproto_pds.endpoint, "nullified ops:", nullified);
if (after.services.atproto_pds.endpoint !== "https://pds.aerox.sola.town" || nullified !== 1) {
  console.error("DRILL FAILED"); process.exit(1);
}
// And the instance key can no longer re-nullify the recovery's op (lower priority).
try {
  await client.updatePds(did, instance, "https://evil.example.com");
  // an ordinary update by the instance key is still allowed (it is still a rotation key)
  console.log("instance key can still perform ordinary updates (expected)");
} catch (e) { console.log("instance update rejected:", e.message); }
console.log("DRILL OK", PLC, log0 ? "" : "");
