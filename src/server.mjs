import { createApp } from './app.mjs';
import { entraConfig, entraKeys } from './auth.mjs';

const config = entraConfig();
if (!process.env.RESOURCE_URL?.startsWith('https://')) {
  throw new Error('RESOURCE_URL must be the HTTPS origin of the private app');
}
config.resourceUrl = new URL(process.env.RESOURCE_URL).origin;
const port = Number(process.env.PORT) || 3000;   // Cloud Run injects PORT; ACA uses 3000
const server = createApp(config, entraKeys(config.tenantId))
  .listen(port, '0.0.0.0', () => console.log(JSON.stringify({ event: 'listening', port })));
process.on('SIGTERM', () => server.close());
