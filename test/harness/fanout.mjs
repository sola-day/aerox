// VERIFICATION §10.1, relay row: fan-out to N subscribers and memory per
// subscriber. Opens N `com.atproto.sync.subscribeRepos` sockets against a
// relay, writes a fixed number of commits on a PDS the relay crawls, and
// measures how long the relay takes to deliver every commit to every socket.
//
//   FANOUT_RELAY=wss://relay.aerox.generic.dev \
//   FANOUT_PDS=https://aerox.generic.dev \
//   FANOUT_HANDLE=… FANOUT_PASSWORD=… \
//   FANOUT_SUBS=1000 FANOUT_COMMITS=100 node fanout.mjs
//
// Run it from a *different* machine than the relay: the point is the relay's
// fan-out cost, and a load generator sharing its cores hides exactly that.
import { AtpAgent } from '@atproto/api'
import WebSocket from 'ws'

const RELAY = process.env.FANOUT_RELAY ?? 'wss://relay.aerox.generic.dev'
const PDS = process.env.FANOUT_PDS ?? 'https://aerox.generic.dev'
const HANDLE = process.env.FANOUT_HANDLE
const PASSWORD = process.env.FANOUT_PASSWORD
const SUBS = Number(process.env.FANOUT_SUBS ?? 100)
const COMMITS = Number(process.env.FANOUT_COMMITS ?? 100)
const OPEN_BATCH = Number(process.env.FANOUT_OPEN_BATCH ?? 50)
// live:     write COMMITS commits and time their delivery to every subscriber.
//           Measures that fan-out is complete, but the rate is the writer's.
// backfill: put PREFILL commits in the relay first, then have every subscriber
//           replay from cursor 0 at once. That is the relay's own fan-out rate:
//           serialise once per event, write once per subscriber.
const MODE = process.env.FANOUT_MODE ?? 'live'
const PREFILL = Number(process.env.FANOUT_PREFILL ?? 500)
const WRITE_CONCURRENCY = Number(process.env.FANOUT_WRITE_CONCURRENCY ?? 16)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// Frame counting only: decoding 1 000 × N DAG-CBOR frames in the load
// generator would measure the load generator. A frame that arrives is a frame
// the relay serialised and wrote, which is the cost under test.
function openSub(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { perMessageDeflate: false })
    ws.frames = 0
    ws.bytes = 0
    ws.on('message', (m) => { ws.frames++; ws.bytes += m.length; ws.lastAt = Date.now() })
    ws.on('open', () => resolve(ws))
    ws.on('error', reject)
  })
}

// Commits, not records: one createRecord is one commit is one firehose event.
// Sequential writes measure the round trip to the PDS, so the prefill runs a
// small window of them in parallel — the repo lock serialises them anyway.
async function writeCommits(agent, n, concurrency, label) {
  const start = Date.now()
  let next = 0
  const worker = async () => {
    while (true) {
      const i = next++
      if (i >= n) return
      await agent.com.atproto.repo.createRecord({
        repo: agent.session.did,
        collection: 'app.bsky.feed.post',
        record: { $type: 'app.bsky.feed.post', text: `${label} ${i}`, createdAt: new Date().toISOString() },
      })
    }
  }
  await Promise.all(Array.from({ length: concurrency }, worker))
  const ms = Date.now() - start
  console.log(`wrote ${n} commits in ${ms}ms (${(n / (ms / 1000)).toFixed(1)}/s, ${concurrency} in flight)`)
  return ms
}

