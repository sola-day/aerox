// The smallest possible proof that the stack answers an upstream client:
// describeServer, createAccount, createSession, a post, a read, and the
// firehose, all through @atproto/api. AEROX_PDS_URL defaults to the dev stack;
// AEROX_INVITE_CODE is required against a deployment that runs with
// INVITES_REQUIRED (as the release drill on the second host does).
import { AtpAgent } from '@atproto/api'
import WebSocket from 'ws'

const service = process.env.AEROX_PDS_URL ?? 'https://aerox.sola.town'
const agent = new AtpAgent({ service })
const res = await agent.com.atproto.server.describeServer()
if (!res.success) throw new Error(`describeServer failed: ${res.status}`)
console.log('describeServer', JSON.stringify(res.data))

const domain = res.data.availableUserDomains[0]
const handle = `smoke-${Date.now().toString(36)}${domain}`
const password = 'REDACTED-smoke-harness-password'
const created = await agent.createAccount({
  handle,
  email: `${handle}@example.invalid`,
  password,
  ...(process.env.AEROX_INVITE_CODE ? { inviteCode: process.env.AEROX_INVITE_CODE } : {}),
})
console.log('createAccount', created.data.did, created.data.handle)

const agent2 = new AtpAgent({ service })
await agent2.login({ identifier: handle, password })
console.log('login', agent2.session?.did, agent2.session?.handle)

const post = await agent2.post({ text: 'hello from the aerox smoke harness', createdAt: new Date().toISOString() })
console.log('post', post.uri, post.cid)

const rkey = post.uri.split('/').pop()
const got = await agent2.com.atproto.repo.getRecord({ repo: agent2.session.did, collection: 'app.bsky.feed.post', rkey })
if (got.data.cid !== post.cid) throw new Error('getRecord cid mismatch')
console.log('getRecord ok')

const prefs = await agent2.app.bsky.actor.getPreferences()
console.log('getPreferences', JSON.stringify(prefs.data))

const repo = await agent2.com.atproto.sync.getRepo({ did: agent2.session.did })
console.log('getRepo bytes', repo.data.byteLength)

// firehose: read frames from cursor 0 until we see our own commit
const wsUrl = service.replace(/^http/, 'ws') + '/xrpc/com.atproto.sync.subscribeRepos?cursor=0'
await new Promise((resolve, reject) => {
  const ws = new WebSocket(wsUrl)
  let n = 0
  const timer = setTimeout(() => { ws.close(); reject(new Error('firehose: no commit seen')) }, 10000)
  let done = false
  ws.on('message', (data) => {
    if (done) return
    n++
    // cheap check: the frame body carries the did as a text string
    if (data.toString('latin1').includes(agent2.session.did)) {
      console.log(`firehose: saw our did after ${n} frames`)
      done = true; clearTimeout(timer); ws.close(); resolve()
    }
  })
  ws.on('error', reject)
})
console.log('SMOKE OK')
