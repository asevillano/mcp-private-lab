// Azure VPN Gateway (route-based, BGP) in an existing VNet that already has a GatewaySubnet.
// Used as the hub that connects the Power Platform delegated subnets (gateway transit) with an
// external network, e.g. Google Cloud HA VPN. Custom APIPA BGP addresses follow the Google Cloud
// guide for HA VPN to Azure (169.254.21.0/30 and 169.254.22.0/30 per tunnel).
param location string = 'northeurope'
param vnetName string = 'mcp-lab-vnet'
param gatewayName string = 'mcp-lab-vpngw'
param sku string = 'VpnGw1AZ'
param asn int = 65515
@description('Azure side APIPA BGP addresses, one per tunnel/remote interface.')
param customBgpIpAddresses array = ['169.254.21.1', '169.254.22.1']

var tags = { purpose: 'MCP-OAuth-private-PoC', data: 'synthetic-only' }

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${gatewayName}-pip'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Regional' }
  zones: ['1', '2', '3']
  properties: { publicIPAllocationMethod: 'Static' }
}

resource gateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' = {
  name: gatewayName
  location: location
  tags: tags
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    sku: { name: sku, tier: sku }
    activeActive: false
    enableBgp: true
    bgpSettings: {
      asn: asn
      bgpPeeringAddresses: [{
        ipconfigurationId: resourceId('Microsoft.Network/virtualNetworkGateways/ipConfigurations', gatewayName, 'default')
        customBgpIpAddresses: customBgpIpAddresses
      }]
    }
    ipConfigurations: [{
      name: 'default'
      properties: {
        privateIPAllocationMethod: 'Dynamic'
        subnet: { id: '${vnet.id}/subnets/GatewaySubnet' }
        publicIPAddress: { id: pip.id }
      }
    }]
  }
}

output gatewayId string = gateway.id
output publicIp string = pip.properties.ipAddress
output asn int = asn
