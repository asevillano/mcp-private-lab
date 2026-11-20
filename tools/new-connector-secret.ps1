<#
Creates a short-lived client secret for the connector OAuth app and copies it to the
clipboard without printing it. Paste it into the Copilot Studio MCP wizard, then clear
the clipboard. Existing credentials are kept (--append). ClientAppId defaults to
entra.connectorClientId in config/lab.config.json.
#>
param(
    [string] $ClientAppId,
    [int] $Days = 30
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-config.ps1')
$ClientAppId = Get-LabSetting 'entra.connectorClientId' $ClientAppId
$end = (Get-Date).ToUniversalTime().AddDays($Days).ToString('yyyy-MM-ddTHH:mm:ssZ')
$secret = az ad app credential reset --id $ClientAppId --append --display-name "copilot-studio-mcp-$(Get-Date -Format yyyyMMdd)" --end-date $end --query password -o tsv
if ($LASTEXITCODE -ne 0 -or -not $secret) { throw 'Secret creation failed' }
Set-Clipboard -Value $secret
Remove-Variable secret
Write-Host "Secret copied to clipboard (expires $end UTC). Paste it in the wizard, then run: Set-Clipboard -Value ' '"
