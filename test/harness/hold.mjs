import WebSocket from 'ws'
const N = Number(process.env.N ?? 1000)
const url = 'wss://relay.aerox.generic.dev/xrpc/com.atproto.sync.subscribeRepos'
const socks = []
for (let i = 0; i < N; i += 100) {
  await Promise.all(Array.from({length: Math.min(100, N - i)}, () => new Promise((res, rej) => {
    const ws = new WebSocket(url, { perMessageDeflate: false })
    ws.on('open', () => { socks.push(ws); res() })
    ws.on('error', rej)
  })))
}
console.log('holding', socks.length)
await new Promise((r) => setTimeout(r, 100000))
process.exit(0)
