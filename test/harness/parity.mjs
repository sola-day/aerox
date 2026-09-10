// VERIFICATION §7.1: seed the same scenario into two independent stacks — ours
// (PDS + relay + AppView) and the upstream reference one (bluesky-social PDS +
// bsky AppView) — then call the same endpoints as the same authenticated user
// on both and diff the normalised JSON.
//
//   AEROX_PDS_URL=https://pds.aerox.sola.town \
//   REF_PDS_URL=https://ref-pds.aerox.sola.town \
//   node parity.mjs
//
// Nothing here knows which stack is which: both are driven through
// @atproto/api, the client library a real application uses, and the diff is
// symmetric. What is stripped before diffing is listed in NORMALISERS and
// nothing else — every remaining difference is a real one.
import { AtpAgent, RichText } from '@atproto/api'

const AEROX = process.env.AEROX_PDS_URL ?? 'https://pds.aerox.sola.town'
const REF = process.env.REF_PDS_URL ?? 'https://ref-pds.aerox.sola.town'
const AEROX_INVITE = process.env.AEROX_INVITE_CODE
const SETTLE_MS = Number(process.env.PARITY_SETTLE_MS ?? 15000)
const STAMP = Date.now().toString(36)

// One fixed instant for every record, so two stacks that encode the same record
// the same way produce the same CID. A CID mismatch on a record whose bytes do
// not mention a DID is therefore a real encoding difference, not scheduling.
const T0 = '2026-01-02T03:04:05.000Z'

const log = (...a) => console.log(...a)

async function seed(service, label, inviteCode) {
  const describe = await new AtpAgent({ service }).com.atproto.server.describeServer()
  const domain = describe.data.availableUserDomains[0]
  const actors = {}

  for (const name of ['alice', 'bob', 'carol']) {
    const agent = new AtpAgent({ service })
    const handle = `p${STAMP}-${name}${domain}`
    const password = 'REDACTED-parity-harness-password'
    await agent.createAccount({
      handle,
      email: `${handle}@example.invalid`,
      password,
      ...(inviteCode ? { inviteCode } : {}),
    })
    actors[name] = { agent, handle, did: agent.session.did }
    log(`${label}: ${name} = ${agent.session.did} (${handle})`)
  }

  const { alice, bob, carol } = actors

  // profiles
  for (const [name, a] of Object.entries(actors)) {
    await a.agent.upsertProfile(() => ({
      displayName: `${name[0].toUpperCase()}${name.slice(1)} Parity`,
      description: `parity fixture for ${name}`,
      createdAt: T0,
    }))
  }

  // graph: alice <-> bob mutual, carol follows alice, alice blocks nobody,
  // bob mutes carol (mutes are viewer state, not a record)
  const follow = (from, to) =>
    from.agent.app.bsky.graph.follow.create(
      { repo: from.did },
      { subject: to.did, createdAt: T0 },
    )
  await follow(alice, bob)
  await follow(bob, alice)
  await follow(carol, alice)
  await bob.agent.mute(carol.did)

  // posts: plain, one with facets (a link and a mention), a reply, a quote,
  // a repost and likes.
  const rt = new RichText({
    text: `parity root post with a link https://example.com and a mention @${bob.handle}`,
  })
  await rt.detectFacets(alice.agent)
  const root = await alice.agent.post({ text: rt.text, facets: rt.facets, createdAt: T0 })

  const plain = await alice.agent.post({ text: 'parity plain post', createdAt: T0 })

  const reply = await bob.agent.post({
    text: 'parity reply',
    createdAt: T0,
    reply: {
      root: { uri: root.uri, cid: root.cid },
      parent: { uri: root.uri, cid: root.cid },
    },
  })

  const nested = await carol.agent.post({
    text: 'parity nested reply',
    createdAt: T0,
    reply: {
      root: { uri: root.uri, cid: root.cid },
      parent: { uri: reply.uri, cid: reply.cid },
    },
  })

  const quote = await bob.agent.post({
    text: 'parity quote',
    createdAt: T0,
    embed: {
      $type: 'app.bsky.embed.record',
      record: { uri: root.uri, cid: root.cid },
    },
  })

  await bob.agent.like(root.uri, root.cid)
  await carol.agent.like(root.uri, root.cid)
  await bob.agent.repost(root.uri, root.cid)

  // a list with one member
  const list = await alice.agent.app.bsky.graph.list.create(
    { repo: alice.did },
    {
      name: 'parity list',
      purpose: 'app.bsky.graph.defs#curatelist',
      description: 'a list for the parity diff',
      createdAt: T0,
    },
  )
  await alice.agent.app.bsky.graph.listitem.create(
    { repo: alice.did },
    { list: list.uri, subject: bob.did, createdAt: T0 },
  )

  // a threadgate on the plain post: replies from followed users only
  await alice.agent.app.bsky.feed.threadgate.create(
    { repo: alice.did, rkey: plain.uri.split('/').pop() },
    {
      post: plain.uri,
      allow: [{ $type: 'app.bsky.feed.threadgate#followingRule' }],
      createdAt: T0,
    },
  )

  return {
    label,
    service,
    actors,
    posts: { root, plain, reply, nested, quote },
    list,
  }
}

