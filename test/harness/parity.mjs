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
import { AtpAgent } from '@atproto/api'

const AEROX = process.env.AEROX_PDS_URL ?? 'https://pds.aerox.sola.town'
const REF = process.env.REF_PDS_URL ?? 'https://ref-pds.aerox.sola.town'
const AEROX_INVITE = process.env.AEROX_INVITE_CODE
const SETTLE_MS = Number(process.env.PARITY_SETTLE_MS ?? 15000)
const STAMP = Date.now().toString(36)

// Fixed instants, so two stacks that encode the same record the same way produce
// the same CID: a CID mismatch on a record whose bytes mention no DID is then a
// real encoding difference rather than scheduling. They also have to be
// *distinct and increasing*, because a feed is ordered by the record's own
// timestamp and a pile of records sharing one instant leaves the order to
// whichever server indexed what first — which is not a difference in anything.
const T0 = '2026-01-02T03:04:05.000Z'
let tick = 0
const at = () => new Date(Date.parse(T0) + 1000 * tick++).toISOString()

const log = (...a) => console.log(...a)

async function seed(service, label, inviteCode) {
  // The same sequence of instants for both stacks.
  tick = 0

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
      createdAt: at(),
    }))
  }

  // graph: alice <-> bob mutual, carol follows alice, alice blocks nobody,
  // bob mutes carol (mutes are viewer state, not a record)
  const follow = (from, to) =>
    from.agent.app.bsky.graph.follow.create(
      { repo: from.did },
      { subject: to.did, createdAt: at() },
    )
  await follow(alice, bob)
  await follow(bob, alice)
  await follow(carol, alice)
  await bob.agent.mute(carol.did)

  // Posts: plain, one with facets (a link and a mention), a reply, a quote, a
  // repost and likes.
  //
  // The facets are built by hand rather than by `RichText.detectFacets`, and
  // the mention's text is a fixed word rather than the handle: handles differ
  // between the two stacks, so a handle in the text would make the *text* and
  // every facet byte range downstream of it differ, and every endpoint that
  // returns this post would read as a difference in aerox.
  const text = 'parity root post, a link https://example.com and a mention @mention'
  const linkStart = text.indexOf('https://example.com')
  const mentionStart = text.indexOf('@mention')
  const root = await alice.agent.post({
    text,
    createdAt: at(),
    facets: [
      {
        index: { byteStart: linkStart, byteEnd: linkStart + 'https://example.com'.length },
        features: [{ $type: 'app.bsky.richtext.facet#link', uri: 'https://example.com' }],
      },
      {
        index: { byteStart: mentionStart, byteEnd: mentionStart + '@mention'.length },
        features: [{ $type: 'app.bsky.richtext.facet#mention', did: bob.did }],
      },
    ],
  })

  const plain = await alice.agent.post({ text: 'parity plain post', createdAt: at() })

  const reply = await bob.agent.post({
    text: 'parity reply',
    createdAt: at(),
    reply: {
      root: { uri: root.uri, cid: root.cid },
      parent: { uri: root.uri, cid: root.cid },
    },
  })

  const nested = await carol.agent.post({
    text: 'parity nested reply',
    createdAt: at(),
    reply: {
      root: { uri: root.uri, cid: root.cid },
      parent: { uri: reply.uri, cid: reply.cid },
    },
  })

  const quote = await bob.agent.post({
    text: 'parity quote',
    createdAt: at(),
    embed: {
      $type: 'app.bsky.embed.record',
      record: { uri: root.uri, cid: root.cid },
    },
  })

  // `agent.like`/`agent.repost` stamp their own `createdAt`, which then shows up
  // as a difference in every view that returns the record. Write them directly
  // at the fixed instant instead.
  const subject = { uri: root.uri, cid: root.cid }
  await bob.agent.app.bsky.feed.like.create({ repo: bob.did }, { subject, createdAt: at() })
  await carol.agent.app.bsky.feed.like.create({ repo: carol.did }, { subject, createdAt: at() })
  await bob.agent.app.bsky.feed.repost.create({ repo: bob.did }, { subject, createdAt: at() })

  // a list with one member
  const list = await alice.agent.app.bsky.graph.list.create(
    { repo: alice.did },
    {
      name: 'parity list',
      purpose: 'app.bsky.graph.defs#curatelist',
      description: 'a list for the parity diff',
      createdAt: at(),
    },
  )
  await alice.agent.app.bsky.graph.listitem.create(
    { repo: alice.did },
    { list: list.uri, subject: bob.did, createdAt: at() },
  )

  // a threadgate on the plain post: replies from followed users only
  await alice.agent.app.bsky.feed.threadgate.create(
    { repo: alice.did, rkey: plain.uri.split('/').pop() },
    {
      post: plain.uri,
      allow: [{ $type: 'app.bsky.feed.threadgate#followingRule' }],
      createdAt: at(),
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
  ['indexedAt / sortAt', 'server-side index time'],
  ['cursor', 'opaque; paging equivalence is checked separately'],
  ['avatar/banner/thumb/fullsize URLs', 'image CDN hostname and blob CID'],
  ['cid', 'a record embedding a URI embeds a DID, so its bytes differ by stack'],
  ['record keys inside at:// URIs', 'TIDs are minted per stack'],
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
  'indexedAt', // when the AppView saw it
  'cursor', // opaque
  'avatar', // image CDN host + blob cid
  'banner',
  'thumb',
  'fullsize',
  'labels', // no labeler is attached to the reference stack
  'cid', // a record that embeds a URI embeds a DID, so its bytes differ
  'sortAt',
  'seenAt', // the server's clock at the moment of the call
])