async function backfill(agent) {
  const cursorUrl = `${RELAY}/xrpc/com.atproto.sync.subscribeRepos`
  await writeCommits(agent, PREFILL, WRITE_CONCURRENCY, 'prefill')

  // Let the relay finish ingesting before the replay starts. The backlog size
  // is whatever the relay decided to keep — it renumbers events and does not
  // forward everything its upstream sent — so the target is what a subscriber
  // actually receives, and the assertion is that every subscriber receives the
  // same number. The upstream host's seq is printed only as a sanity check.
  await sleep(5000)
  const status = await fetch(
    `${RELAY.replace(/^ws/, 'http')}/xrpc/com.atproto.sync.getHostStatus?hostname=${new URL(PDS).host}`,
  ).then((r) => r.json())
  console.log(`upstream host seq=${status.seq}; replaying the relay's backlog to ${SUBS} subscribers from cursor 0`)

  const t0 = Date.now()
  const socks = []
  for (let i = 0; i < SUBS; i += OPEN_BATCH) {
    const batch = []
    for (let j = i; j < Math.min(i + OPEN_BATCH, SUBS); j++) {
      batch.push(openSub(`${cursorUrl}?cursor=0`))
    }
    socks.push(...(await Promise.all(batch)))
  }
  const connectMs = Date.now() - t0

  // Done when every socket has stopped growing for a full second.
  let last = -1
  let stableSince = Date.now()
  const deadline = Date.now() + 300000
  while (Date.now() < deadline) {
    const total = socks.reduce((n, s) => n + s.frames, 0)
    if (total !== last) { last = total; stableSince = Date.now() }
    else if (Date.now() - stableSince > 2000) break
    await sleep(200)
  }
  // The run is over when the last frame lands, not when the stability window
  // expires: the wait is detection, not work.
  const lastAt = Math.max(...socks.map((s) => s.lastAt ?? t0))
  const elapsed = lastAt - t0
  const frames = socks.reduce((n, s) => n + s.frames, 0)
  const bytes = socks.reduce((n, s) => n + s.bytes, 0)
  const target = Math.max(...socks.map((s) => s.frames))
  const complete = socks.filter((s) => s.frames === target).length

  console.log(JSON.stringify({
    mode: 'backfill',
    subscribers: SUBS,
    backlogFrames: target,
    framesDelivered: frames,
    framesExpected: SUBS * target,
    subscribersComplete: complete,
    connectMs,
    elapsedMs: elapsed,
    frameRate: Math.round(frames / (elapsed / 1000)),
    mbytesPerSecond: +(bytes / (elapsed / 1000) / 1e6).toFixed(1),
  }, null, 2))

  for (const s of socks) s.close()
  if (complete < SUBS) {
    console.log(`INCOMPLETE: ${SUBS - complete} subscribers received fewer than ${target} frames`)
    process.exit(2)
  }
  console.log('FANOUT OK')
}

async function main() {
  const agent = new AtpAgent({ service: PDS })
  await agent.login({ identifier: HANDLE, password: PASSWORD })

  // Start every subscriber at the relay's current head so the run measures
  // live fan-out, not backfill.
  const head = await fetch(`${RELAY.replace(/^ws/, 'http')}/xrpc/com.atproto.sync.getLatestCommit?did=${agent.session.did}`)
    .then((r) => (r.ok ? r.json() : null))
    .catch(() => null)
  const cursorUrl = `${RELAY}/xrpc/com.atproto.sync.subscribeRepos`
  console.log(`relay ${RELAY} head=${head ? head.rev : 'unknown'} subs=${SUBS} commits=${COMMITS}`)

  if (MODE === 'backfill') return backfill(agent)

  const socks = []
  const t0 = Date.now()
  for (let i = 0; i < SUBS; i += OPEN_BATCH) {
    const batch = []
    for (let j = i; j < Math.min(i + OPEN_BATCH, SUBS); j++) batch.push(openSub(cursorUrl))
    socks.push(...(await Promise.all(batch)))
    process.stdout.write(`\ropened ${socks.length}/${SUBS}`)
  }
  console.log(`\nconnected in ${Date.now() - t0}ms`)

  await sleep(2000)
  const before = socks.reduce((n, s) => n + s.frames, 0)

  const writeStart = Date.now()
  await writeCommits(agent, COMMITS, 1, 'fanout')

  // Wait until every socket has seen COMMITS more frames, or give up.
  const deadline = Date.now() + 120000
  let delivered = 0
  while (Date.now() < deadline) {
    delivered = socks.reduce((n, s) => n + s.frames, 0) - before
    if (delivered >= SUBS * COMMITS) break
    await sleep(100)
  }
  const elapsed = Date.now() - writeStart
  const complete = socks.filter((s) => s.frames >= COMMITS).length

  console.log(JSON.stringify({
    subscribers: SUBS,
    commits: COMMITS,
    framesDelivered: delivered,
    framesExpected: SUBS * COMMITS,
    subscribersComplete: complete,
    elapsedMs: elapsed,
    frameRate: Math.round(delivered / (elapsed / 1000)),
  }, null, 2))

  for (const s of socks) s.close()
  if (delivered < SUBS * COMMITS) {
    console.log('INCOMPLETE: not every subscriber saw every commit within the deadline')
    process.exit(2)
  }
  console.log('FANOUT OK')
}

await main()
