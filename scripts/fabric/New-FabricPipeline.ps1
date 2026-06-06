<#
.SYNOPSIS
Create a new Pipeline in a Fabric workspace (idempotent).

.DESCRIPTION
Uses Fabric REST API v1 to create a pipeline.
If a pipeline with the same name already exists, skips creation.

.PARAMETER WorkspaceId
Required. The Fabric workspace ID (GUID).
Can also be set via $env:FABRIC_WORKSPACE_ID environment variable.

.PARAMETER PipelineName
Required. The display name for the new pipeline.

.PARAMETER Description
Optional. Description for the pipeline.

.EXAMPLE
.\New-FabricPipeline.ps1 -WorkspaceId "12345678-1234-1234-1234-123456789012" -PipelineName "MyPipeline"

.EXAMPLE
$env:FABRIC_WORKSPACE_ID = "12345678-1234-1234-1234-123456789012"
.\New-FabricPipeline.ps1 -PipelineName "ETLPipeline" -Description "Daily bronze-to-silver transformation"
#>

param(
    [string]$WorkspaceId = $env:FABRIC_WORKSPACE_ID,
    [Parameter(Mandatory=$true)]
    [string]$PipelineName,
    [string]$Description = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    throw "WorkspaceId is required. Pass -WorkspaceId or set `$env:FABRIC_WORKSPACE_ID"
}

$token = & "$PSScriptRoot\Get-FabricToken.ps1"
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# Check if pipeline already exists
$existingItems = Invoke-RestMethod -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items" -Headers $headers
$existingPipeline = $existingItems.value | Where-Object { $_.displayName -eq $PipelineName -and $_.type -eq "Pipeline" }

if ($existingPipeline) {
    Write-Host "Pipeline '$PipelineName' already exists (ID: $($existingPipeline.id)). Skipping creation."
    Write-Output $existingPipeline
    return
}

# Create pipeline
$body = @{
    displayName = $PipelineName
    type = "Pipeline"
    description = $Description
} | ConvertTo-Json

$uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items"
$response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body

Write-Host "Pipeline '$PipelineName' created successfully (ID: $($response.id))"
Write-Output $response
