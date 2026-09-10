// Builds the backlog the ingest benchmark of VERIFICATION §10.1 replays:
// events spread over many repos, because the AppView's ingest partitions by
// hash(did) — a backlog from one repo lands in one partition and measures
// nothing about partition count.
import { AtpAgent } from '@atproto/api'

const PDS = process.env.AEROX_PDS_URL ?? 'https://aerox.generic.dev'
const INVITE = process.env.AEROX_INVITE_CODE
const ACCOUNTS = Number(process.env.PREFILL_ACCOUNTS ?? 20)
const POSTS = Number(process.env.PREFILL_POSTS ?? 100)
const CONCURRENCY = Number(process.env.PREFILL_CONCURRENCY ?? 20)

const describe = await new AtpAgent({ service: PDS }).com.atproto.server.describeServer()
const domain = describe.data.availableUserDomains[0]
const stamp = Date.now().toString(36)

const agents = []
for (let i = 0; i < ACCOUNTS; i++) {
  const agent = new AtpAgent({ service: PDS })
  const handle = `ing${stamp}${i}${domain}`
  await agent.createAccount({
    handle,
    email: `${handle}@example.invalid`,
    password: 'REDACTED-prefill-password',
    ...(INVITE ? { inviteCode: INVITE } : {}),
  })
  agents.push(agent)
  process.stdout.write(`\raccounts ${agents.length}/${ACCOUNTS}`)
}
console.log()

const start = Date.now()
let done = 0
await Promise.all(
  agents.map(async (agent) => {
    for (let i = 0; i < POSTS; i++) {
      await agent.com.atproto.repo.createRecord({
        repo: agent.session.did,
        collection: 'app.bsky.feed.post',
        record: { $type: 'app.bsky.feed.post', text: `ingest ${stamp} ${i}`, createdAt: new Date().toISOString() },
      })
      done++
      if (done % 100 === 0) process.stdout.write(`\rcommits ${done}/${ACCOUNTS * POSTS}`)
    }
  }),
)
const ms = Date.now() - start
console.log(`\nwrote ${done} commits over ${ACCOUNTS} repos in ${ms}ms (${(done / (ms / 1000)).toFixed(1)}/s)`)
console.log('PREFILL OK')
