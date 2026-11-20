<#
Shows MCP audit events from Log Analytics for the last N minutes, resolving the Entra
object ID of each caller to its UPN, so every Teams/Copilot Studio call can be tied to
a test user. Health probes are excluded. Ingestion delay is usually 2-5 minutes.
WorkspaceId and AppName default to config/lab.config.json.
#>
param(
    [int] $Minutes = 60,
    [string] $WorkspaceId,
    [string] $AppName,
    [string] $OutFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-config.ps1')
$WorkspaceId = Get-LabSetting 'azure.logAnalyticsWorkspaceId' $WorkspaceId
$AppName = Get-LabSetting 'mcp.appName' $AppName
$kql = @"
ContainerAppConsoleLogs_CL
| where ContainerAppName_s == '$AppName'
| where Log_s has_any ('/mcp', 'permission_denied', 'auth_rejected')
| extend e = parse_json(Log_s)
| project TimeGenerated, event = tostring(e.event), method = tostring(e.method), status = toint(e.status),
          mode = tostring(e.identityMode), objectId = tostring(e.objectId), clientId = tostring(e.clientId),
          reason = tostring(e.reason), requestId = tostring(e.requestId)
| order by TimeGenerated asc
"@
$body = Join-Path $env:TEMP 'mcp-audit-query.json'
@{ query = $kql; timespan = "PT${Minutes}M" } | ConvertTo-Json | Set-Content $body -Encoding ascii
try {
    $r = az rest --method POST --headers Content-Type=application/json --resource https://api.loganalytics.io `
        --url "https://api.loganalytics.io/v1/workspaces/$WorkspaceId/query" --body "@$body" -o json | ConvertFrom-Json
} finally { Remove-Item $body -ErrorAction SilentlyContinue }

$cols = $r.tables[0].columns.name
$names = @{}
$rows = foreach ($row in $r.tables[0].rows) {
    $o = [ordered]@{}
    for ($i = 0; $i -lt $cols.Count; $i++) { $o[$cols[$i]] = $row[$i] }
    if ($o.objectId -and -not $names.ContainsKey($o.objectId)) {
        $upn = az ad user show --id $o.objectId --query userPrincipalName -o tsv 2>$null
        if (-not $upn) { $upn = az ad sp show --id $o.objectId --query displayName -o tsv 2>$null }
        $names[$o.objectId] = $upn
    }
    $o.user = if ($o.objectId) { $names[$o.objectId] } else { '' }
    [pscustomobject]$o
}
if ($OutFile) { $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding utf8 }
$rows | Format-Table TimeGenerated, event, method, status, mode, user, clientId, reason -AutoSize
