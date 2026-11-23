import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPair, SignJWT } from 'jose';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { createApp } from '../src/app.mjs';
import { entraConfig } from '../src/auth.mjs';

const config = {
  tenantId: '11111111-1111-1111-1111-111111111111',
  audience: '22222222-2222-2222-2222-222222222222',
  issuer: 'https://issuer.example/v2.0',
  resourceUrl: 'https://mcp.example',
  probeClientId: 'probe-client',
  allowedClientIds: ['connector-client'],
  requiredUserRole: 'MCP.User',
  runtime: 'test-runtime',
};
let keys, server, origin;
const logs = [];
before(async () => {
  keys = await generateKeyPair('RS256');
  server = createApp(config, keys.publicKey, line => logs.push(JSON.parse(line))).listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
});
after(() => new Promise(resolve => server.close(resolve)));
async function token(overrides = {}, signingKey = keys.privateKey) {
  return new SignJWT({
    tid: config.tenantId, oid: 'test-user', scp: 'MCP.Access',
    azp: 'connector-client', roles: ['MCP.User'],
    iss: config.issuer, aud: config.audience,
    iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 600,
    ...overrides,
  }).setProtectedHeader({ alg: 'RS256' }).sign(signingKey);
}
async function post(accessToken) {
  return fetch(`${origin}/mcp`, {
    method: 'POST', headers: accessToken ? { Authorization: `Bearer ${accessToken}` } : {},
  });
}
test('configuration fails closed', () => assert.throws(() => entraConfig({})));
test('delegated access is disabled until a client is allowlisted', () => {
  const ids = { TENANT_ID: config.tenantId, API_CLIENT_ID: config.audience };
  assert.deepEqual(entraConfig(ids).allowedClientIds, []);
  assert.equal(entraConfig(ids).requiredUserRole, 'MCP.User');
  assert.throws(() => entraConfig({ ...ids, ALLOWED_CLIENT_IDS: 'not-a-guid' }));
});
test('health is available without disclosing identity', async () => {
  assert.deepEqual(await (await fetch(`${origin}/healthz`)).json(), { status: 'ok' });
});
test('discovery advertises the protected MCP resource', async () => {
  const response = await fetch(`${origin}/.well-known/oauth-protected-resource`);
  assert.equal((await response.json()).resource, 'https://mcp.example/mcp');
});
test('missing and malformed tokens are rejected', async () => {
  for (const value of [undefined, 'invalid']) assert.equal((await post(value)).status, 401);
});
test('rejections are audited with the real MCP path and no token material', async () => {
  const response = await post('invalid');
  const id = response.headers.get('x-request-id');
  await new Promise(resolve => setImmediate(resolve));
  const entry = logs.find(line => line.event === 'http' && line.requestId === id);
  assert.equal(entry.path, '/mcp');
  assert.equal(entry.status, 401);
  assert(!JSON.stringify(logs).includes('invalid"'), 'bearer value must not be logged');
});
for (const [name, claims] of Object.entries({
  audience: { aud: 'wrong' }, issuer: { iss: 'https://wrong.example' },
  tenant: { tid: 'wrong' }, expiry: { exp: 1 }, missingExpiry: { exp: undefined },
})) {
  test(`rejects invalid ${name}`, async () => assert.equal((await post(await token(claims))).status, 401));
}
test('rejects signatures from another key', async () => {
  const other = await generateKeyPair('RS256');
  assert.equal((await post(await token({}, other.privateKey))).status, 401);
});
test('requires delegated scope, not merely a signed token', async () => {
  assert.equal((await post(await token({ scp: 'Other.Scope' }))).status, 403);
});
test('delegated token from a non-allowlisted client is rejected', async () => {
  assert.equal((await post(await token({ azp: 'other-tenant-app' }))).status, 403);
});
test('delegated user without the pilot role is rejected', async () => {
  assert.equal((await post(await token({ roles: undefined }))).status, 403);
});
test('app-only requires both probe role and exact allowlisted client', async () => {
  assert.equal((await post(await token({ scp: undefined, roles: ['MCP.Probe'], azp: 'wrong' }))).status, 403);
  assert.equal((await post(await token({ scp: undefined, roles: undefined, azp: config.probeClientId }))).status, 403);
});
for (const mode of ['delegated', 'application-probe']) {
  test(`MCP SDK initialize, tools/list and tools/call: ${mode}`, async () => {
    const accessToken = await token(mode === 'delegated' ? {} : {
      scp: undefined, roles: ['MCP.Probe'], azp: config.probeClientId,
    });
    const client = new Client({ name: 'test', version: '1.0.0' });
    try {
      await client.connect(new StreamableHTTPClientTransport(new URL(`${origin}/mcp`), {
        requestInit: { headers: { Authorization: `Bearer ${accessToken}` } },
      }));
      assert.equal((await client.listTools()).tools[0].name, 'iam_connection_check');
      const result = await client.callTool({ name: 'iam_connection_check', arguments: {} });
      assert(!result.isError);
      assert.equal(JSON.parse(result.content[0].text).identity.mode, mode);
      assert.equal(JSON.parse(result.content[0].text).runtime, 'test-runtime');
      const { identity } = JSON.parse(result.content[0].text);
      assert(Date.parse(identity.tokenExpiresAt) - Date.parse(identity.tokenIssuedAt) === 600_000);
      const audited = logs.filter(line => line.event === 'http' && line.identityMode === mode);
      assert(audited.length > 0 && audited.every(line => line.objectId === 'test-user'
        && line.tokenExpiresAt === identity.tokenExpiresAt));
    } finally { await client.close(); }
  });
}
