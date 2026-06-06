<#
.SYNOPSIS
List all items in a Fabric workspace.

.DESCRIPTION
Uses Fabric REST API v1 to retrieve workspace items.
Displays id, displayName, and type for each item.

.PARAMETER WorkspaceId
Required. The Fabric workspace ID (GUID).
Can also be set via $env:FABRIC_WORKSPACE_ID environment variable.

.EXAMPLE
.\Get-FabricItems.ps1 -WorkspaceId "12345678-1234-1234-1234-123456789012"

.EXAMPLE
$env:FABRIC_WORKSPACE_ID = "12345678-1234-1234-1234-123456789012"
.\Get-FabricItems.ps1
#>

param(
    [string]$WorkspaceId = $env:FABRIC_WORKSPACE_ID
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    throw "WorkspaceId is required. Pass -WorkspaceId or set `$env:FABRIC_WORKSPACE_ID"
}

$token = & "$PSScriptRoot\Get-FabricToken.ps1"
$headers = @{ Authorization = "Bearer $token" }

$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items"
$response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers

if ($response.value) {
    Write-Host "Workspace Items:"
    $response.value | Select-Object id, displayName, type | Format-Table -AutoSize
    Write-Host "Total items: $($response.value.Count)"
} else {
    Write-Host "No items found in workspace."
}

Write-Output $response
