param location string = 'northeurope'
param environmentId string
param environmentDomain string
param identityId string
param probeIdentityId string
param probeClientId string
param registryServer string
param image string
param tenantId string
param apiClientId string
param appName string = 'mcp-server'
@description('Comma-separated OAuth client IDs trusted for delegated calls (connector app). Empty disables delegated access.')
param allowedClientIds string = ''
@description('Source CIDRs allowed to reach the MCP ingress: ACA subnet (probe) plus Power Platform delegated subnets.')
param allowedSourceCidrs array
@description('Label returned by the tool as "runtime" to tell MCP instances apart (e.g. Azure vs GCP).')
param mcpRuntime string = 'azure-container-apps-northeurope'

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: appName
  location: location
  tags: { purpose: 'MCP-OAuth-private-PoC', data: 'synthetic-only' }
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${identityId}': {} } }
  properties: {
    managedEnvironmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 3000
        transport: 'http'
        allowInsecure: false
        ipSecurityRestrictions: [for (cidr, i) in allowedSourceCidrs: {
          name: 'allow-${i}'
          action: 'Allow'
          ipAddressRange: cidr
        }]
      }
      registries: [{ server: registryServer, identity: identityId }]
    }
    template: {
      containers: [{
        name: 'mcp'
        image: image
        resources: { cpu: json('0.25'), memory: '0.5Gi' }
        env: [
          { name: 'TENANT_ID', value: tenantId }
          { name: 'API_CLIENT_ID', value: apiClientId }
          { name: 'PROBE_CLIENT_ID', value: probeClientId }
          { name: 'ALLOWED_CLIENT_IDS', value: allowedClientIds }
          { name: 'MCP_RUNTIME', value: mcpRuntime }
          { name: 'RESOURCE_URL', value: 'https://${appName}.${environmentDomain}' }
        ]
        probes: [
          { type: 'Liveness', httpGet: { path: '/healthz', port: 3000 }, initialDelaySeconds: 10, periodSeconds: 30 }
          { type: 'Readiness', httpGet: { path: '/healthz', port: 3000 }, initialDelaySeconds: 3, periodSeconds: 10 }
        ]
      }]
      scale: { minReplicas: 1, maxReplicas: 2 }
    }
  }
}
resource probe 'Microsoft.App/jobs@2024-03-01' = {
  name: '${appName}-probe'
  location: location
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${probeIdentityId}': {} } }
  properties: {
    environmentId: environmentId
    workloadProfileName: 'Consumption'
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 180
      replicaRetryLimit: 0
      manualTriggerConfig: { parallelism: 1, replicaCompletionCount: 1 }
      registries: [{ server: registryServer, identity: probeIdentityId }]
    }
    template: {
      containers: [{
        name: 'probe'
        image: image
        command: ['node', 'src/probe.mjs']
        resources: { cpu: json('0.25'), memory: '0.5Gi' }
        env: [
          { name: 'MCP_URL', value: 'https://${appName}.${environmentDomain}/mcp' }
          { name: 'API_RESOURCE', value: 'api://${apiClientId}' }
          { name: 'PROBE_CLIENT_ID', value: probeClientId }
        ]
      }]
    }
  }
}
output mcpUrl string = 'https://${app.properties.configuration.ingress.fqdn}/mcp'
output probeJob string = probe.name
