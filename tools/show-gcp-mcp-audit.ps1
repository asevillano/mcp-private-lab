<#
MCP audit for the GCP-hosted MCP (Cloud Run): reads the structured request logs that the MCP writes
to stdout (Cloud Logging jsonPayload) and resolves each caller's Entra object ID to its UPN.
Equivalent of show-mcp-audit.ps1 (Log Analytics) for the Azure-hosted MCP.
Project and Service default to config/lab.config.json (gcp.*).
#>
param(
    [int] $Minutes = 60,
    [string] $Project,
    [string] $Service,
    [string] $OutFile
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lab-config.ps1')
$Project = Get-LabSetting 'gcp.projectId' $Project
$Service = Get-LabSetting 'gcp.cloudRunService' $Service
$since = (Get-Date).ToUniversalTime().AddMinutes(-$Minutes).ToString('yyyy-MM-ddTHH:mm:ssZ')
$filter = "resource.type=`"cloud_run_revision`" AND resource.labels.service_name=`"$Service`" AND " +
          "jsonPayload.event=(`"http`" OR `"auth_rejected`" OR `"permission_denied`") AND " +
          "NOT jsonPayload.path=`"/healthz`" AND timestamp>=`"$since`""
$entries = gcloud logging read $filter --project $Project --order=asc --limit=500 --format=json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'gcloud logging read failed' }

$names = @{}
$rows = foreach ($e in $entries) {
    $p = $e.jsonPayload
    if ($p.objectId -and -not $names.ContainsKey($p.objectId)) {
        $upn = az ad user show --id $p.objectId --query userPrincipalName -o tsv 2>$null
        if (-not $upn) { $upn = az ad sp show --id $p.objectId --query displayName -o tsv 2>$null }
        $names[$p.objectId] = $upn
    }
    [pscustomobject]@{
        TimeUtc   = ([datetimeoffset]$e.timestamp).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')
        event     = $p.event; method = $p.method; status = $p.status; mode = $p.identityMode
        user      = if ($p.objectId) { $names[$p.objectId] } else { '' }
        clientId  = $p.clientId; reason = $p.reason; requestId = $p.requestId
    }
}
if ($OutFile) { $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding utf8 }
$rows | Format-Table TimeUtc, event, method, status, mode, user, clientId, reason -AutoSize
