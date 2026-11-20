<#
Deploys (or previews with -WhatIf) the MCP Container App and its probe job using the
outputs of the foundation deployment (infra/main.bicep). Centralises the parameters that
change during the lab: image tag, allowed source subnets and allowed OAuth client IDs.
Parameters not passed are read from config/lab.config.json (see tools/lab-config.ps1).
#>
param(
    [string] $ResourceGroup,
    [string] $FoundationDeployment,
    [string] $Location,
    [string] $AppName,
    [string] $ImageName,
    [string] $ImageTag,
    [string] $TenantId,
    [string] $ApiClientId,
    # ACA subnet (probe job) + Power Platform delegated subnets.
    [string[]] $AllowedSourceCidrs,
    # OAuth client of the Copilot Studio connector. Default: entra.connectorClientId. @() = no delegated access.
    [string[]] $AllowedClientIds,
    # Shown by the tool as "runtime" (same field as the GCP Cloud Run instance).
    [string] $McpRuntime,
    [switch] $WhatIf
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'lab-config.ps1')
$ResourceGroup = Get-LabSetting 'azure.resourceGroup' $ResourceGroup
$FoundationDeployment = Get-LabSetting 'azure.foundationDeployment' $FoundationDeployment
$Location = Get-LabSetting 'azure.location' $Location
$AppName = Get-LabSetting 'mcp.appName' $AppName
$ImageName = Get-LabSetting 'mcp.imageName' $ImageName
$ImageTag = Get-LabSetting 'mcp.imageTag' $ImageTag
$TenantId = Get-LabSetting 'tenantId' $TenantId
$ApiClientId = Get-LabSetting 'entra.apiClientId' $ApiClientId
if (-not $AllowedSourceCidrs) {
    $AllowedSourceCidrs = @(Get-LabSetting 'azure.acaSubnetCidr') + @(Get-LabSetting 'powerPlatform.delegatedSubnetCidrs')
}
$AllowedClientIds = if ($PSBoundParameters.ContainsKey('AllowedClientIds')) { @($AllowedClientIds) } else {
    @(Get-LabSetting 'entra.connectorClientId')
}
$McpRuntime = Get-LabSetting 'mcp.runtime' $McpRuntime

$o = az deployment group show -g $ResourceGroup -n $FoundationDeployment --query properties.outputs -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $o) { throw "Foundation deployment '$FoundationDeployment' not found" }

$params = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        location = @{ value = $Location }
        environmentId = @{ value = $o.environmentId.value }
        environmentDomain = @{ value = $o.environmentDomain.value }
        identityId = @{ value = $o.identityId.value }
        probeIdentityId = @{ value = $o.probeIdentityId.value }
        probeClientId = @{ value = $o.probeClientId.value }
        registryServer = @{ value = $o.registryServer.value }
        image = @{ value = "$($o.registryServer.value)/${ImageName}:$ImageTag" }
        appName = @{ value = $AppName }
        tenantId = @{ value = $TenantId }
        apiClientId = @{ value = $ApiClientId }
        allowedSourceCidrs = @{ value = @($AllowedSourceCidrs) }
        allowedClientIds = @{ value = ($AllowedClientIds -join ',') }
        mcpRuntime = @{ value = $McpRuntime }
    }
}
$file = Join-Path $env:TEMP "$AppName-app.parameters.json"
$params | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding utf8
try {
    $template = Join-Path $root 'infra\app.bicep'
    if ($WhatIf) {
        az deployment group what-if -g $ResourceGroup --template-file $template --parameters "@$file"
    } else {
        az deployment group create -g $ResourceGroup -n "mcp-app-$ImageTag" --template-file $template --parameters "@$file" `
            --query '{state:properties.provisioningState,mcpUrl:properties.outputs.mcpUrl.value}' -o json
    }
    if ($LASTEXITCODE -ne 0) { throw 'Deployment failed' }
} finally {
    Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
}
