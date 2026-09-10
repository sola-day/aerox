// The restore drill's acceptance (VERIFICATION §10.4, docs/OPS.md §3): against
// a server booted on the *restored* databases and blob store, an existing
// account logs in with its restored password hash, its records read back, a
// new write commits on top of the restored repo, and the repo CAR is served.
// AEROX_PDS_URL, HANDLE, PASSWORD.
import { AtpAgent } from '@atproto/api'
const service = process.env.AEROX_PDS_URL ?? 'http://172.18.0.1:4001'
const agent = new AtpAgent({ service })
await agent.login({ identifier: process.env.HANDLE ?? 'alice.aerox.sola.town', password: process.env.PASSWORD ?? 'REDACTED-peer-account-password-rotated-2026-09-16' })
console.log('login on restored stack', agent.session.did)
const before = await agent.com.atproto.repo.listRecords({ repo: agent.session.did, collection: 'app.bsky.feed.post', limit: 5 })
console.log('restored posts visible', before.data.records.length)
const latest = await agent.com.atproto.sync.getLatestCommit({ did: agent.session.did })
const post = await agent.post({ text: 'written on the restored stack', createdAt: new Date().toISOString() })
const got = await agent.com.atproto.repo.getRecord({ repo: agent.session.did, collection: 'app.bsky.feed.post', rkey: post.uri.split('/').pop() })
if (got.data.cid !== post.cid) throw new Error('read-back mismatch')
const after = await agent.com.atproto.sync.getLatestCommit({ did: agent.session.did })
if (after.data.rev <= latest.data.rev) throw new Error('rev did not advance')
const car = await fetch(`${service}/xrpc/com.atproto.sync.getRepo?did=${agent.session.did}`)
console.log('getRepo', car.status, (await car.arrayBuffer()).byteLength, 'bytes; rev', latest.data.rev, '→', after.data.rev)
console.log('RESTORE OK')
