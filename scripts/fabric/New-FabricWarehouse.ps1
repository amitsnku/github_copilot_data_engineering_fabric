<#
.SYNOPSIS
Create a new Warehouse in a Fabric workspace (idempotent).

.DESCRIPTION
Uses Fabric REST API v1 to create a warehouse.
If a warehouse with the same name already exists, skips creation.

.PARAMETER WorkspaceId
Required. The Fabric workspace ID (GUID).
Can also be set via $env:FABRIC_WORKSPACE_ID.

.PARAMETER WarehouseName
Required. The display name for the new warehouse.

.PARAMETER Description
Optional. Description for the warehouse.

.EXAMPLE
$env:FABRIC_WORKSPACE_ID = "12345678-..."
.\New-FabricWarehouse.ps1 -WarehouseName "ou_copilot_dw_poc"
#>

param(
    [string]$WorkspaceId = $env:FABRIC_WORKSPACE_ID,
    [Parameter(Mandatory=$true)]
    [string]$WarehouseName,
    [string]$Description = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    throw "WorkspaceId is required. Pass -WorkspaceId or set `$env:FABRIC_WORKSPACE_ID"
}

$token   = & "$PSScriptRoot\Get-FabricToken.ps1"
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# Check if warehouse already exists
$existingItems = Invoke-RestMethod -Method Get `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items" `
    -Headers $headers

$existing = $existingItems.value | Where-Object { $_.displayName -eq $WarehouseName -and $_.type -eq "Warehouse" }

if ($existing) {
    Write-Host "Warehouse '$WarehouseName' already exists (ID: $($existing.id)). Skipping creation."
    Write-Output $existing
    return
}

# Create warehouse
$body = @{
    displayName = $WarehouseName
    type        = "Warehouse"
    description = $Description
} | ConvertTo-Json

$response = Invoke-RestMethod -Method Post `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/warehouses" `
    -Headers $headers `
    -Body $body

Write-Host "Warehouse '$WarehouseName' created successfully (ID: $($response.id))"
Write-Output $response
