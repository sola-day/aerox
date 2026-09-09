// Generates test/golden/space/alpha.json from the *published* Spaces alpha
// package, @atproto/space@0.0.0-spaces-alpha-20260818163953 — the version the
// bulletin test client pins (DESIGN §12.1: the alpha is the oracle). Run from
// a checkout where bulletin's dependencies are installed:
//   NODE_PATH=/home/ubuntu/aero/bulletin/node_modules node test/harness/gen-space-alpha-goldens.mjs
// Covers: the set-hash element format, RepoCommit states, the commit ctx /
// MAC / signature (fixed ikm and key, deterministic secp256k1), the two-root
// CAR (serializeRepo) and the three space tokens.
import { createRequire } from 'node:module'
import { writeFileSync } from 'node:fs'
const topRequire = createRequire(process.env.NODE_PATH.replace(/\/?$/, '/') + 'x.js')
const spaceEntry = topRequire.resolve('@atproto/space')
// @atproto/crypto and lex-cbor are pnpm-nested under @atproto/space
const resolve = (m) => createRequire(spaceEntry).resolve(m)
const space = await import(spaceEntry)
const spaceSync = await import(new URL('./sync/index.js', 'file://' + spaceEntry).href)
const crypto = await import(resolve('@atproto/crypto'))
const lexCbor = await import(resolve('@atproto/lex-cbor'))

const hex = (b) => Buffer.from(b).toString('hex')
let seed = 7
const bytes = (n) => Buffer.from(Array.from({ length: n }, () => (seed = (seed * 16807) % 2147483647) & 0xff))

// --- records, element format, set hash
const recordsIn = [
  ['my.bulletin.post', '3k2a4b5c6d7e8', { $type: 'my.bulletin.post', text: 'one', createdAt: '2026-09-09T12:00:00.000Z' }],
  ['my.bulletin.post', 'second', { $type: 'my.bulletin.post', text: 'two', position: { x: 1, y: 2 } }],
  ['my.bulletin.removal', 'a', { $type: 'my.bulletin.removal', subject: { uri: 'at://did:plc:x/space/t/s/did:plc:y/my.bulletin.post/z', cid: 'bafyreid6dzyqk2c7zjmrric22uvngomxomc36pgmwurewgwp7tn22pt6vi' } }],
]
const records = []
for (const [collection, rkey, record] of recordsIn) {
  records.push(await spaceSync.serializeRecord(collection, rkey, record))
}
const repo = space.RepoCommit.fromRecords(records)
const elements = records.map((r) => space.formatSetHashElement(r.collection, r.rkey, r.cid))
const step = new space.RepoCommit()
const steps = []
for (const r of records) { step.add(r.collection, r.rkey, r.cid); steps.push({ state: hex(step.setHash.state()), digest: hex(step.setHash.digest()) }) }
// an update: remove the old cid, add the new one (applyOp with prev)
const updated = await spaceSync.serializeRecord('my.bulletin.post', 'second', { $type: 'my.bulletin.post', text: 'two, edited' })
const afterUpdate = space.RepoCommit.fromState(repo.setHash.state()).applyOp({ collection: 'my.bulletin.post', rkey: 'second', cid: updated.cid, prev: records[1].cid })

// --- commit: fixed key, ikm, hash
const privateKey = bytes(32)
const keypair = await crypto.Secp256k1Keypair.import(privateKey)
const ctx = { space: 'at://did:plc:vx4ssij3m6dcdrs5yvxxbznq/space/my.bulletin.board/self', author: 'did:plc:j34mp52kqeqheoencw7lqpyy', rev: '3mv4fihuqwc2h' }
const ikm = bytes(32)
const hash = repo.setHash.digest()
const ctxBytes = space.encodeCommitCtx(ctx, ikm)
const mac = crypto.hmacSha256(crypto.hkdfSha256(ikm, ctxBytes), hash)
const sig = await keypair.sign(ctxBytes)
const commit = { ver: 1, hash, ikm, mac, sig, rev: ctx.rev }
if (!(await space.verifyCommit(commit, ctx, keypair.did()))) throw new Error('self-verification failed')
if (await space.verifyCommit(commit, { ...ctx, author: 'did:plc:other' }, keypair.did())) throw new Error('mac not bound')

// --- CAR
const carChunks = []
for await (const chunk of spaceSync.serializeRepo(commit, records)) carChunks.push(chunk)
const car = Buffer.concat(carChunks)
const verified = await spaceSync.verifyRepoCarFull([new Uint8Array(car)], { space: ctx.space, author: ctx.author, didKey: keypair.did() })
if (verified.records.length !== records.length) throw new Error('car round trip')

// --- tokens
const now = Math.floor(Date.now() / 1000)
const delegation = await space.createSpaceToken('delegation', { iss: ctx.author, sub: ctx.space, aud: space.spaceHostAud('did:plc:vx4ssij3m6dcdrs5yvxxbznq') }, keypair)
const credential = await space.createSpaceToken('credential', { iss: 'did:plc:vx4ssij3m6dcdrs5yvxxbznq', sub: ctx.space, dpopJkt: 'NzbLsXh8uDCcd-6MNwXF4W_7noWXFZAfHkxZsRGC9Xs' }, keypair)

const golden = {
  description: 'Spaces alpha primitives from @atproto/space@0.0.0-spaces-alpha-20260818163953 (the bulletin pin): element = collection/rkey/cid; commit ctx = "atproto-space-v1" || len16BE(space) space || len16BE(author) author || len16BE(rev) rev || len16BE(ikm) ikm; mac = HMAC-SHA256(HKDF-Expand-SHA256(ikm, ctx, 32), hash); sig over ctx; two-root CAR with record blocks in canonical index key order; tokens typ atproto-space-{delegation,credential}+jwt',
  records: records.map((r, i) => ({ collection: r.collection, rkey: r.rkey, record: recordsIn[i][2], cid: r.cid.toString(), bytes: hex(r.bytes) })),
  elements,
  steps,
  index: Object.fromEntries(records.map((r) => [`${r.collection}/${r.rkey}`, r.cid.toString()])),
  indexBytes: hex(lexCbor.encode(Object.fromEntries(records.map((r) => [`${r.collection}/${r.rkey}`, r.cid])))),
  state: hex(repo.setHash.state()),
  digest: hex(hash),
  update: { rkey: 'second', record: { $type: 'my.bulletin.post', text: 'two, edited' }, cid: updated.cid.toString(), prev: records[1].cid.toString(), state: hex(afterUpdate.setHash.state()), digest: hex(afterUpdate.setHash.digest()) },
  key: { privateKeyHex: hex(privateKey), did: keypair.did() },
  commit: { ctx, ikm: hex(ikm), hash: hex(hash), ctxBytes: hex(ctxBytes), mac: hex(mac), sig: hex(sig), commitBytes: hex(lexCbor.encode(commit)) },
  car: hex(car),
  tokens: { now, delegation, credential, delegationAud: space.spaceHostAud('did:plc:vx4ssij3m6dcdrs5yvxxbznq') },
}
writeFileSync(new URL('../golden/space/alpha.json', import.meta.url), JSON.stringify(golden, null, 2) + '\n')
console.log('wrote alpha.json:', records.length, 'records, car', car.length, 'bytes')
