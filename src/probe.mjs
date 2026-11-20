import assert from 'node:assert/strict';
import { lookup } from 'node:dns/promises';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const target = new URL(process.env.MCP_URL);
const addresses = await lookup(target.hostname, { all: true });
assert(addresses.length > 0);
assert(addresses.every(({ address }) => /^10\./.test(address)
  || /^192\.168\./.test(address) || /^172\.(1[6-9]|2\d|3[01])\./.test(address)),
'DNS must resolve only to RFC1918 addresses');
console.log(JSON.stringify({ test: 'private_dns', addresses, passed: true }));
for (const authorization of [undefined, 'Bearer invalid']) {
  const response = await fetch(target, {
    method: 'POST', headers: authorization ? { authorization } : {},
    signal: AbortSignal.timeout(20000),
  });
  assert.equal(response.status, 401);
}
console.log(JSON.stringify({ test: 'missing_and_invalid_tokens_denied', passed: true }));

let token = process.env.MCP_ACCESS_TOKEN;
if (!token) {
  assert(process.env.IDENTITY_ENDPOINT && process.env.IDENTITY_HEADER, 'Managed identity unavailable');
  const endpoint = new URL(process.env.IDENTITY_ENDPOINT);
  endpoint.searchParams.set('api-version', '2019-08-01');
  endpoint.searchParams.set('resource', process.env.API_RESOURCE);
  endpoint.searchParams.set('client_id', process.env.PROBE_CLIENT_ID);
  const response = await fetch(endpoint, {
    headers: { 'X-IDENTITY-HEADER': process.env.IDENTITY_HEADER },
    signal: AbortSignal.timeout(20000),
  });
  assert(response.ok, `Managed identity token endpoint returned ${response.status}`);
  const body = await response.json();
  assert(body.access_token, 'Token endpoint did not return an access token');
  token = body.access_token;
}
const client = new Client({ name: 'mcp-private-probe', version: '1.0.0' });
try {
  await client.connect(new StreamableHTTPClientTransport(target, {
    requestInit: { headers: { Authorization: `Bearer ${token}` } },
  }));
  const tools = await client.listTools();
  assert(tools.tools.some(tool => tool.name === 'iam_connection_check'));
  const result = await client.callTool({ name: 'iam_connection_check', arguments: {} });
  assert(!result.isError);
  const data = JSON.parse(result.content[0].text);
  assert.equal(data.synthetic, true);
  assert(['delegated', 'application-probe'].includes(data.identity.mode));
  console.log(JSON.stringify({ test: 'mcp_initialize_list_call', passed: true, result: data }));
} finally {
  await client.close();
}
