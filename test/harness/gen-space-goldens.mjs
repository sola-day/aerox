// Generates test/golden/space/*.json from the alpha Spaces primitives
// (packages/space at permissioned-data @a90c3695): LtHash (blake3 XOF over
// 1024 little-endian uint16 lanes, add/remove mod 2^16, sha256 digest) and
// the commit MAC (HKDF-SHA256(ikm, info) then HMAC-SHA256 over the hash).
// Uses @noble/hashes exactly as upstream does. Provenance in MANIFEST.json.
import { blake3 } from '@noble/hashes/blake3'
import { sha256 } from '@noble/hashes/sha256'
import { hkdf } from '@noble/hashes/hkdf'
import { hmac } from '@noble/hashes/hmac'
import { writeFileSync } from 'node:fs'

const LANES = 1024, STATE_BYTES = 2048
const expand = (el) => new Uint16Array(blake3(new TextEncoder().encode(el), { dkLen: STATE_BYTES }).buffer.slice(0))
class LtHash {
  constructor(init) { const buf = new ArrayBuffer(STATE_BYTES); this.bytes = new Uint8Array(buf); this.lanes = new Uint16Array(buf); if (init) this.bytes.set(init) }
  add(el) { const l = expand(el); for (let i = 0; i < LANES; i++) this.lanes[i] += l[i] }
  remove(el) { const l = expand(el); for (let i = 0; i < LANES; i++) this.lanes[i] -= l[i] }
  hex() { return Buffer.from(this.bytes).toString('hex') }
  digest() { return Buffer.from(sha256(this.bytes)).toString('hex') }
}
const hex = (b) => Buffer.from(b).toString('hex')

const elements = [
  'app.bsky.feed.post/3k2a4b5c6d7e8:bafyreid6dzyqk2c7zjmrric22uvngomxomc36pgmwurewgwp7tn22pt6vi',
  'my.bulletin.post/3k2a4b5c6d7e9:bafyreih7zk4zdiqawogrvomgqlp4vgx2zpfjhpm5xfiqal2jfoguqavewu',
  'my.bulletin.note/abc:bafyreia2ju6nxr53nnjjgiwojrfanisxfwey4gutirz37aamxpedfsz36u',
  '',
  '日本語/キー:bafkreiccldh766hwcnuxnf2wh6jgzepf2nlu2lvcllt63eww5p6chi4ity',
]
const lthash = { description: 'LtHash states after each step; expand = blake3 XOF 2048 bytes as LE uint16 lanes', empty: new LtHash().hex(), emptyDigest: new LtHash().digest(), expansions: elements.map((e) => ({ element: e, expansion: hex(blake3(new TextEncoder().encode(e), { dkLen: STATE_BYTES })) })), steps: [] }
const h = new LtHash()
const script = [['add', 0], ['add', 1], ['add', 2], ['remove', 1], ['add', 3], ['add', 4], ['add', 1], ['remove', 0], ['remove', 2], ['remove', 3], ['remove', 4], ['remove', 1]]
for (const [op, i] of script) { h[op](elements[i]); lthash.steps.push({ op, element: elements[i], state: h.hex(), digest: h.digest() }) }
// order independence: add in reverse yields the same state
const r = new LtHash(); for (const e of [...elements].reverse()) r.add(e)
const f = new LtHash(); for (const e of elements) f.add(e)
lthash.orderIndependent = { forward: f.hex(), reverse: r.hex(), equal: f.hex() === r.hex() }
// wraparound: adding the same element 70000 times wraps lanes mod 2^16 — use 3 for speed and a lane check
const w = new LtHash(); for (let i = 0; i < 3; i++) w.add(elements[0])
lthash.tripleAdd = { element: elements[0], state: w.hex() }
writeFileSync('../golden/space/lthash.json', JSON.stringify(lthash, null, 2) + '\n')

const DOMAIN = Buffer.from('atproto-space-v1')
const encodeInfo = (space) => { const parts = [DOMAIN]; for (const f of [space.spaceDid, space.spaceType, space.spaceKey, space.userDid, space.rev, space.scope]) { const b = Buffer.from(f); const len = Buffer.alloc(2); len.writeUInt16BE(b.length); parts.push(len, b) } return Buffer.concat(parts) }
const contexts = [
  { spaceDid: 'did:plc:vx4ssij3m6dcdrs5yvxxbznq', spaceType: 'com.atproto.simplespace', spaceKey: 'team', userDid: 'did:plc:j34mp52kqeqheoencw7lqpyy', rev: '3mv4fihuqwc2h', scope: 'records' },
  { spaceDid: 'did:web:example.com', spaceType: 'my.bulletin.space', spaceKey: 'x', userDid: 'did:plc:vx4ssij3m6dcdrs5yvxxbznq', rev: '3mv4fihuqwc2i', scope: 'members' },
  { spaceDid: 'did:plc:aaaaaaaaaaaaaaaaaaaaaaaa', spaceType: 'com.atproto.simplespace', spaceKey: '日本語', userDid: 'did:plc:bbbbbbbbbbbbbbbbbbbbbbbb', rev: '3mv4fihuqwc2j', scope: 'records' },
]
const commits = { description: 'commit MAC: info = "atproto-space-v1" ‖ len16BE-prefixed [spaceDid, spaceType, spaceKey, userDid, rev, scope]; key = HKDF-SHA256(ikm, salt=empty, info, 32); mac = HMAC-SHA256(key, hash)', vectors: [] }
let seed = 1
const bytes = (n) => Buffer.from(Array.from({ length: n }, () => (seed = (seed * 16807) % 2147483647) & 0xff))
for (const space of contexts) {
  const ikm = bytes(32), hash = bytes(32)
  const info = encodeInfo(space)
  const key = hkdf(sha256, ikm, undefined, info, 32)
  const mac = hmac(sha256, key, hash)
  commits.vectors.push({ space, ikm: hex(ikm), hash: hex(hash), info: hex(info), derivedKey: hex(key), mac: hex(mac) })
}
writeFileSync('../golden/space/commit.json', JSON.stringify(commits, null, 2) + '\n')
console.log('wrote lthash.json (', lthash.steps.length, 'steps ) and commit.json (', commits.vectors.length, 'vectors )')
