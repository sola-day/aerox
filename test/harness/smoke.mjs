// The smallest possible proof that the stack answers an upstream client:
// describeServer through @atproto/api. AEROX_PDS_URL defaults to the dev stack.
import { AtpAgent } from '@atproto/api'

const service = process.env.AEROX_PDS_URL ?? 'http://127.0.0.1:4000'
const agent = new AtpAgent({ service })
const res = await agent.com.atproto.server.describeServer()
if (!res.success) throw new Error(`describeServer failed: ${res.status}`)
console.log(JSON.stringify(res.data, null, 2))
