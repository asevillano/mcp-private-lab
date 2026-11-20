<#
Power Platform VNet diagnostics using Azure CLI tokens (no Az PowerShell needed).
Calls the same /plex endpoints as Test-DnsResolution, Test-NetworkConnectivity and
Test-TLSHandshake from Microsoft.PowerPlatform.EnterprisePolicies. The request runs
inside a container of the environment's delegated subnet in the chosen region.
EnvironmentId and Regions default to config/lab.config.json (powerPlatform.*).
#>
param(
    [Parameter(Mandatory)] [string] $HostName,
    [string] $EnvironmentId,
    [string[]] $Regions,
    [int] $Port = 443,
    [string] $OutFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-config.ps1')
$EnvironmentId = Get-LabSetting 'powerPlatform.environmentId' $EnvironmentId
$Regions = @(Get-LabSetting 'powerPlatform.regions' $Regions)

$token = az account get-access-token --resource https://api.powerplatform.com --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not get a token for https://api.powerplatform.com' }

$compact = $EnvironmentId.Replace('-', '')
$routeHost = '{0}.{1}.environment.api.powerplatform.com' -f $compact.Substring(0, $compact.Length - 2), $compact.Substring($compact.Length - 2)
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

function Invoke-Plex([string] $Path, [string] $Region, [hashtable] $Body) {
    $uri = "https://$routeHost$Path`?api-version=2026-02-01&region=$Region"
    try {
        Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body ($Body | ConvertTo-Json) -TimeoutSec 120
    } catch {
        [pscustomobject]@{
            error = $_.Exception.Message
            status = $_.Exception.Response.StatusCode.value__
            body = $_.ErrorDetails.Message
        }
    }
}

$results = foreach ($region in $Regions) {
    [pscustomobject]@{
        region = $region
        timeUtc = (Get-Date).ToUniversalTime().ToString('o')
        dns = Invoke-Plex '/plex/resolveDns' $region @{ HostName = $HostName }
        tcp = Invoke-Plex '/plex/testConnection' $region @{ Destination = $HostName; Port = "$Port" }
        tls = Invoke-Plex '/plex/testTLSConnection' $region @{ Destination = $HostName; Port = "$Port" }
    }
}
$json = $results | ConvertTo-Json -Depth 8
if ($OutFile) { $json | Set-Content -LiteralPath $OutFile -Encoding utf8 }
$json
