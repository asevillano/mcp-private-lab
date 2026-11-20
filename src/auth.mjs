import { createRemoteJWKSet, jwtVerify, errors } from 'jose';

export function entraConfig(env = process.env) {
  for (const name of ['TENANT_ID', 'API_CLIENT_ID']) {
    if (!/^[0-9a-f-]{36}$/i.test(env[name] ?? '')) {
      throw new Error(`Missing or invalid ${name}`);
    }
  }
  const allowedClientIds = (env.ALLOWED_CLIENT_IDS ?? '')
    .split(',').map(id => id.trim()).filter(Boolean);
  if (allowedClientIds.some(id => !/^[0-9a-f-]{36}$/i.test(id))) {
    throw new Error('Invalid ALLOWED_CLIENT_IDS');
  }
  return {
    tenantId: env.TENANT_ID,
    audience: env.API_CLIENT_ID,
    issuer: `https://login.microsoftonline.com/${env.TENANT_ID}/v2.0`,
    probeClientId: env.PROBE_CLIENT_ID || undefined,
    // Empty list means no delegated client is trusted yet (fail closed).
    allowedClientIds,
    requiredUserRole: env.REQUIRED_USER_ROLE || 'MCP.User',
    // Free-text label shown in tool results, e.g. "gcp-cloud-run", to tell MCP instances apart.
    runtime: env.MCP_RUNTIME || undefined,
  };
}

export function entraKeys(tenantId) {
  return createRemoteJWKSet(new URL(
    `https://login.microsoftonline.com/${tenantId}/discovery/v2.0/keys`,
  ));
}

export function authenticate(config, keys, log = console.log) {
  return async (req, res, next) => {
    const bearer = /^Bearer ([^\s]+)$/i.exec(req.headers.authorization ?? '');
    const challenge = `Bearer resource_metadata="${config.resourceUrl}/.well-known/oauth-protected-resource"`;
    if (!bearer) {
      return res.set('WWW-Authenticate', challenge).status(401).json({ error: 'invalid_token' });
    }
    let payload;
    try {
      ({ payload } = await jwtVerify(bearer[1], keys, {
        issuer: config.issuer, audience: config.audience,
        algorithms: ['RS256'], requiredClaims: ['exp', 'iat', 'tid', 'oid'],
      }));
    } catch (error) {
      if (error instanceof errors.JOSEError) {
        const infrastructureFailure = ['ERR_JWKS_TIMEOUT', 'ERR_JWKS_INVALID'].includes(error.code);
        log(JSON.stringify({ event: 'auth_rejected', requestId: req.requestId, reason: error.code }));
        return res.set('WWW-Authenticate', challenge).status(infrastructureFailure ? 503 : 401)
          .json({ error: infrastructureFailure ? 'identity_unavailable' : 'invalid_token' });
      }
      return next(error);
    }
    if (payload.tid !== config.tenantId) {
      return res.status(401).json({ error: 'invalid_tenant' });
    }
    const roles = Array.isArray(payload.roles) ? payload.roles : [];
    const delegated = typeof payload.scp === 'string'
      && payload.scp.split(' ').includes('MCP.Access')
      && config.allowedClientIds.includes(payload.azp)
      && roles.includes(config.requiredUserRole);
    const probe = !payload.scp && Boolean(config.probeClientId)
      && payload.azp === config.probeClientId
      && roles.includes('MCP.Probe');
    if (!delegated && !probe) {
      log(JSON.stringify({
        event: 'permission_denied', requestId: req.requestId, clientId: payload.azp,
        hasScope: typeof payload.scp === 'string', roleCount: roles.length,
      }));
      return res.set('WWW-Authenticate', 'Bearer error="insufficient_scope", scope="MCP.Access"')
        .status(403).json({ error: 'insufficient_scope' });
    }
    res.locals.identity = {
      tenantId: payload.tid, objectId: payload.oid,
      clientId: payload.azp, mode: delegated ? 'delegated' : 'application-probe',
    };
    next();
  };
}
