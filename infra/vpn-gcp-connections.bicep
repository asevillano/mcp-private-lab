// IPsec/BGP connections from the Azure VPN Gateway to the two interfaces of a Google Cloud
// HA VPN gateway (one local network gateway + connection per interface), following the Google
// Cloud guide for HA VPN to Azure. The shared key is passed as a secure parameter only.
param location string = 'northeurope'
param gatewayName string = 'mcp-lab-vpngw'
param prefix string = 'mcp-lab-gcp'
param gcpAsn int = 64514
@description('Public IPs of the GCP HA VPN interfaces 0 and 1.')
param gcpInterfaceIps array
@secure()
param sharedKey string

var tags = { purpose: 'MCP-OAuth-private-PoC', data: 'synthetic-only' }
var tunnels = [
  { azureApipa: '169.254.21.1', gcpApipa: '169.254.21.2' }
  { azureApipa: '169.254.22.1', gcpApipa: '169.254.22.2' }
]

resource gateway 'Microsoft.Network/virtualNetworkGateways@2024-05-01' existing = {
  name: gatewayName
}

resource lngs 'Microsoft.Network/localNetworkGateways@2024-05-01' = [for (t, i) in tunnels: {
  name: '${prefix}-if${i}'
  location: location
  tags: tags
  properties: {
    gatewayIpAddress: gcpInterfaceIps[i]
    localNetworkAddressSpace: { addressPrefixes: [] }
    bgpSettings: { asn: gcpAsn, bgpPeeringAddress: t.gcpApipa }
  }
}]

resource connections 'Microsoft.Network/connections@2024-05-01' = [for (t, i) in tunnels: {
  name: '${prefix}-conn${i}'
  location: location
  tags: tags
  properties: {
    connectionType: 'IPsec'
    connectionProtocol: 'IKEv2'
    virtualNetworkGateway1: { id: gateway.id, properties: {} }
    localNetworkGateway2: { id: lngs[i].id, properties: {} }
    sharedKey: sharedKey
    enableBgp: true
    gatewayCustomBgpIpAddresses: [{
      ipConfigurationId: '${gateway.id}/ipConfigurations/default'
      customBgpIpAddress: t.azureApipa
    }]
  }
}]

output connectionNames array = [for (t, i) in tunnels: connections[i].name]
