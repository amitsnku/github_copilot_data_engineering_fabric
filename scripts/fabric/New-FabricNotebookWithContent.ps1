<#
.SYNOPSIS
Create a Fabric Notebook and upload its content from a local .ipynb file (idempotent).

.DESCRIPTION
Reads a local .ipynb file, base64-encodes it, and creates (or updates) the notebook
in the specified Fabric workspace using the item definition API.

.PARAMETER WorkspaceId
Required. The Fabric workspace ID. Can also be set via $env:FABRIC_WORKSPACE_ID.

.PARAMETER NotebookName
Required. The display name for the notebook.

.PARAMETER NotebookPath
Required. Full path to the local .ipynb file.

.PARAMETER Description
Optional. Description for the notebook.

.EXAMPLE
.\New-FabricNotebookWithContent.ps1 -NotebookName "nb_01_raw_data_setup" `
    -NotebookPath ".\notebooks\nb_01_raw_data_setup.ipynb"
#>

param(
    [string]$WorkspaceId  = $env:FABRIC_WORKSPACE_ID,
    [Parameter(Mandatory=$true)][string]$NotebookName,
    [Parameter(Mandatory=$true)][string]$NotebookPath,
    [string]$Description  = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    throw "WorkspaceId is required. Pass -WorkspaceId or set `$env:FABRIC_WORKSPACE_ID"
}

if (-not (Test-Path $NotebookPath)) {
    throw "Notebook file not found: $NotebookPath"
}

$token   = & "$PSScriptRoot\Get-FabricToken.ps1"
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# Check if notebook already exists
$existingItems = Invoke-RestMethod -Method Get `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items" `
    -Headers $headers

$existing = $existingItems.value | Where-Object { $_.displayName -eq $NotebookName -and $_.type -eq "Notebook" }

# Base64 encode the notebook content
$notebookContent = Get-Content -Path $NotebookPath -Raw -Encoding UTF8
$encodedContent  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($notebookContent))

if ($existing) {
    Write-Host "Notebook '$NotebookName' exists (ID: $($existing.id)). Updating definition..."

    $updateBody = @{
        definition = @{
            parts = @(
                @{
                    path        = "notebook-content.py"
                    payload     = $encodedContent
                    payloadType = "InlineBase64"
                }
            )
        }
    } | ConvertTo-Json -Depth 10

    Invoke-RestMethod -Method Post `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/notebooks/$($existing.id)/updateDefinition" `
        -Headers $headers `
        -Body $updateBody | Out-Null

    Write-Host "Notebook '$NotebookName' definition updated."
    Write-Output $existing
    return
}

# Create notebook with definition
$body = @{
    displayName = $NotebookName
    type        = "Notebook"
    description = $Description
    definition  = @{
        parts = @(
            @{
                path        = "notebook-content.py"
                payload     = $encodedContent
                payloadType = "InlineBase64"
            }
        )
    }
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod -Method Post `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items" `
    -Headers $headers `
    -Body $body

Write-Host "Notebook '$NotebookName' created successfully (ID: $($response.id))"
Write-Output $response
