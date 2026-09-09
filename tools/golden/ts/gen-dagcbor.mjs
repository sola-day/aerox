// Emit test/golden/dagcbor/<name>.{json,cbor,cid} for every value in values.mjs.
import { encode } from '@ipld/dag-cbor'
import { buildValues } from './values.mjs'
import { cidOf, toAtprotoJson, writeFile } from './common.mjs'

const values = await buildValues()
const written = []
for (const [name, value] of Object.entries(values)) {
  const bytes = encode(value)
  const cid = await cidOf(bytes)
  written.push(writeFile(`dagcbor/${name}.json`, JSON.stringify(toAtprotoJson(value), null, 2) + '\n'))
  written.push(writeFile(`dagcbor/${name}.cbor`, bytes))
  written.push(writeFile(`dagcbor/${name}.cid`, cid.toString()))
}
console.log(`gen-dagcbor: wrote ${written.length} files`)