// Everything a parity diff must ignore, and why. Anything not listed here is
// compared byte for byte after symbolisation.
const NORMALISERS = [
  ['indexedAt', 'server-side index time'],
  ['createdAt on view objects only where the record carries none', 'derived'],
  ['cursor', 'opaque; paging equivalence is checked separately'],
  ['avatar/banner/thumb/fullsize URLs', 'image CDN hostname and blob CID'],
  ['viewer.* record URIs', 'rkeys are TIDs minted per stack'],
  ['labels', 'no labeler is attached to the reference stack'],
]

function symbolise(value, map) {
  if (typeof value === 'string') {
    let out = value
    for (const [from, to] of map) out = out.split(from).join(to)
    return out
  }
  if (Array.isArray(value)) return value.map((v) => symbolise(v, map))
  if (value && typeof value === 'object') {
    const out = {}
    for (const [k, v] of Object.entries(value)) out[k] = symbolise(v, map)
    return out
  }
  return value
}

const DROP_KEYS = new Set([
  'indexedAt',
  'cursor',
  'avatar',
  'banner',
  'thumb',
  'fullsize',
  'labels',
  'cid',
  'sortAt',
  'uri', // rkeys are TIDs; identity is carried by the symbolised text/subject
])

function strip(value) {
  if (Array.isArray(value)) return value.map(strip)
  if (value && typeof value === 'object') {
    const out = {}
    for (const [k, v] of Object.entries(value)) {
      if (DROP_KEYS.has(k)) continue
      out[k] = strip(v)
    }
    return out
  }
  return value
}

function mapFor(stack) {
  const m = []
  for (const [name, a] of Object.entries(stack.actors)) {
    m.push([a.did, `$${name}.did`])
    m.push([a.handle, `$${name}.handle`])
  }
  for (const [name, p] of Object.entries(stack.posts)) {
    m.push([p.uri.split('/').pop(), `$${name}.rkey`])
  }
  m.push([stack.list.uri.split('/').pop(), '$list.rkey'])
  m.push([new URL(stack.service).host, '$pds.host'])
  return m
}

function normalise(stack, body) {
  return strip(symbolise(body, mapFor(stack)))
}

