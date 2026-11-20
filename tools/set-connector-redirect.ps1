<#
Adds the connector callback URL shown by the Copilot Studio MCP wizard as a Web
redirect URI of the connector OAuth app, keeping any existing redirect URIs.
ClientAppId defaults to entra.connectorClientId in config/lab.config.json.
#>
param(
    [Parameter(Mandatory)] [ValidatePattern('^https://')] [string] $CallbackUrl,
    [string] $ClientAppId
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-config.ps1')
$ClientAppId = Get-LabSetting 'entra.connectorClientId' $ClientAppId
$current = @(az ad app show --id $ClientAppId --query 'web.redirectUris' -o json | ConvertFrom-Json)
$uris = @($current + $CallbackUrl | Where-Object { $_ } | Select-Object -Unique)
az ad app update --id $ClientAppId --web-redirect-uris @uris
if ($LASTEXITCODE -ne 0) { throw 'Redirect URI update failed' }
az ad app show --id $ClientAppId --query 'web.redirectUris' -o json
