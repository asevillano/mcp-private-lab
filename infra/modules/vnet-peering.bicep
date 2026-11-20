// Peering created on an existing VNet (deployed in the VNet's own resource group/subscription).
param vnetName string
param peeringName string
param remoteVnetId string
param allowGatewayTransit bool = false
param useRemoteGateways bool = false
param allowForwardedTraffic bool = false

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: vnet
  name: peeringName
  properties: {
    remoteVirtualNetwork: { id: remoteVnetId }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
  }
}
