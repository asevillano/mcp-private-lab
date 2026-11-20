targetScope = 'resourceGroup'

// Power Platform VNet support: two delegated subnets (one per region of the environment's
// region pair), connectivity to the network where the MCP server lives, and the
// NetworkInjection enterprise policy.
//
// Where is the MCP server?
//  - Lab (ACA in Azure): backendVnetId = ACA VNet, privateDnsZoneId = ACA private zone.
//  - GCP / on-premises / other network: backendVnetId = hub VNet with VPN/ExpressRoute
//    gateway, useRemoteGateways = true, and dnsServers = DNS that resolves the MCP FQDN
//    (Azure DNS Private Resolver inbound endpoint, or corporate DNS reachable via the hub).

@description('Power Platform region of the environment (azureRegion / Get-EnvironmentRegion). Canada => canadacentral + canadaeast; Europe => westeurope + northeurope.')
param policyLocation string = 'canada'
param primaryRegion string = 'canadacentral'
param secondaryRegion string = 'canadaeast'
param primaryPrefix string = '10.92.0.0/24'
param primarySubnet string = '10.92.0.0/26'
param secondaryPrefix string = '10.93.0.0/24'
param secondarySubnet string = '10.93.0.0/26'
param namePrefix string = 'mcp-lab'

@description('Resource ID of the VNet to peer with: the lab ACA VNet or the hub that holds the VPN/ExpressRoute gateway. Empty = no peering.')
param backendVnetId string = ''
@description('Name of the peering created on each Power Platform VNet.')
param backendPeeringName string = 'to-aca'
@description('Also create the peering on the backend/hub side (requires permissions on that VNet).')
param createReversePeering bool = true
@description('Use the hub VPN/ExpressRoute gateway to reach GCP or on-premises (gateway transit). The hub side gets allowGatewayTransit.')
param useRemoteGateways bool = false
@description('Accept traffic forwarded by a hub firewall/NVA.')
param allowForwardedTraffic bool = false

@description('Resource ID of a private DNS zone to link to both Power Platform VNets (lab: ACA zone). Empty = none.')
param privateDnsZoneId string = ''
@description('Custom DNS servers for the Power Platform VNets (e.g. Private Resolver inbound IP). Must be final BEFORE linking the policy: it cannot be changed while linked.')
param dnsServers array = []
@description('Optional NSG resource IDs for the delegated subnets, in region order [primary, secondary]. Keeps existing NSGs on redeploy and allows outbound filtering.')
param subnetNsgIds array = []
@description('Create/update the enterprise policy. Set to false once it is linked to an environment: a linked policy cannot be updated.')
param manageEnterprisePolicy bool = true

var tags = { purpose: 'MCP-OAuth-private-PoC', data: 'synthetic-only' }
var subnetName = 'pp-delegated'
var regions = [
  { location: primaryRegion, prefix: primaryPrefix, subnet: primarySubnet }
  { location: secondaryRegion, prefix: secondaryPrefix, subnet: secondarySubnet }
]
// Safe placeholders keep scope expressions valid when the optional IDs are empty.
var placeholder = '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/x/y/none'
var backend = split(empty(backendVnetId) ? placeholder : backendVnetId, '/')
var dnsZone = split(empty(privateDnsZoneId) ? placeholder : privateDnsZoneId, '/')

resource ppVnets 'Microsoft.Network/virtualNetworks@2024-05-01' = [for (r, i) in regions: {
  name: '${namePrefix}-pp-${r.location}'
  location: r.location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [r.prefix] }
    dhcpOptions: empty(dnsServers) ? null : { dnsServers: dnsServers }
    subnets: [{
      name: subnetName
      properties: {
        addressPrefix: r.subnet
        networkSecurityGroup: length(subnetNsgIds) > i ? { id: subnetNsgIds[i] } : null
        delegations: [{
          name: 'powerplatform'
          properties: { serviceName: 'Microsoft.PowerPlatform/enterprisePolicies' }
        }]
      }
    }]
  }
}]

// Backend/hub side first: gateway transit must be allowed before a spoke can use it.
module fromBackend 'modules/vnet-peering.bicep' = [for (r, i) in regions: if (!empty(backendVnetId) && createReversePeering) {
  name: 'peer-backend-to-pp-${r.location}'
  scope: resourceGroup(backend[2], backend[4])
  params: {
    vnetName: backend[8]
    peeringName: 'to-pp-${r.location}'
    remoteVnetId: ppVnets[i].id
    allowGatewayTransit: useRemoteGateways
    allowForwardedTraffic: allowForwardedTraffic
  }
}]

resource toBackend 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = [for (r, i) in regions: if (!empty(backendVnetId)) {
  parent: ppVnets[i]
  name: backendPeeringName
  properties: {
    remoteVirtualNetwork: { id: backendVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: false
    useRemoteGateways: useRemoteGateways
  }
  dependsOn: [fromBackend]
}]

module dnsLinks 'modules/private-dns-link.bicep' = [for (r, i) in regions: if (!empty(privateDnsZoneId)) {
  name: 'dns-link-pp-${r.location}'
  scope: resourceGroup(dnsZone[2], dnsZone[4])
  params: {
    zoneName: dnsZone[8]
    linkName: 'pp-${r.location}'
    vnetId: ppVnets[i].id
  }
}]

#disable-next-line BCP081
resource policy 'Microsoft.PowerPlatform/enterprisePolicies@2020-10-30' = if (manageEnterprisePolicy) {
  name: '${namePrefix}-pp-network'
  location: policyLocation
  kind: 'NetworkInjection'
  tags: tags
  properties: {
    networkInjection: {
      virtualNetworks: [for (r, i) in regions: {
        id: ppVnets[i].id
        subnet: { name: subnetName }
      }]
    }
  }
}

// A linked policy cannot be updated (EnterprisePolicyUpdateNotAllowed), not even with identical
// values: after linking, redeploy with manageEnterprisePolicy=false to change only the network.
#disable-next-line BCP081
resource existingPolicy 'Microsoft.PowerPlatform/enterprisePolicies@2020-10-30' existing = if (!manageEnterprisePolicy) {
  name: '${namePrefix}-pp-network'
}

output policyId string = manageEnterprisePolicy ? policy!.id : existingPolicy!.id
#disable-next-line BCP053
output policySystemId string = manageEnterprisePolicy ? policy!.properties.systemId : existingPolicy!.properties.systemId
output ppSubnetPrefixes array = [primarySubnet, secondarySubnet]
