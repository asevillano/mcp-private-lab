<#
Shared helper, dot-sourced by the scripts in tools/ and infra/gcp/.

Values not passed as parameters are read from config/lab.config.json (ignored by git), or from
the file in $env:MCP_LAB_CONFIG. Template: config/lab.config.example.json. Values that still
look like "<PLACEHOLDER>" count as missing.
#>
$script:LabConfigPath = if ($env:MCP_LAB_CONFIG) { $env:MCP_LAB_CONFIG } else {
    Join-Path (Split-Path $PSScriptRoot -Parent) 'config\lab.config.json'
}
$script:LabConfig = $null

function Get-LabConfig {
    if ($null -eq $script:LabConfig -and (Test-Path -LiteralPath $script:LabConfigPath)) {
        $script:LabConfig = Get-Content -LiteralPath $script:LabConfigPath -Raw | ConvertFrom-Json
    }
    $script:LabConfig
}

function Test-LabValue($Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [array]) { return $Value.Count -gt 0 }
    "$Value" -ne '' -and "$Value" -notmatch '^<.*>$'
}

# Returns $Value when given; otherwise the setting at dotted $Path (e.g. 'azure.resourceGroup');
# otherwise $Default; otherwise throws a message that says what to fill in.
function Get-LabSetting([string] $Path, $Value, $Default) {
    if (Test-LabValue $Value) { return $Value }
    $node = Get-LabConfig
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $node) { break }
        $node = $node.$part
    }
    if (Test-LabValue $node) { return $node }
    if ($PSBoundParameters.ContainsKey('Default')) { return $Default }
    $where = if (Test-Path -LiteralPath $script:LabConfigPath) { "complete '$Path' in $script:LabConfigPath" } else {
        "create $script:LabConfigPath from config\lab.config.example.json"
    }
    throw "Missing setting '$Path': pass it as a parameter or $where."
}
