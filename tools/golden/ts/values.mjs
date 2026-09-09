// The fixed list of named DAG-CBOR test values. Built as real JS values with
// CID instances (multiformats) and Uint8Array bytes so that tag 42 with the
// leading 0x00 multibase-identity byte, and CBOR major type 2, are exercised.
import { CID } from 'multiformats/cid'
import { cidOf, RAW, utf8 } from './common.mjs'

const LEAF = CID.parse('bafyreie5cvv4h45feadgeuwhbcutmh6t2ceseocckahdoe6uat64zmz454')

export async function buildValues() {
  const rawHello = await cidOf(utf8('hello'), RAW)
  const blobCid = await cidOf(utf8('a blob'), RAW)
  const dataCid = await cidOf(utf8('mst root'))

  const ints = {}
  for (const n of [0, 1, 23, 24, 255, 256, 65535, 65536, 4294967295, 4294967296, 9007199254740991]) ints[`i${n}`] = n
  for (const n of [1, 24, 25, 256, 257, 65536, 65537, 4294967296, 4294967297, 9007199254740991]) ints[`n${n}`] = -n

  const long = new Uint8Array(300)
  for (let i = 0; i < 300; i++) long[i] = i & 0xff
  const sig = new Uint8Array(64)
  for (let i = 0; i < 64; i++) sig[i] = i

  const mixed = {
    $type: 'app.bsky.feed.post',
    text: '你好世界 hello from aerox 😀',
    createdAt: '2026-09-09T12:00:00.000Z',
    langs: ['zh', 'en'],
    embed: {
      $type: 'app.bsky.embed.images',
      images: [
        {
          alt: 'an image',
          image: { $type: 'blob', ref: blobCid, mimeType: 'image/jpeg', size: 1234 },
          aspectRatio: { width: 4, height: 3 },
        },
      ],
    },
    facets: [
      {
        index: { byteStart: 13, byteEnd: 18 },
        features: [{ $type: 'app.bsky.richtext.facet#link', uri: 'https://example.com' }],
      },
      {
        index: { byteStart: 24, byteEnd: 29 },
        features: [{ $type: 'app.bsky.richtext.facet#tag', tag: 'aerox' }],
      },
    ],
  }

  const nest = (depth) => (depth === 0 ? { leaf: 'bottom' } : depth % 2 === 0 ? { d: depth, in: [nest(depth - 1)] } : { d: depth, in: nest(depth - 1) })

  const commitUnsigned = {
    did: 'did:plc:ewvi7nxzyoun6zhxrhs64oiz',
    version: 3,
    data: dataCid,
    rev: '3jqfcqzm3fo2j',
    prev: null,
  }

  return {
    'empty-map': {},
    'empty-array': [],
    null: { a: null },
    bools: { t: true, f: false },
    'ints-boundaries': ints,
    strings: {
      ascii: 'hello, world',
      empty: '',
      s24: 'x'.repeat(24),
      s256: 'y'.repeat(256),
      s65536: 'z'.repeat(65536),
      cjk: '你好世界',
      emoji: '😀',
      combining: 'éä́', // e + acute; a + diaeresis + acute
    },
    'key-ordering': { b: 1, a: 2, aa: 3, ab: 4, ba: 5, abc: 6, aaa: 7, z: 8, aZ: 9, Aa: 10 },
    nested: nest(10),
    bytes: { b: new Uint8Array(32), e: new Uint8Array(0), s: new Uint8Array([0xff]), long },
    'cid-link': { link: LEAF, raw: rawHello },
    mixed,
    'mst-node': {
      l: null,
      e: [
        { p: 0, k: utf8('app.bsky.feed.post/3jqfcqzm3fo2j'), v: LEAF, t: null },
        { p: 19, k: utf8('3jqfcqzm3fp2j'), v: LEAF, t: null },
      ],
    },
    'commit-unsigned': commitUnsigned,
    'commit-signed': { ...commitUnsigned, sig },
  }
}
