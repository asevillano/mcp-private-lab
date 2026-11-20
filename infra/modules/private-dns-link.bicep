// Links an existing private DNS zone (in its own resource group) to a VNet.
param zoneName string
param linkName string
param vnetId string

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
  name: zoneName
}

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: linkName
  location: 'global'
  properties: { registrationEnabled: false, virtualNetwork: { id: vnetId } }
}
