<#
Network negative test: temporarily removes the Power Platform delegated subnets from the
MCP ingress allow list (Block) and restores them (Allow). While blocked, a tool call from
the agent must fail and NO event must reach the MCP container, proving the connector
traffic really travels through the delegated subnets. Always run -Mode Allow afterwards.
App, ResourceGroup and the delegated CIDRs default to config/lab.config.json.
Rule names allow-1/allow-2 match the order of allowedSourceCidrs in app.bicep (ACA subnet first).
#>
param(
    [Parameter(Mandatory)] [ValidateSet('Block', 'Allow', 'Show')] [string] $Mode,
    [string] $App,
    [string] $ResourceGroup
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-config.ps1')
$App = Get-LabSetting 'mcp.appName' $App
$ResourceGroup = Get-LabSetting 'azure.resourceGroup' $ResourceGroup
$ppCidrs = @(Get-LabSetting 'powerPlatform.delegatedSubnetCidrs')
$ppRules = [ordered]@{}
for ($i = 0; $i -lt $ppCidrs.Count; $i++) { $ppRules["allow-$($i + 1)"] = $ppCidrs[$i] }
switch ($Mode) {
    'Block' {
        foreach ($name in $ppRules.Keys) {
            az containerapp ingress access-restriction remove -n $App -g $ResourceGroup --rule-name $name -o none
        }
    }
    'Allow' {
        foreach ($name in $ppRules.Keys) {
            az containerapp ingress access-restriction set -n $App -g $ResourceGroup --rule-name $name `
                --ip-address $ppRules[$name] --action Allow -o none
        }
    }
}
az containerapp ingress access-restriction list -n $App -g $ResourceGroup --query '[].{name:name,range:ipAddressRange}' -o table
