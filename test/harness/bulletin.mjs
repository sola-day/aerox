// VERIFICATION §6 scenario 9: bulletin end to end against pds.<dev-domain>.
// Owner logs in through our OAuth consent page (include:my.bulletin.permissions),
// creates a board (simplespace.createSpace) and pins a note (space createRecord);
// a mutual follower logs in, opens the board (delegation token → space credential
// on the owner's PDS, followers check via our AppView getRelationships) and pins
// a note of their own; the owner's board then shows both. Env: BULLETIN_URL,
// OWNER_HANDLE/OWNER_PASSWORD, MEMBER_HANDLE/MEMBER_PASSWORD.
import { chromium } from 'playwright'
import { existsSync } from 'node:fs'

const url = process.env.BULLETIN_URL ?? 'https://bulletin.aerox.sola.town'
const owner = { handle: process.env.OWNER_HANDLE ?? 'alice.aerox.sola.town', password: process.env.OWNER_PASSWORD ?? 'REDACTED-peer-account-password-rotated-2026-09-16' }
const member = { handle: process.env.MEMBER_HANDLE ?? 'bob.aerox.sola.town', password: process.env.MEMBER_PASSWORD ?? 'bob-dev-password' }
const shots = process.env.SHOT_DIR ?? '/tmp/claude-1000/-home-ubuntu-aero/1398f4ed-e70e-47f3-8a0d-52e0f8489995/scratchpad'
const stamp = Date.now().toString(36)

const browser = await chromium.launch({ executablePath: ['/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome'].find((p) => existsSync(p)), args: ['--no-sandbox'] })

async function login(ctx, who) {
  const page = await ctx.newPage()
  page.on('console', (m) => { if (m.type() === 'error') console.log(`  [${who.handle} console]`, m.text().slice(0, 200)) })
  await page.goto(url + '/', { waitUntil: 'domcontentloaded' })
  await page.locator('input.login-handle-input').fill(who.handle)
  await page.locator('form.stack button.button').first().click()
  // our PDS consent page
  await page.waitForURL(/pds\.aerox\.sola\.town\/oauth\/authorize/, { timeout: 30000 })
  await page.locator('input[name="identifier"]').first().fill(who.handle)
  await page.locator('input[name="password"]').first().fill(who.password)
  await page.locator('button[type="submit"]').first().click()
  await page.waitForSelector('button:has-text("Allow")', { timeout: 20000 })
  const scopes = await page.innerText('body')
  console.log(`  consent shows space scope: ${/my\.bulletin|bulletin/i.test(scopes)}`)
  await page.locator('button:has-text("Allow")').first().click()
  await page.waitForURL((u) => u.origin === url, { timeout: 30000 })
  await page.waitForLoadState('domcontentloaded')
  console.log(`  ${who.handle} logged in at ${page.url()}`)
  return page
}

async function pinNote(page, text) {
  const board = page.locator('.spatial-board, [class*="spatial"]').first()
  await board.waitFor({ timeout: 30000 })
  const box = await board.boundingBox()
  await page.mouse.click(...(await freeSpot(page, box)))
  await page.locator('textarea.composer-note').waitFor({ timeout: 10000 })
  await page.locator('textarea.composer-note').fill(text)
  await page.locator('form.board-composer-card button.button').first().click()
  await page.waitForLoadState('domcontentloaded')
  await page.getByText(text).first().waitFor({ timeout: 30000 })
  console.log(`  pinned: ${text}`)
}

// Clicking the board opens the composer, but only on bare cork: a click that
// lands on a note selects the note instead. The board keeps every note ever
// pinned, so a fixed (or small random) offset stops working as soon as a few
// runs have piled notes into that corner. Pick a point no existing note covers.
async function freeSpot(page, box) {
  const notes = await page.locator('.spatial-note').evaluateAll((els) =>
    els.map((el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height } }))
  const pad = 24
  const candidates = []
  for (let x = box.x + 60; x < box.x + box.width - 220; x += 40) {
    for (let y = box.y + 60; y < box.y + box.height - 140; y += 40) {
      if (!notes.some((n) => x > n.x - pad && x < n.x + n.w + pad && y > n.y - pad && y < n.y + n.h + pad)) {
        candidates.push([x, y])
      }
    }
  }
  if (!candidates.length) throw new Error('the board has no room left for another note')
  return candidates[Math.floor(Math.random() * candidates.length)]
}

// ---- owner
const ownerCtx = await browser.newContext()
console.log('owner login')
const op = await login(ownerCtx, owner)
await op.goto(`${url}/${owner.handle}`, { waitUntil: 'domcontentloaded' })
if (await op.locator('button:has-text("create my bulletin")').count()) {
  await op.locator('button:has-text("create my bulletin")').click()
  await op.waitForLoadState('domcontentloaded')
  await op.waitForTimeout(1500)
  console.log('  board created')
} else {
  console.log('  board already exists')
}
await op.screenshot({ path: `${shots}/bulletin-owner-board.png` })
const ownerNote = `owner note ${stamp}`
await pinNote(op, ownerNote)

// ---- member (mutual follower)
const memberCtx = await browser.newContext()
console.log('member login')
const mp = await login(memberCtx, member)
await mp.goto(`${url}/${owner.handle}`, { waitUntil: 'domcontentloaded' })
const memberSees = await mp.getByText(ownerNote).count()
console.log(`  member sees owner note: ${memberSees > 0}`)
const memberNote = `member note ${stamp}`
await pinNote(mp, memberNote)
await mp.screenshot({ path: `${shots}/bulletin-member-board.png` })

// ---- owner sees both
await op.reload({ waitUntil: 'domcontentloaded' })
await op.getByText(memberNote).first().waitFor({ timeout: 60000 })
const both = (await op.getByText(ownerNote).count()) > 0 && (await op.getByText(memberNote).count()) > 0
await op.screenshot({ path: `${shots}/bulletin-owner-final.png` })
console.log(`  owner sees both notes: ${both}`)
await browser.close()
if (!both || !memberSees) { console.error('BULLETIN FAILED'); process.exit(1) }
console.log('BULLETIN OK')
