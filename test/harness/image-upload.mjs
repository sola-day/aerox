// Uploads the fixtures the image-CDN benchmark of VERIFICATION §10.1 works on
// and prints the CDN URLs for them, one per line, for `oha --urls-from-file`.
import fs from 'node:fs'
import path from 'node:path'
import { AtpAgent } from '@atproto/api'

const PDS = process.env.AEROX_PDS_URL ?? 'https://aerox.generic.dev'
const APPVIEW = process.env.AEROX_APPVIEW_URL ?? 'https://appview.aerox.generic.dev'
const DIR = process.env.IMG_DIR
const HANDLE = process.env.AEROX_HANDLE
const PASSWORD = process.env.AEROX_PASSWORD
const PRESET = process.env.IMG_PRESET ?? 'feed_fullsize'

const agent = new AtpAgent({ service: PDS })
await agent.login({ identifier: HANDLE, password: PASSWORD })

const files = fs.readdirSync(DIR).filter((f) => f.endsWith('.jpg')).sort()
const urls = []
const blobs = []
for (const f of files) {
  const bytes = fs.readFileSync(path.join(DIR, f))
  const res = await agent.com.atproto.repo.uploadBlob(bytes, { encoding: 'image/jpeg' })
  blobs.push(res.data.blob)
  urls.push(`${APPVIEW}/img/${PRESET}/plain/${agent.session.did}/${res.data.blob.ref.toString()}@jpeg`)
  process.stdout.write(`\ruploaded ${urls.length}/${files.length}`)
}
console.error()

// An uploaded blob that no record references is not served by getBlob, so the
// CDN's origin fetch 404s. Referencing them in posts is what a real client
// does and what makes the fixtures fetchable.
for (let i = 0; i < blobs.length; i += 4) {
  const images = blobs.slice(i, i + 4).map((image) => ({ image, alt: 'bench fixture' }))
  await agent.post({
    text: `image bench fixtures ${i / 4}`,
    createdAt: new Date().toISOString(),
    embed: { $type: 'app.bsky.embed.images', images },
  })
}
console.error(`referenced ${blobs.length} blobs from ${Math.ceil(blobs.length / 4)} posts`)
fs.writeFileSync(process.env.URL_FILE ?? '/tmp/img-urls.txt', urls.join('\n') + '\n')
console.error(`did ${agent.session.did}`)
console.error(`wrote ${urls.length} urls to ${process.env.URL_FILE ?? '/tmp/img-urls.txt'}`)
