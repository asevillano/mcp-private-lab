<#
Gives the members of an Entra security group read access to the solution custom connector
that the Copilot Studio MCP wizard creates, so end users can create their own connection.
Idempotent:
  1. Dataverse team of type "Microsoft Entra ID security group" linked to the group.
  2. Basic User security role on that team (localized name accepted).
  3. GrantAccess ReadAccess on the connector record to the team.
Without this, users see "Connector information unavailable" when connecting.
Parameters not passed are read from config/lab.config.json.
#>
param(
    [string] $OrgUrl,
    [string] $GroupObjectId,
    [string] $TeamName,
    [string] $ConnectorDisplayName,
    [string[]] $BasicUserRoleNames = @('Basic User', 'Usuario Basic', 'Usuario básico')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-config.ps1')
$OrgUrl = (Get-LabSetting 'powerPlatform.orgUrl' $OrgUrl).TrimEnd('/')
$GroupObjectId = Get-LabSetting 'entra.pilotGroupObjectId' $GroupObjectId
$TeamName = Get-LabSetting 'entra.pilotGroupName' $TeamName
$ConnectorDisplayName = Get-LabSetting 'powerPlatform.connectorDisplayName' $ConnectorDisplayName
$api = "$OrgUrl/api/data/v9.2"
$token = az account get-access-token --resource $OrgUrl --query accessToken -o tsv
if ($LASTEXITCODE -ne 0 -or -not $token) { throw "No token for $OrgUrl" }
$h = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json'; 'OData-Version' = '4.0'; Accept = 'application/json' }
function Get-Dv([string] $Path) { Invoke-RestMethod -Uri "$api/$Path" -Headers $h }

$bu = (Get-Dv 'businessunits?$select=businessunitid&$filter=_parentbusinessunitid_value eq null').value[0].businessunitid
$roles = (Get-Dv "roles?`$select=roleid,name&`$filter=_businessunitid_value eq $bu").value
$role = $roles | Where-Object { $_.name -in $BasicUserRoleNames } | Select-Object -First 1
if (-not $role) { throw 'Basic User role not found; pass -BasicUserRoleNames with the localized name' }

$team = (Get-Dv "teams?`$select=teamid,name&`$filter=azureactivedirectoryobjectid eq $GroupObjectId").value | Select-Object -First 1
if (-not $team) {
    $body = @{ name = $TeamName; teamtype = 2; membershiptype = 0; azureactivedirectoryobjectid = $GroupObjectId
               'businessunitid@odata.bind' = "/businessunits($bu)" } | ConvertTo-Json
    $hc = $h.Clone(); $hc.Prefer = 'return=representation'
    $team = Invoke-RestMethod -Method Post -Uri "$api/teams" -Headers $hc -Body $body
    Write-Host "Team created: $($team.teamid)"
} else { Write-Host "Team exists: $($team.teamid)" }

$assigned = (Get-Dv "teams($($team.teamid))/teamroles_association?`$select=roleid").value.roleid
if ($role.roleid -notin $assigned) {
    Invoke-RestMethod -Method Post -Uri "$api/teams($($team.teamid))/teamroles_association/`$ref" -Headers $h `
        -Body (@{ '@odata.id' = "$api/roles($($role.roleid))" } | ConvertTo-Json) | Out-Null
    Write-Host "Role assigned: $($role.name)"
} else { Write-Host "Role already assigned: $($role.name)" }

$connector = (Get-Dv "connectors?`$select=connectorid,displayname,connectorinternalid").value |
    Where-Object displayname -eq $ConnectorDisplayName | Select-Object -First 1
if (-not $connector) { throw "Connector '$ConnectorDisplayName' not found in $OrgUrl" }
$grant = @{
    Target = @{ connectorid = $connector.connectorid; '@odata.type' = 'Microsoft.Dynamics.CRM.connector' }
    PrincipalAccess = @{ Principal = @{ teamid = $team.teamid; '@odata.type' = 'Microsoft.Dynamics.CRM.team' }; AccessMask = 'ReadAccess' }
} | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method Post -Uri "$api/GrantAccess" -Headers $h -Body $grant | Out-Null

$shared = Invoke-RestMethod -Uri "$api/RetrieveSharedPrincipalsAndAccess(Target=@t)?@t={'@odata.id':'connectors($($connector.connectorid))'}" -Headers $h
[pscustomobject]@{
    team = $team.teamid
    role = $role.name
    connector = "$($connector.displayname) ($($connector.connectorinternalid))"
    sharedWith = ($shared.PrincipalAccesses | ForEach-Object { "$($_.Principal.ownerid):$($_.AccessMask)" }) -join '; '
}
