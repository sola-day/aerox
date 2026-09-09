// VERIFICATION §7.2 "@atproto/api client logs in (OAuth)": the upstream Node
// OAuth client, as a loopback client, against the aerox PDS — PAR, the
// consent page driven in headless Chromium, the code grant with DPoP, then
// XRPC calls through the OAuth session. Env: AEROX_PDS_URL, AEROX_PLC_URL,
// OAUTH_HANDLE, OAUTH_PASSWORD.
import http from 'node:http'
import { existsSync } from 'node:fs'
import { NodeOAuthClient } from '@atproto/oauth-client-node'
import { Agent } from '@atproto/api'
import { chromium } from 'playwright'

const plc = process.env.AEROX_PLC_URL ?? 'https://plc.aerox.sola.town'
const handle = process.env.OAUTH_HANDLE ?? 'alice.aerox.sola.town'
const password = process.env.OAUTH_PASSWORD ?? 'REDACTED-peer-account-password-rotated-2026-09-16'

// a loopback redirect target
const port = 4321
const redirectUri = `http://127.0.0.1:${port}/cb`
let resolveCallback
const callbackParams = new Promise((r) => (resolveCallback = r))
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${port}`)
  res.end('ok, you can close this window')
  if (url.pathname === '/cb') resolveCallback(url.searchParams)
})
await new Promise((r) => server.listen(port, '127.0.0.1', r))

const stores = { state: new Map(), session: new Map() }
const client = new NodeOAuthClient({
  clientMetadata: {
    client_id: `http://localhost?${new URLSearchParams({ redirect_uri: redirectUri, scope: 'atproto transition:generic' })}`,
    redirect_uris: [redirectUri],
    scope: 'atproto transition:generic',
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
    application_type: 'native',
    token_endpoint_auth_method: 'none',
    dpop_bound_access_tokens: true,
  },
  plcDirectoryUrl: plc,
  stateStore: { set: (k, v) => stores.state.set(k, v), get: (k) => stores.state.get(k), del: (k) => stores.state.delete(k) },
  sessionStore: { set: (k, v) => stores.session.set(k, v), get: (k) => stores.session.get(k), del: (k) => stores.session.delete(k) },
})

const authorizeUrl = await client.authorize(handle, { state: 'harness' })
console.log('authorize url', authorizeUrl.origin + authorizeUrl.pathname)

const candidates = ['/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome']
const browser = await chromium.launch({ executablePath: candidates.find((p) => existsSync(p)), args: ['--no-sandbox'] })
const page = await browser.newPage()
await page.goto(authorizeUrl.href, { waitUntil: 'networkidle' })
await page.locator('input[name="identifier"]').first().fill(handle)
await page.locator('input[name="password"]').first().fill(password)
await page.locator('button[type="submit"]').first().click()
await page.waitForSelector('button:has-text("Allow")', { timeout: 20000 })
await page.locator('button:has-text("Allow")').first().click()
const params = await callbackParams
await browser.close()
server.close()
console.log('callback', Object.fromEntries(params))

const { session, state } = await client.callback(params)
if (state !== 'harness') throw new Error('state mismatch')
console.log('session did', session.did)

const agent = new Agent(session)
const me = await agent.com.atproto.server.getSession()
console.log('getSession', me.data.handle, me.data.did)
const post = await agent.com.atproto.repo.createRecord({
  repo: session.did,
  collection: 'app.bsky.feed.post',
  record: { $type: 'app.bsky.feed.post', text: 'posted through atproto OAuth (DPoP) on aerox', createdAt: new Date().toISOString() },
})
console.log('createRecord', post.data.uri)
const tl = await agent.app.bsky.feed.getTimeline({ limit: 1 })
console.log('getTimeline through the OAuth session', tl.data.feed.length, 'items')
await session.signOut()
console.log('OAUTH OK')
