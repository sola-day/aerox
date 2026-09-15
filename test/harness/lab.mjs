// Multi-implementation interop against the lab network on generic.dev
// (VERIFICATION §7.4). The lab runs seven PDS implementations that share one
// PLC directory (plc.xjdao.generic.dev), an indigo relay (relay.generic.dev)
// and a bsky AppView (appview.generic.dev). The aerox instance under test is
// tools/interop/lab-devserver.sh, which registers its DIDs on the same PLC.
//
//   node lab.mjs accounts        create (or log in) one account per PDS, post once
//   node lab.mjs crawl           each relay crawls every PDS; posts reach both AppViews
//   node lab.mjs proxy           app.bsky.* proxied across implementations
//   node lab.mjs social          follows, likes, replies, images; both AppViews agree
//   node lab.mjs all
//
// Accounts are remembered in ../../tmp/lab/accounts.json (gitignored).
import {AtpAgent} from '@atproto/api';
import fs from 'node:fs';
import zlib from 'node:zlib';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const stateFile = path.join(here, '../../tmp/lab/accounts.json');

export const LAB = {
  plc: 'https://plc.xjdao.generic.dev',
  relay: 'https://relay.generic.dev',
  appview: 'https://appview.generic.dev',
  appviewDid: 'did:web:appview.generic.dev',
};
export const AEROX = {
  pds: 'https://pds.lab.aerox.sola.town',
  relay: 'https://relay.lab.aerox.sola.town',
  appview: 'https://appview.lab.aerox.sola.town',
  appviewDid: 'did:web:appview.lab.aerox.sola.town',
  mailbox: 'https://lab.aerox.sola.town/dev/mailbox/json',
};

// name → PDS url and the suffix its handles take
export const PDSES = {
  aerox: {url: AEROX.pds, domain: '.lab.aerox.sola.town'},
  atproto: {url: 'https://atproto.generic.dev', domain: '.u.atproto.generic.dev'},
  crates: {url: 'https://crates.generic.dev', domain: '.u.crates.generic.dev'},
  tranquil: {url: 'https://tranquil.generic.dev', domain: '.u.tranquil.generic.dev'},
  pegasus: {url: 'https://pegasus.generic.dev', domain: '.pegasus.generic.dev'},
  zds: {url: 'https://zds.generic.dev', domain: '.u.zds.generic.dev'},
  cocoon: {url: 'https://cocoon.generic.dev', domain: '.cocoon.generic.dev'},
  rsky: {url: 'https://rsky.generic.dev', domain: '.u.rsky.generic.dev'},
};

export const loadState = () => (fs.existsSync(stateFile) ? JSON.parse(fs.readFileSync(stateFile, 'utf8')) : {});
export const saveState = s => {
  fs.mkdirSync(path.dirname(stateFile), {recursive: true});
  fs.writeFileSync(stateFile, JSON.stringify(s, null, 2), {mode: 0o600});
};

export const sleep = ms => new Promise(r => setTimeout(r, ms));
export async function until(what, fn, {timeout = 90_000, every = 3_000} = {}) {
  const t0 = Date.now();
  let last;
  while (Date.now() - t0 < timeout) {
    try {
      const v = await fn();
      if (v) return v;
    } catch (e) {
      last = e;
    }
    await sleep(every);
  }
  throw new Error(`timed out: ${what}${last ? ` (last error: ${last.message})` : ''}`);
}

export const errText = e => `${e?.status ?? ''} ${e?.error ?? ''} ${e?.message ?? e}`.trim();

export async function xrpc(base, nsid, params = {}, init = {}) {
  const u = new URL(`/xrpc/${nsid}`, base);
  for (const [k, v] of Object.entries(params)) {
    for (const item of [v].flat()) u.searchParams.append(k, item);
  }
  const res = await fetch(u, init);
  const text = await res.text();
  let body;
  try {
    body = JSON.parse(text);
  } catch {
    body = text;
  }
  return {status: res.status, body, headers: res.headers};
}

