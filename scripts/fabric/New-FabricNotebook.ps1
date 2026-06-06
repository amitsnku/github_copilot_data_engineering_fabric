<#
.SYNOPSIS
Create a new Notebook in a Fabric workspace (idempotent).

.DESCRIPTION
Uses Fabric REST API v1 to create a notebook.
If a notebook with the same name already exists, skips creation.

.PARAMETER WorkspaceId
Required. The Fabric workspace ID (GUID).
Can also be set via $env:FABRIC_WORKSPACE_ID environment variable.

.PARAMETER NotebookName
Required. The display name for the new notebook.

.PARAMETER Description
Optional. Description for the notebook.

.EXAMPLE
.\New-FabricNotebook.ps1 -WorkspaceId "12345678-1234-1234-1234-123456789012" -NotebookName "MyNotebook"

.EXAMPLE
$env:FABRIC_WORKSPACE_ID = "12345678-1234-1234-1234-123456789012"
.\New-FabricNotebook.ps1 -NotebookName "DataEngineering" -Description "ETL transformations"
#>

param(
    [string]$WorkspaceId = $env:FABRIC_WORKSPACE_ID,
    [Parameter(Mandatory=$true)]
    [string]$NotebookName,
    [string]$Description = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    throw "WorkspaceId is required. Pass -WorkspaceId or set `$env:FABRIC_WORKSPACE_ID"
}

$token = & "$PSScriptRoot\Get-FabricToken.ps1"
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# Check if notebook already exists
$existingItems = Invoke-RestMethod -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items" -Headers $headers
$existingNotebook = $existingItems.value | Where-Object { $_.displayName -eq $NotebookName -and $_.type -eq "Notebook" }

if ($existingNotebook) {
    Write-Host "Notebook '$NotebookName' already exists (ID: $($existingNotebook.id)). Skipping creation."
    Write-Output $existingNotebook
    return
}

# Create notebook
$body = @{
    displayName = $NotebookName
    type = "Notebook"
    description = $Description
} | ConvertTo-Json

$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items"
$response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body

Write-Host "Notebook '$NotebookName' created successfully (ID: $($response.id))"
Write-Output $response
