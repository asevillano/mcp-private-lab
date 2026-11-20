targetScope = 'resourceGroup'

param location string = 'northeurope'
param namePrefix string = 'mcp-lab'
param tenantId string
param apiClientId string
param imageTag string = 'v1'
param imageName string = 'mcp-server'
@description('Optional GatewaySubnet (e.g. 10.91.255.0/27) to host a VPN/ExpressRoute gateway, making this VNet the hub for Power Platform and external MCPs.')
param gatewaySubnetPrefix string = ''
@description('Optional NSG already associated to the ACA subnet, so redeployments keep it.')
param acaSubnetNsgId string = ''
@description('Container registry name = this prefix + a unique suffix (lowercase letters and digits only).')
param registryNamePrefix string = 'mcplab'

var suffix = uniqueString(resourceGroup().id)
var tags = { purpose: 'MCP-OAuth-private-PoC', data: 'synthetic-only' }
var acaSubnet = {
  name: 'aca'
  properties: {
    addressPrefix: '10.91.0.0/23'
    networkSecurityGroup: empty(acaSubnetNsgId) ? null : { id: acaSubnetNsgId }
    delegations: [{
      name: 'aca'
      properties: { serviceName: 'Microsoft.App/environments' }
    }]
  }
}
var gatewaySubnet = empty(gatewaySubnetPrefix) ? [] : [{
  name: 'GatewaySubnet'
  properties: { addressPrefix: gatewaySubnetPrefix }
}]

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: ['10.91.0.0/16'] }
    subnets: concat([acaSubnet], gatewaySubnet)
  }
}
resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: '${registryNamePrefix}${suffix}'
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-runtime'
  location: location
  tags: tags
}
// Separate identity so the MCP runtime never holds the MCP.Probe app role.
resource probeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-probe'
  location: location
  tags: tags
}
resource pull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, identity.id, 'AcrPull')
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource probePull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, probeIdentity.id, 'AcrPull')
  scope: registry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: probeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${namePrefix}-logs'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }
  }
}
resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: '${namePrefix}-env'
  location: location
  tags: tags
  properties: {
    vnetConfiguration: {
      infrastructureSubnetId: '${vnet.id}/subnets/aca'
      internal: true
    }
    workloadProfiles: [{ name: 'Consumption', workloadProfileType: 'Consumption' }]
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}
module dns './dns.bicep' = {
  name: 'private-dns'
  params: {
    domain: environment.properties.defaultDomain
    privateIp: environment.properties.staticIp
    vnetId: vnet.id
  }
}

output registryName string = registry.name
output registryServer string = registry.properties.loginServer
output environmentId string = environment.id
output environmentDomain string = environment.properties.defaultDomain
output privateIp string = environment.properties.staticIp
output vnetId string = vnet.id
output identityId string = identity.id
output probeIdentityId string = probeIdentity.id
output probeClientId string = probeIdentity.properties.clientId
output probePrincipalId string = probeIdentity.properties.principalId
output acaSubnetPrefix string = '10.91.0.0/23'
output logAnalyticsCustomerId string = logs.properties.customerId
output image string = '${registry.properties.loginServer}/${imageName}:${imageTag}'
output tenant string = tenantId
output api string = apiClientId
