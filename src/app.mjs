import express from 'express';
import { randomUUID } from 'node:crypto';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { authenticate } from './auth.mjs';

export function createApp(config, keys, log = console.log) {
  const app = express();
  app.disable('x-powered-by');
  app.use((req, res, next) => {
    req.requestId = randomUUID();
    res.set('x-request-id', req.requestId);
    res.on('finish', () => log(JSON.stringify({
      event: 'http', requestId: req.requestId, method: req.method,
      // originalUrl keeps the mount prefix even when a mounted middleware rejects.
      path: req.originalUrl.split('?')[0], status: res.statusCode,
      identityMode: res.locals.identity?.mode,
      // Pseudonymous Entra object/client IDs so each call can be tied to a test user.
      objectId: res.locals.identity?.objectId,
      clientId: res.locals.identity?.clientId,
    })));
    next();
  });
  app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));
  app.get('/.well-known/oauth-protected-resource', (_req, res) => res.json({
    resource: `${config.resourceUrl}/mcp`,
    authorization_servers: [config.issuer],
    scopes_supported: [`api://${config.audience}/MCP.Access`],
    bearer_methods_supported: ['header'],
  }));
  app.use('/mcp', authenticate(config, keys, log));
  app.post('/mcp', express.json({ limit: '128kb' }), async (req, res, next) => {
    const server = new McpServer({ name: 'mcp-private-lab', version: '1.0.0' });
    server.registerTool('iam_connection_check', {
      description: 'Diagnostico de conexion e identidad. Solo datos sinteticos, sin sistemas corporativos.',
      inputSchema: {},
    }, async () => ({
      content: [{ type: 'text', text: JSON.stringify({
        message: 'MCP privado accesible con token validado',
        synthetic: true, requestId: req.requestId, runtime: config.runtime,
        identity: res.locals.identity,
      }) }],
    }));
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined, enableJsonResponse: true,
    });
    res.on('close', () => {
      Promise.all([transport.close(), server.close()]).catch(next);
    });
    try {
      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);
    } catch (error) {
      next(error);
    }
  });
  app.all('/mcp', (_req, res) => res.set('Allow', 'POST').status(405).end());
  app.use((error, req, res, _next) => {
    log(JSON.stringify({ event: 'request_failed', requestId: req.requestId,
      error: error.code ?? error.name }));
    if (res.headersSent) return res.end();
    res.status(error.type === 'entity.parse.failed' ? 400 : 500)
      .json({ error: error.type === 'entity.parse.failed' ? 'invalid_json' : 'internal_error' });
  });
  return app;
}
