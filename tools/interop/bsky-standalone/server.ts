/**
 * The reference AppView of VERIFICATION §7.1, as one process: bsync, the
 * data plane, the AppView itself, and the two subscriptions that feed it.
 *
 * This is aerox's entrypoint, not upstream's: it imports only the public
 * exports of `@atproto/bsky` and `@atproto/bsync` and wires them exactly the
 * way upstream's own `packages/dev-env` does, so the oracle stays upstream's
 * code. (The reading-room checkout carries a `services/bsky-standalone` that
 * imports a `MockBsync` the package no longer exports; upstream replaced it
 * with the real bsync service, which is what runs here.)
 *
 * On first boot it mints a DID for itself on the configured PLC directory and
 * keeps the key under DATA_DIR, so restarts keep the same identity — the PDS
 * that proxies to it names that DID as the audience of its service JWTs.
 */
import assert from 'node:assert'
import fs from 'node:fs'
import path from 'node:path'
import {
  BskyAppView,
  BsyncSubscription,
  DataPlaneServer,
  Database,
  RepoSubscription,
  ServerConfig,
} from '@atproto/bsky'
import { BsyncService, envToCfg } from '@atproto/bsync'
import { Secp256k1Keypair } from '@atproto/crypto'
import { Client as PlcClient } from '@did-plc/lib'

const DATA_DIR = process.env.DATA_DIR || '/data/appview'
const KEY_FILE = path.join(DATA_DIR, 'signing.key')
const DID_FILE = path.join(DATA_DIR, 'server.did')
const BSYNC_API_KEY = process.env.BSYNC_API_KEY || 'bsync-api-key'

async function getOrCreateIdentity(plcUrl: string, publicUrl: string) {
  fs.mkdirSync(DATA_DIR, { recursive: true })

  let keypair: Secp256k1Keypair
  if (fs.existsSync(KEY_FILE)) {
    keypair = await Secp256k1Keypair.import(fs.readFileSync(KEY_FILE, 'utf8').trim())
  } else {
    keypair = await Secp256k1Keypair.create({ exportable: true })
    fs.writeFileSync(KEY_FILE, Buffer.from(await keypair.export()).toString('hex'), {
      mode: 0o600,
    })
  }

  if (fs.existsSync(DID_FILE)) {
    const did = fs.readFileSync(DID_FILE, 'utf8').trim()
    console.log('appview did (existing):', did)
    return { keypair, did }
  }

  const plc = new PlcClient(plcUrl)
  const handle = new URL(publicUrl).host
  const did = await plc.createDid({
    signingKey: keypair.did(),
    rotationKeys: [keypair.did()],
    handle,
    pds: publicUrl,
    signer: keypair,
  })
  await plc.updateData(did, keypair, (doc) => {
    doc.services['bsky_appview'] = { type: 'BskyAppView', endpoint: publicUrl }
    doc.services['bsky_notif'] = { type: 'BskyNotificationService', endpoint: publicUrl }
    return doc
  })
  fs.writeFileSync(DID_FILE, did)
  console.log('appview did (new):', did)
  return { keypair, did }
}

const main = async () => {
  const dbUrl = process.env.DB_POSTGRES_URL
  assert(dbUrl, 'DB_POSTGRES_URL required')
  const plcUrl = process.env.BSKY_DID_PLC_URL || 'https://plc.directory'
  const publicUrl = process.env.BSKY_PUBLIC_URL || 'http://localhost:3000'
  const port = parseInt(process.env.BSKY_PORT || '3000', 10)
  const dataplanePort = parseInt(process.env.DATAPLANE_PORT || '4001', 10)
  const bsyncPort = parseInt(process.env.BSYNC_PORT || '4002', 10)
  const schema = process.env.DB_SCHEMA || 'public'

  const { keypair, did: serverDid } = await getOrCreateIdentity(plcUrl, publicUrl)

  // bsync keeps the private state (mutes, blocks) the AppView reads back
  // through BsyncSubscription. Its own schema, its own migrations.
  const bsync = await BsyncService.create(
    envToCfg({
      port: bsyncPort,
      dbUrl,
      dbSchema: 'bsync',
      dbPoolSize: 5,
      apiKeys: [BSYNC_API_KEY],
    }),
  )
  await bsync.ctx.db.migrateToLatestOrThrow()
  await bsync.start()

  // One pool shared by the AppView, the data plane and both subscriptions,
  // as upstream's dev-env does.
  const db = new Database({ url: dbUrl, schema, poolSize: 10 })
  const migrationDb = new Database({ url: dbUrl, schema })
  await migrationDb.migrateToLatestOrThrow()
  await migrationDb.close()

  const dataplane = await DataPlaneServer.create(db, dataplanePort, plcUrl)

  const config = new ServerConfig({
    version: process.env.BSKY_VERSION ?? 'unknown',
    port,
    didPlcUrl: plcUrl,
    publicUrl,
    serverDid,
    alternateAudienceDids: [],
    dataplaneUrls: [`http://127.0.0.1:${dataplanePort}`],
    dataplaneHttpVersion: '1.1',
    bsyncUrl: `http://127.0.0.1:${bsyncPort}`,
    bsyncHttpVersion: '1.1',
    bsyncApiKey: BSYNC_API_KEY,
    modServiceDid: process.env.MOD_SERVICE_DID ?? 'did:example:invalidMod',
    labelsFromIssuerDids: [],
    adminPasswords: [process.env.BSKY_ADMIN_PASSWORDS ?? 'admin'],
    etcdHosts: [],
    bigThreadUris: new Set(),
    maxThreadParents: 50,
    disableSsrfProtection: true,
    searchTagsHide: new Set(),
    searchTagsHideAll: new Set(),
    threadTagsBumpDown: new Set(),
    threadTagsHide: new Set(),
    visibilityTagHide: '',
    visibilityTagRankPrefix: '',
    debugFieldAllowedDids: new Set(),
    draftsLimit: 500,
  })

  const server = BskyAppView.create({ config, signingKey: keypair })
  await server.start()
  console.log(`appview listening on ${port} (dataplane ${dataplanePort}, bsync ${bsyncPort})`)

  const bsyncSub = new BsyncSubscription({ config, db })
  bsyncSub.start()

  const repoProvider = process.env.BSKY_REPO_PROVIDER
  let sub: RepoSubscription | undefined
  if (repoProvider) {
    sub = new RepoSubscription({ service: repoProvider, db, idResolver: dataplane.idResolver })
    void sub.start()
    console.log(`indexing ${repoProvider}`)
  }

  const shutdown = async () => {
    sub?.destroy()
    await bsyncSub.destroy()
    await server.destroy()
    await dataplane.destroy()
    await bsync.destroy()
    await db.close()
    process.exit(0)
  }
  process.on('SIGTERM', shutdown)
  process.on('SIGINT', shutdown)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
