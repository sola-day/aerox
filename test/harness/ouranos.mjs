// VERIFICATION §7.2 "ouranos renders": drive the real ouranos build in a
// headless browser — log in, open the home timeline, assert a post and its
// image render, screenshot. OURANOS_URL / OURANOS_HANDLE / OURANOS_PASSWORD.
import { chromium } from 'playwright'
import { existsSync } from 'node:fs'

const url = process.env.OURANOS_URL ?? 'https://ouranos.aerox.sola.town'
const handle = process.env.OURANOS_HANDLE ?? 'alice.aerox.sola.town'
const password = process.env.OURANOS_PASSWORD ?? 'REDACTED-peer-account-password-rotated-2026-09-16'
const expectText = process.env.OURANOS_EXPECT ?? 'a picture for ouranos'
const shot = process.env.OURANOS_SCREENSHOT ?? '/tmp/ouranos-home.png'
const candidates = ['/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome']
const executablePath = candidates.find((p) => existsSync(p))

const browser = await chromium.launch({ executablePath, args: ['--no-sandbox'] })
const page = await browser.newPage({ viewport: { width: 1200, height: 900 } })
const images = []
page.on('response', (r) => { if (r.url().includes('/img/')) images.push({ url: r.url(), status: r.status() }) })
const failures = []
const xrpc = []
page.on('response', (r) => { if (r.url().includes('/xrpc/')) xrpc.push({ url: r.url().slice(0, 140), status: r.status() }) })
const consoleMsgs = []
page.on('console', (m) => { if (m.type() === 'error' || m.type() === 'warning') consoleMsgs.push(m.text().slice(0, 300)) })
page.on('requestfailed', (r) => failures.push(r.url()))

await page.goto(url + '/', { waitUntil: 'networkidle' })
await page.goto(url + '/login', { waitUntil: 'networkidle' }).catch(() => {})
const handleInput = page.locator('input[name="handle"], input[placeholder*="aerox"], input[type="text"]').first()
await handleInput.fill(handle)
await page.locator('input[type="password"]').first().fill(password)
await page.locator('button[type="submit"]').first().click()
await page.waitForURL(/dashboard/, { timeout: 30000 })
await page.goto(url + '/dashboard/home', { waitUntil: 'networkidle' })
try {
  await page.getByText(expectText).first().waitFor({ timeout: 30000 })
} catch (e) {
  await page.screenshot({ path: shot })
  const text = (await page.innerText('body')).slice(0, 1500)
  console.log(JSON.stringify({ url: page.url(), text, xrpc, consoleMsgs, failures }, null, 2))
  await browser.close()
  process.exit(2)
}
const imgs = await page.$$eval('img', (els) => els.map((e) => ({ src: e.currentSrc || e.src, ok: e.complete && e.naturalWidth > 0 })))
const cdn = imgs.filter((i) => i.src.includes('/img/'))
await page.screenshot({ path: shot, fullPage: false })
console.log(JSON.stringify({ url: page.url(), postSeen: true, cdnImages: cdn, imageResponses: images, failures }, null, 2))
await browser.close()
if (!cdn.length || !cdn.every((i) => i.ok)) { console.error('image(s) did not render'); process.exit(1) }
console.log('OURANOS OK')
