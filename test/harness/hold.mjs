// Holds N idle firehose subscribers open so the relay's memory per subscriber
// can be read off the node while they are connected (VERIFICATION §10.1):
//
//   N=1000 node hold.mjs &
//   ssh <relay host> 'aerox rpc ":erlang.memory()"'
//
// Idle on purpose — a subscriber that is also receiving would mix the cost of
// the connection with the cost of the traffic.
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
