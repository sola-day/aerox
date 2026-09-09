// Shared helpers for the golden generators.
import { CID } from 'multiformats/cid'
import { sha256 } from 'multiformats/hashes/sha2'
import * as fs from 'node:fs'
import * as path from 'node:path'

export const DAG_CBOR = 0x71
export const RAW = 0x55

// Repo root = three levels up from tools/golden/ts/
export const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..', '..')
export const GOLDEN = path.join(ROOT, 'test', 'golden')

export async function cidOf(bytes, codec = DAG_CBOR) {
  return CID.createV1(codec, await sha256.digest(bytes))
}

export const utf8 = (s) => new TextEncoder().encode(s)

// Standard alphabet, no padding (atproto JSON `$bytes` form).
export const b64 = (u8) => Buffer.from(u8).toString('base64').replace(/=+$/, '')
// Standard alphabet, padded (used for the CID vectors file).
export const b64pad = (u8) => Buffer.from(u8).toString('base64')

// Convert a JS value (with CID instances and Uint8Array) into atproto JSON form.
export function toAtprotoJson(v) {
  if (v === null || typeof v === 'boolean' || typeof v === 'number' || typeof v === 'string') return v
  if (v instanceof CID) return { $link: v.toString() }
  if (v instanceof Uint8Array) return { $bytes: b64(v) }
  if (Array.isArray(v)) return v.map(toAtprotoJson)
  if (typeof v === 'object') {
    const out = {}
    for (const k of Object.keys(v)) out[k] = toAtprotoJson(v[k])
    return out
  }
  throw new Error(`unsupported value: ${v}`)
}

export function writeFile(rel, data) {
  const p = path.join(GOLDEN, rel)
  fs.mkdirSync(path.dirname(p), { recursive: true })
  fs.writeFileSync(p, data)
  return rel
}