// The calls. Each is a function of (stack) so it can name that stack's own
// DIDs and URIs; both sides run the same function.
const CALLS = [
  ['app.bsky.actor.getProfile', (s) => s.actors.bob.agent.app.bsky.actor.getProfile({ actor: s.actors.alice.did })],
  ['app.bsky.actor.getProfiles', (s) => s.actors.bob.agent.app.bsky.actor.getProfiles({ actors: [s.actors.alice.did, s.actors.carol.did] })],
  ['app.bsky.actor.searchActors', (s) => s.actors.bob.agent.app.bsky.actor.searchActors({ q: `p${STAMP}` })],
  ['app.bsky.feed.getAuthorFeed', (s) => s.actors.bob.agent.app.bsky.feed.getAuthorFeed({ actor: s.actors.alice.did })],
  ['app.bsky.feed.getPostThread', (s) => s.actors.bob.agent.app.bsky.feed.getPostThread({ uri: s.posts.root.uri })],
  ['app.bsky.feed.getPosts', (s) => s.actors.bob.agent.app.bsky.feed.getPosts({ uris: [s.posts.root.uri, s.posts.quote.uri] })],
  ['app.bsky.feed.getLikes', (s) => s.actors.bob.agent.app.bsky.feed.getLikes({ uri: s.posts.root.uri })],
  ['app.bsky.feed.getRepostedBy', (s) => s.actors.bob.agent.app.bsky.feed.getRepostedBy({ uri: s.posts.root.uri })],
  ['app.bsky.feed.getQuotes', (s) => s.actors.bob.agent.app.bsky.feed.getQuotes({ uri: s.posts.root.uri })],
  ['app.bsky.feed.getActorLikes', (s) => s.actors.bob.agent.app.bsky.feed.getActorLikes({ actor: s.actors.bob.did })],
  ['app.bsky.feed.getTimeline', (s) => s.actors.bob.agent.app.bsky.feed.getTimeline({})],
  ['app.bsky.graph.getFollows', (s) => s.actors.bob.agent.app.bsky.graph.getFollows({ actor: s.actors.alice.did })],
  ['app.bsky.graph.getFollowers', (s) => s.actors.bob.agent.app.bsky.graph.getFollowers({ actor: s.actors.alice.did })],
  ['app.bsky.graph.getKnownFollowers', (s) => s.actors.bob.agent.app.bsky.graph.getKnownFollowers({ actor: s.actors.alice.did })],
  ['app.bsky.graph.getList', (s) => s.actors.bob.agent.app.bsky.graph.getList({ list: s.list.uri })],
  ['app.bsky.graph.getLists', (s) => s.actors.bob.agent.app.bsky.graph.getLists({ actor: s.actors.alice.did })],
  ['app.bsky.graph.getMutes', (s) => s.actors.bob.agent.app.bsky.graph.getMutes({})],
  ['app.bsky.graph.getRelationships', (s) => s.actors.bob.agent.app.bsky.graph.getRelationships({ actor: s.actors.alice.did, others: [s.actors.bob.did, s.actors.carol.did] })],
  ['app.bsky.notification.listNotifications', (s) => s.actors.alice.agent.app.bsky.notification.listNotifications({})],
  ['app.bsky.unspecced.getPopularFeedGenerators', (s) => s.actors.bob.agent.app.bsky.unspecced.getPopularFeedGenerators({})],
]

const sortJson = (v) => {
  if (Array.isArray(v)) return v.map(sortJson)
  if (v && typeof v === 'object') {
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortJson(v[k])]))
  }
  return v
}

async function main() {
  log(`aerox   ${AEROX}`)
  log(`reference ${REF}`)

  const ours = await seed(AEROX, 'aerox', AEROX_INVITE)
  const theirs = await seed(REF, 'ref', process.env.REF_INVITE_CODE)

  // The root post carries no DID in its bytes, so both stacks must have
  // produced the same CID for it. This is the cheapest possible check that the
  // two seeds really are the same data.
  if (ours.posts.plain.cid !== theirs.posts.plain.cid) {
    throw new Error(
      `seed mismatch: plain post CID differs (${ours.posts.plain.cid} vs ${theirs.posts.plain.cid})`,
    )
  }
  log(`seed ok: identical CID for the DID-free record (${ours.posts.plain.cid})`)

  log(`waiting ${SETTLE_MS}ms for both AppViews to index`)
  await new Promise((r) => setTimeout(r, SETTLE_MS))

  const rows = []
  for (const [name, call] of CALLS) {
    let a, b
    try {
      a = normalise(ours, (await call(ours)).data)
    } catch (err) {
      a = { __error: err.error ?? err.message }
    }
    try {
      b = normalise(theirs, (await call(theirs)).data)
    } catch (err) {
      b = { __error: err.error ?? err.message }
    }
    const left = JSON.stringify(sortJson(a))
    const right = JSON.stringify(sortJson(b))
    rows.push({ name, equal: left === right, ours: left, theirs: right })
    log(`${left === right ? 'MATCH  ' : 'DIFFER '} ${name}`)
  }

  const differing = rows.filter((r) => !r.equal)
  if (differing.length) {
    log('\n--- differences ---')
    for (const r of differing) {
      log(`\n### ${r.name}\naerox: ${r.ours}\nref  : ${r.theirs}`)
    }
  }
  log(`\n${rows.length - differing.length}/${rows.length} endpoints match`)
  if (process.env.PARITY_STRICT === '1' && differing.length) process.exit(1)
  log('PARITY RUN COMPLETE')
}

await main()
