// Emit test/golden/cid/vectors.json: block bytes, expected CID (string and
// binary) and the exact tag-42 encoding @ipld/dag-cbor produces for {"x": cid}.
import { encode } from '@ipld/dag-cbor'
import { buildValues } from './values.mjs'
import { b64pad, cidOf, DAG_CBOR, RAW, utf8, writeFile } from './common.mjs'

const values = await buildValues()
const cases = [
  ['dagcbor-empty-map', encode({}), DAG_CBOR],
  ['raw-empty', new Uint8Array(0), RAW],
  ['raw-hello', utf8('hello'), RAW],
  ['dagcbor-mixed', encode(values.mixed), DAG_CBOR],
  ['dagcbor-commit-signed', encode(values['commit-signed']), DAG_CBOR],
  ['dagcbor-mst-node', encode(values['mst-node']), DAG_CBOR],
  ['raw-256-bytes', Uint8Array.from({ length: 256 }, (_, i) => i), RAW],
]

const out = []
for (const [name, bytes, codec] of cases) {
  const cid = await cidOf(bytes, codec)
  out.push({
    name,
    bytesBase64: b64pad(bytes),
    codec: codec === DAG_CBOR ? 'dag-cbor' : 'raw',
    cid: cid.toString(),
    cidBytesBase64: b64pad(cid.bytes),
    tag42Base64: b64pad(encode({ x: cid })),
  })
}
writeFile('cid/vectors.json', JSON.stringify(out, null, 2) + '\n')
console.log(`gen-cid: wrote ${out.length} vectors`)
