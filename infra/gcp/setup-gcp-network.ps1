<#
Google Cloud side of the "MCP in GCP" scenario (idempotent; skips what already exists):
  1. Custom VPC + subnet with Private Google Access.
  2. Private Service Connect endpoint for Google APIs (all-apis). Cloud Run *.run.app URLs are
     reached through this private IP from Azure, so a Cloud Run service with ingress=internal
     is callable over the VPN while keeping its Google Trust Services (public CA) certificate.
  3. HA VPN gateway + Cloud Router (BGP) advertising the subnet and the PSC endpoint /32.
  4. External VPN gateway (Azure VPN Gateway public IP) and two tunnels with BGP sessions
     (APIPA 169.254.21.0/30 and 169.254.22.0/30, matching infra/vpn-gateway.bicep).

The IPsec pre-shared key is generated once and stored encrypted with Windows DPAPI
(current user only) at $PskFile, never printed nor written to the repository.
Parameters not passed are read from config/lab.config.json (gcp.*).
#>
param(
    [string] $Project,
    [string] $Region,
    [string] $Prefix,
    [string] $SubnetRange,
    [string] $PscAddress,
    [string] $PscName,          # 1-20 chars, lowercase letters/digits only
    [int] $RouterAsn,
    [string] $AzureGatewayIp,
    [int] $AzureAsn,
    [string] $PskFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\tools\lab-config.ps1')
$Project = Get-LabSetting 'gcp.projectId' $Project
$Region = Get-LabSetting 'gcp.region' $Region 'europe-west1'
$Prefix = Get-LabSetting 'gcp.prefix' $Prefix 'mcp-lab'
$SubnetRange = Get-LabSetting 'gcp.subnetRange' $SubnetRange '10.95.0.0/24'
$PscAddress = Get-LabSetting 'gcp.pscAddress' $PscAddress '10.96.0.10'
$PscName = Get-LabSetting 'gcp.pscName' $PscName 'mcplabpsc'
$RouterAsn = Get-LabSetting 'gcp.routerAsn' $PSBoundParameters['RouterAsn'] 64514
$AzureGatewayIp = Get-LabSetting 'gcp.azureVpnGatewayIp' $AzureGatewayIp
$AzureAsn = Get-LabSetting 'gcp.azureAsn' $PSBoundParameters['AzureAsn'] 65515
$PskFile = [Environment]::ExpandEnvironmentVariables(
    (Get-LabSetting 'gcp.pskFile' $PskFile (Join-Path $env:LOCALAPPDATA 'mcp-lab\vpn-psk.clixml')))
$common = @('--project', $Project, '--quiet')
function Exists([string[]] $describeArgs) {
    & gcloud @describeArgs @common --format='value(name)' 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}
function Run([string[]] $gcloudArgs) {
    & gcloud @gcloudArgs @common 2>&1 | Select-Object -Last 1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "gcloud failed: $($gcloudArgs -join ' ')" }
}
$vpc = "$Prefix-vpc"; $subnet = "$Prefix-subnet"; $havpn = "$Prefix-havpn"; $router = "$Prefix-router"
$extgw = "$Prefix-azure-gw"

Write-Host "1. VPC $vpc / subnet $subnet ($SubnetRange)"
if (-not (Exists @('compute','networks','describe',$vpc))) {
    Run @('compute','networks','create',$vpc,'--subnet-mode=custom','--bgp-routing-mode=global')
}
if (-not (Exists @('compute','networks','subnets','describe',$subnet,"--region=$Region"))) {
    Run @('compute','networks','subnets','create',$subnet,"--network=$vpc","--region=$Region","--range=$SubnetRange",'--enable-private-ip-google-access')
}