const results = [];
export function record(area, name, pds, ok, detail = '') {
  results.push({area, name, pds, ok, detail});
  console.log(`${ok ? 'PASS' : 'FAIL'} [${area}] ${pds}: ${name}${detail ? ` — ${detail}` : ''}`);
}
export async function check(area, name, pds, fn) {
  try {
    const detail = await fn();
    record(area, name, pds, true, typeof detail === 'string' ? detail : '');
    return true;
  } catch (e) {
    record(area, name, pds, false, errText(e));
    return false;
  }
}

export async function login(name, acct) {
  const agent = new AtpAgent({service: PDSES[name].url});
  await agent.login({identifier: acct.handle, password: acct.password});
  return agent;
}

async function accounts(names) {
  const state = loadState();
  const stamp = Date.now().toString(36).slice(-5);
  for (const name of names) {
    const pds = PDSES[name];
    await check('accounts', 'create account or log in', name, async () => {
      let acct = state[name];
      if (!acct) {
        const agent = new AtpAgent({service: pds.url});
        acct = {
          handle: `ix${name.slice(0, 4)}${stamp}${pds.domain}`,
          password: `Lab-interop-${stamp}-pw9`,
          email: `ix-${name}-${stamp}@example.com`,
        };
        const res = await agent.createAccount(acct);
        acct.did = res.data.did;
        state[name] = acct;
        saveState(state);
      }
      const agent = await login(name, acct);
      acct.did = agent.session.did;
      saveState(state);
      return acct.did;
    });
    if (!state[name]) continue;
    await check('accounts', 'DID document on the lab PLC points at the PDS', name, async () => {
      const doc = await (await fetch(`${LAB.plc}/${state[name].did}`)).json();
      const svc = doc.service?.find(s => s.id === '#atproto_pds');
      if (svc?.serviceEndpoint.replace(/\/$/, '') !== pds.url) throw new Error(`endpoint ${svc?.serviceEndpoint}`);
    });
    await check('accounts', 'write a post', name, async () => {
      const agent = await login(name, state[name]);
      const res = await agent.post({text: `lab interop from ${name} ${new Date().toISOString()}`});
      state[name].post = res.uri;
      saveState(state);
      return res.uri;
    });
  }
}

async function crawl(names) {
  const state = loadState();
  for (const name of names) {
    const host = new URL(PDSES[name].url).host;
    const acct = state[name];
    if (!acct?.post) {
      record('crawl', 'account and post exist', name, false, 'run `accounts` first');
      continue;
    }
    for (const [relayName, relay] of [
      ['aerox relay', AEROX.relay],
      ['lab relay', LAB.relay],
    ]) {
      await check('crawl', `${relayName} accepts requestCrawl`, name, async () => {
        const r = await xrpc(relay, 'com.atproto.sync.requestCrawl', {}, {
          method: 'POST',
          headers: {'content-type': 'application/json'},
          body: JSON.stringify({hostname: host}),
        });
        if (r.status !== 200) throw new Error(`${r.status} ${JSON.stringify(r.body)}`);
      });
      await check('crawl', `${relayName} serves the repo (getLatestCommit)`, name, async () => {
        // A fresh write after the crawl request, so the relay sees at least one
        // event. requestCrawl returns before the relay has dialled the host, and
        // a new host is subscribed without a cursor, so a write that lands
        // first is never seen: write again every 20 s until one is.
        const agent = await login(name, acct);
        let pdsHead;
        return until(`${relayName} has ${name}'s head`, async () => {
          if (!pdsHead || Date.now() - pdsHead.at > 20_000) {
            await agent.post({text: `crawl probe for ${relayName} ${Date.now()}`});
            pdsHead = {...(await xrpc(PDSES[name].url, 'com.atproto.sync.getLatestCommit', {did: acct.did})).body, at: Date.now()};
          }
          const r = await xrpc(relay, 'com.atproto.sync.getLatestCommit', {did: acct.did});
          if (r.status !== 200) throw new Error(`${r.status} ${JSON.stringify(r.body)}`);
          return r.body.rev >= pdsHead.rev ? `rev ${r.body.rev}` : null;
        });
      });
    }
    for (const [viewName, view] of [
      ['aerox appview', AEROX.appview],
      ['lab appview', LAB.appview],
    ]) {
      await check('crawl', `${viewName} indexes the post`, name, async () =>
        until(`${viewName} has ${acct.post}`, async () => {
          const r = await xrpc(view, 'app.bsky.feed.getPosts', {uris: acct.post});
          if (r.status !== 200) throw new Error(`${r.status} ${JSON.stringify(r.body)}`);
          return r.body.posts?.length === 1 ? `handle ${r.body.posts[0].author.handle}` : null;
        }),
      );
    }
  }
}