// Record keys are TIDs minted at write time, so the same record has a different
// rkey in each stack. The rest of an at:// URI — the DID and the collection —
// is comparable, and the five posts the scenario keeps a handle on are mapped
// to their own symbols before this runs; this catches everything else (follows,
// likes, reposts, list items).
const TID = /\/[a-z2-7]{13}(?![a-z2-7])/g
function normaliseTids(value) {
  if (typeof value === 'string') return value.startsWith('at://') ? value.replace(TID, '/$tid') : value
  if (Array.isArray(value)) return value.map(normaliseTids)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, normaliseTids(v)]))
  }
  return value
}

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
  return normaliseTids(strip(symbolise(body, mapFor(stack))))
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
  // DESIGN §15.4 says ours returns an empty list on purpose; the diff is where
  // that deviation shows up rather than something anyone has to remember.
  ['app.bsky.actor.getSuggestions', (s) => s.actors.bob.agent.app.bsky.actor.getSuggestions({})],
  ['app.bsky.feed.getFeed (no generator)', (s) => s.actors.bob.agent.app.bsky.feed.getFeedGenerators({ feeds: [] })],
]

// A whole-body dump answers "are they the same?" and nothing else. What a
// parity run has to produce is *which field* differs, because that is the bug
// report: one missing key repeated in every actor view reads as twenty broken
// endpoints until you see the path.
function diffPaths(a, b, path = '$', out = []) {
  if (out.length > 400) return out
  const ta = a === null ? 'null' : Array.isArray(a) ? 'array' : typeof a
  const tb = b === null ? 'null' : Array.isArray(b) ? 'array' : typeof b
  if (ta !== tb) {
    out.push({ path, ours: preview(a), theirs: preview(b) })
    return out
  }
  if (ta === 'array') {
    if (a.length !== b.length) out.push({ path: `${path}.length`, ours: a.length, theirs: b.length })
    for (let i = 0; i < Math.min(a.length, b.length); i++) diffPaths(a[i], b[i], `${path}[${i}]`, out)
    return out
  }
  if (ta === 'object') {
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
      if (!(k in a)) out.push({ path: `${path}.${k}`, ours: '(absent)', theirs: preview(b[k]) })
      else if (!(k in b)) out.push({ path: `${path}.${k}`, ours: preview(a[k]), theirs: '(absent)' })
      else diffPaths(a[k], b[k], `${path}.${k}`, out)
    }
    return out
  }
  if (a !== b) out.push({ path, ours: preview(a), theirs: preview(b) })
  return out
}

const preview = (v) => {
  const s = typeof v === 'string' ? v : JSON.stringify(v)
  return s === undefined ? String(v) : s.length > 80 ? s.slice(0, 77) + '…' : s
}

// Collapse `$.feed[3].post.author.associated` and its siblings into one row:
// the same missing field under every array index is one difference, not five.
const shape = (path) => path.replace(/\[\d+\]/g, '[]')

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
    const left = sortJson(a)
    const right = sortJson(b)
    const equal = JSON.stringify(left) === JSON.stringify(right)
    const diffs = equal ? [] : diffPaths(left, right)
    rows.push({ name, equal, diffs })
    log(`${equal ? 'MATCH  ' : 'DIFFER '} ${name}${equal ? '' : ` (${diffs.length})`}`)

    // PARITY_DUMP=<endpoint>: print both normalised bodies. A structural diff
    // aligns by index, so when the two sides hold the same items in a different
    // order — or one holds an item the other does not — every row after the
    // first is noise and only the raw pair says what actually happened.
    if (process.env.PARITY_DUMP && name.includes(process.env.PARITY_DUMP)) {
      log(`\n--- ${name} (aerox) ---\n${JSON.stringify(left, null, 1)}`)
      log(`\n--- ${name} (ref) ---\n${JSON.stringify(right, null, 1)}`)
    }
  }

  const differing = rows.filter((r) => !r.equal)
  if (differing.length) {
    log('\n--- differences by endpoint ---')
    for (const r of differing) {
      log(`\n### ${r.name}`)
      const seen = new Set()
      for (const d of r.diffs) {
        const key = shape(d.path)
        if (seen.has(key)) continue
        seen.add(key)
        log(`  ${key}\n    aerox: ${d.ours}\n    ref  : ${d.theirs}`)
      }
    }

    // The same field missing everywhere is one bug. Rank by how many endpoints
    // it touches, so the fix list is ordered by what it buys.
    const byShape = new Map()
    for (const r of differing) {
      for (const key of new Set(r.diffs.map((d) => shape(d.path)))) {
        const leaf = key.split('.').slice(-2).join('.')
        byShape.set(leaf, (byShape.get(leaf) ?? new Set()).add(r.name))
      }
    }
    log('\n--- fields ranked by how many endpoints they break ---')
    for (const [leaf, endpoints] of [...byShape].sort((x, y) => y[1].size - x[1].size).slice(0, 20)) {
      log(`  ${String(endpoints.size).padStart(2)}  ${leaf}`)
    }
  }
  log(`\n${rows.length - differing.length}/${rows.length} endpoints match`)
  if (process.env.PARITY_STRICT === '1' && differing.length) process.exit(1)
  log('PARITY RUN COMPLETE')
}

await main()