Write-Host "2. PSC endpoint for Google APIs $PscName ($PscAddress)"
if (-not (Exists @('compute','addresses','describe',"$PscName-ip",'--global'))) {
    Run @('compute','addresses','create',"$PscName-ip",'--global','--purpose=PRIVATE_SERVICE_CONNECT',"--addresses=$PscAddress","--network=$vpc")
}
if (-not (Exists @('compute','forwarding-rules','describe',$PscName,'--global'))) {
    Run @('compute','forwarding-rules','create',$PscName,'--global',"--network=$vpc","--address=$PscName-ip",'--target-google-apis-bundle=all-apis')
}

Write-Host "3. HA VPN $havpn + Cloud Router $router (ASN $RouterAsn)"
if (-not (Exists @('compute','vpn-gateways','describe',$havpn,"--region=$Region"))) {
    Run @('compute','vpn-gateways','create',$havpn,"--network=$vpc","--region=$Region",'--stack-type=IPV4_ONLY')
}
if (-not (Exists @('compute','routers','describe',$router,"--region=$Region"))) {
    Run @('compute','routers','create',$router,"--network=$vpc","--region=$Region","--asn=$RouterAsn",
        '--advertisement-mode=custom','--set-advertisement-groups=all_subnets',"--set-advertisement-ranges=$PscAddress/32")
}

Write-Host "4. External gateway $extgw ($AzureGatewayIp) and tunnels"
if (-not (Exists @('compute','external-vpn-gateways','describe',$extgw))) {
    Run @('compute','external-vpn-gateways','create',$extgw,"--interfaces=0=$AzureGatewayIp")
}
if (-not (Test-Path $PskFile)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $PskFile) | Out-Null
    $bytes = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $plain = [Convert]::ToBase64String($bytes) -replace '[+/=]', 'x'
    ConvertTo-SecureString $plain -AsPlainText -Force | Export-Clixml -LiteralPath $PskFile
    Remove-Variable plain, bytes
    Write-Host "  PSK generated and stored (DPAPI) at $PskFile"
}
$psk = [Net.NetworkCredential]::new('', (Import-Clixml -LiteralPath $PskFile)).Password

$tunnels = @(
    @{ name = "$Prefix-tunnel0"; iface = 0; local = '169.254.21.2'; peer = '169.254.21.1' },
    @{ name = "$Prefix-tunnel1"; iface = 1; local = '169.254.22.2'; peer = '169.254.22.1' }
)
foreach ($t in $tunnels) {
    if (-not (Exists @('compute','vpn-tunnels','describe',$t.name,"--region=$Region"))) {
        Run @('compute','vpn-tunnels','create',$t.name,"--region=$Region","--vpn-gateway=$havpn","--interface=$($t.iface)",
            "--peer-external-gateway=$extgw",'--peer-external-gateway-interface=0',"--shared-secret=$psk",
            "--router=$router",'--ike-version=2')
    }
    $bgpIf = "$($t.name)-if"
    $routerJson = gcloud compute routers describe $router "--region=$Region" @common --format=json | ConvertFrom-Json
    if (-not ($routerJson.interfaces | Where-Object name -eq $bgpIf)) {
        Run @('compute','routers','add-interface',$router,"--region=$Region","--interface-name=$bgpIf",
            "--ip-address=$($t.local)",'--mask-length=30',"--vpn-tunnel=$($t.name)")
    }
    if (-not ($routerJson.bgpPeers | Where-Object name -eq "$($t.name)-peer")) {
        Run @('compute','routers','add-bgp-peer',$router,"--region=$Region","--peer-name=$($t.name)-peer",
            "--interface=$bgpIf","--peer-ip-address=$($t.peer)","--peer-asn=$AzureAsn")
    }
}
Remove-Variable psk

$ips = gcloud compute vpn-gateways describe $havpn "--region=$Region" @common --format='value(vpnInterfaces[0].ipAddress,vpnInterfaces[1].ipAddress)'
[pscustomobject]@{
    vpc = $vpc; subnet = $SubnetRange; pscEndpoint = $PscAddress; routerAsn = $RouterAsn
    haVpnInterfaceIps = ($ips -split "`t") -join ', '
    tunnels = ($tunnels.name -join ', ')
}
