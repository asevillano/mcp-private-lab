// Private DNS override for ONE Cloud Run URL: <service>-<project-number>.<region>.run.app -> PSC
// endpoint for Google APIs reached over the VPN. Scoping the zone to the exact host keeps every
// other *.run.app name resolving publicly. Linking a private zone does not change the VNet DNS
// servers, so it is allowed while the Power Platform enterprise policy is linked.
@description('Exact Cloud Run host, e.g. <service>-<project-number>.<region>.run.app (gcp.cloudRunHost in config/lab.config.json).')
param hostName string
param pscAddress string = '10.96.0.10'
@description('VNets that must resolve the MCP privately: lab hub (probe job) and both Power Platform VNets.')
param vnetIds array

var tags = { purpose: 'MCP-OAuth-private-PoC', data: 'synthetic-only' }

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: hostName
  location: 'global'
  tags: tags
}

resource apex 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: zone
  name: '@'
  properties: { ttl: 300, aRecords: [{ ipv4Address: pscAddress }] }
}

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for id in vnetIds: {
  parent: zone
  name: last(split(id, '/'))
  location: 'global'
  properties: { registrationEnabled: false, virtualNetwork: { id: id } }
}]

output fqdn string = hostName