async function proxy(names) {
  const state = loadState();
  for (const name of names) {
    const acct = state[name];
    if (!acct) continue;
    for (const [viewName, did] of [
      ['aerox appview', AEROX.appviewDid],
      ['lab appview', LAB.appviewDid],
    ]) {
      await check('proxy', `getProfile through the PDS to the ${viewName}`, name, async () => {
        const agent = await login(name, acct);
        const r = await agent
          .withProxy('bsky_appview', did)
          .app.bsky.actor.getProfile({actor: acct.did});
        return `handle ${r.data.handle}`;
      });
      await check('proxy', `getTimeline (viewer-authenticated) through the PDS to the ${viewName}`, name, async () => {
        const agent = await login(name, acct);
        const r = await agent.withProxy('bsky_appview', did).app.bsky.feed.getTimeline({limit: 5});
        return `${r.data.feed.length} items`;
      });
    }
  }
}

// A valid 48×48 RGB PNG whose pixels depend on `seed`, so every upload is a new blob.
export function png(seed) {
  const w = 48;
  const raw = Buffer.alloc((w * 3 + 1) * w);
  for (let y = 0; y < w; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const o = y * (w * 3 + 1) + 1 + x * 3;
      raw[o] = (x * 5 + seed) & 255;
      raw[o + 1] = (y * 5 + seed * 7) & 255;
      raw[o + 2] = (seed * 13) & 255;
    }
  }
  const crcTable = Array.from({length: 256}, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = buf => {
    let c = 0xffffffff;
    for (const b of buf) c = crcTable[(c ^ b) & 255] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(w, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const VIEWS = [
  ['aerox appview', AEROX.appview],
  ['lab appview', LAB.appview],
];

// Every account follows every other, likes and replies to every other
// account's post, and posts one image. Then both AppViews must agree on the
// counts, the thread, the image and aerox's notifications.
async function social(names) {
  const state = loadState();
  const present = names.filter(n => state[n]?.post);
  const agents = {};
  for (const n of present) agents[n] = await login(n, state[n]);

  for (const n of present) {
    const me = state[n];
    await check('social', 'follow, like and reply to every other implementation', n, async () => {
      const done = (me.socialDone ??= []);
      for (const other of present) {
        if (other === n || done.includes(other)) continue;
        const them = state[other];
        const post = (await agents[n].app.bsky.feed.getPosts({uris: [them.post]}).catch(() => null))?.data.posts[0];
        const cid = post?.cid ?? (await xrpc(PDSES[other].url, 'com.atproto.repo.getRecord', {
          repo: them.did, collection: 'app.bsky.feed.post', rkey: them.post.split('/').pop(),
        })).body.cid;
        await agents[n].follow(them.did);
        await agents[n].like(them.post, cid);
        await agents[n].post({text: `reply from ${n} to ${other}`, reply: {root: {uri: them.post, cid}, parent: {uri: them.post, cid}}});
        done.push(other);
        saveState(state);
      }
      return `${done.length} peers`;
    });
    await check('social', 'post an image', n, async () => {
      if (me.imagePost) return me.imagePost;
      const {data} = await agents[n].uploadBlob(png(present.indexOf(n) + 1), {encoding: 'image/png'});
      const res = await agents[n].post({
        text: `image from ${n}`,
        embed: {$type: 'app.bsky.embed.images', images: [{image: data.blob, alt: `${n} test image`, aspectRatio: {width: 48, height: 48}}]},
      });
      me.imagePost = res.uri;
      saveState(state);
      return res.uri;
    });
  }

  const peers = present.length - 1;
  for (const n of present) {
    const me = state[n];
    for (const [viewName, view] of VIEWS) {
      await check('social', `${viewName}: ${peers} followers, likes and replies`, n, async () =>
        until(`${viewName} counts for ${n}`, async () => {
          const prof = await xrpc(view, 'app.bsky.actor.getProfile', {actor: me.did});
          const posts = await xrpc(view, 'app.bsky.feed.getPosts', {uris: me.post});
          const p = posts.body.posts?.[0];
          const got = `followers ${prof.body.followersCount} follows ${prof.body.followsCount} likes ${p?.likeCount} replies ${p?.replyCount}`;
          if (prof.body.followersCount >= peers && prof.body.followsCount >= peers && p?.likeCount >= peers && p?.replyCount >= peers) return got;
          throw new Error(got);
        }, {timeout: 120_000}),
      );
      await check('social', `${viewName}: thread shows every reply`, n, async () => {
        const r = await xrpc(view, 'app.bsky.feed.getPostThread', {uri: me.post, depth: 1});
        if (r.status !== 200) throw new Error(`${r.status} ${JSON.stringify(r.body)}`);
        const authors = new Set(r.body.thread.replies.map(x => x.post?.author.did));
        const missing = present.filter(o => o !== n && !authors.has(state[o].did));
        if (missing.length) throw new Error(`missing replies from ${missing.join(', ')}`);
      });
      await check('social', `${viewName}: image embed resolves to a fetchable image`, n, async () =>
        until(`${viewName} image for ${n}`, async () => {
          const r = await xrpc(view, 'app.bsky.feed.getPosts', {uris: me.imagePost});
          const img = r.body.posts?.[0]?.embed?.images?.[0];
          if (!img) throw new Error(`no embed: ${JSON.stringify(r.body).slice(0, 200)}`);
          const res = await fetch(img.thumb);
          const type = res.headers.get('content-type');
          if (res.status !== 200 || !type?.startsWith('image/')) throw new Error(`thumb ${res.status} ${type} ${img.thumb}`);
          return `${type} ${img.thumb.slice(0, 60)}…`;
        }, {timeout: 60_000}),
      );
    }
  }

  if (state.aerox) {
    await check('social', 'aerox notifications list every implementation', 'aerox', async () => {
      const r = await agents.aerox.app.bsky.notification.listNotifications({limit: 100});
      const by = {};
      for (const x of r.data.notifications) (by[x.reason] ??= new Set()).add(x.author.did);
      const missing = [];
      for (const o of present.filter(o => o !== 'aerox')) {
        for (const reason of ['follow', 'like', 'reply']) if (!by[reason]?.has(state[o].did)) missing.push(`${reason}:${o}`);
      }
      if (missing.length) throw new Error(`missing ${missing.join(' ')}`);
      return Object.entries(by).map(([k, v]) => `${k} ${v.size}`).join(', ');
    });
  }
}

export function summary() {
  const failed = results.filter(r => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  for (const f of failed) console.log(`  FAIL [${f.area}] ${f.pds}: ${f.name} — ${f.detail}`);
  return results;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd = 'all', ...rest] = process.argv.slice(2);
  const names = rest.length ? rest : Object.keys(PDSES);
  if (cmd === 'accounts' || cmd === 'all') await accounts(names);
  if (cmd === 'crawl' || cmd === 'all') await crawl(names);
  if (cmd === 'proxy' || cmd === 'all') await proxy(names);
  if (cmd === 'social' || cmd === 'all') await social(names);
  const rs = summary();
  fs.writeFileSync(path.join(here, `../../tmp/lab/results-${cmd}.json`), JSON.stringify(rs, null, 2));
  process.exit(rs.some(r => !r.ok) ? 1 : 0);
}
