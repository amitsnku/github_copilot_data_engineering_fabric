<#
.SYNOPSIS
Update a Fabric Pipeline's definition with notebook activities.

.DESCRIPTION
Builds a sequential pipeline definition (3 notebook activities) and uploads
it to the specified pipeline using the Fabric REST API updateDefinition endpoint.

.PARAMETER WorkspaceId
Required. The Fabric workspace ID. Can also be set via $env:FABRIC_WORKSPACE_ID.

.PARAMETER PipelineId
Required. The GUID of the pipeline to update.

.PARAMETER Notebook1Id
Required. GUID of the first notebook (raw data setup).

.PARAMETER Notebook2Id
Required. GUID of the second notebook (quality + silver).

.PARAMETER Notebook3Id
Required. GUID of the third notebook (semantic views).

.EXAMPLE
.\Update-FabricPipelineDefinition.ps1 -PipelineId "abc" `
    -Notebook1Id "id1" -Notebook2Id "id2" -Notebook3Id "id3"
#>

param(
    [string]$WorkspaceId  = $env:FABRIC_WORKSPACE_ID,
    [Parameter(Mandatory=$true)][string]$PipelineId,
    [Parameter(Mandatory=$true)][string]$Notebook1Id,
    [Parameter(Mandatory=$true)][string]$Notebook2Id,
    [Parameter(Mandatory=$true)][string]$Notebook3Id
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkspaceId)) {
    throw "WorkspaceId is required. Pass -WorkspaceId or set `$env:FABRIC_WORKSPACE_ID"
}

$token   = & "$PSScriptRoot\Get-FabricToken.ps1"
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# Build pipeline definition with 3 sequential notebook activities
$pipelineDef = @{
    properties = @{
        activities = @(
            @{
                name      = "01_RawDataSetup"
                type      = "TridentNotebook"
                dependsOn = @()
                policy    = @{
                    timeout                = "0.12:00:00"
                    retry                  = 1
                    retryIntervalInSeconds = 60
                    secureOutput           = $false
                    secureInput            = $false
                }
                typeProperties = @{
                    notebookId  = $Notebook1Id
                    workspaceId = $WorkspaceId
                }
            },
            @{
                name      = "02_QualityAndSilver"
                type      = "TridentNotebook"
                dependsOn = @(
                    @{
                        activity             = "01_RawDataSetup"
                        dependencyConditions = @("Succeeded")
                    }
                )
                policy    = @{
                    timeout                = "0.12:00:00"
                    retry                  = 1
                    retryIntervalInSeconds = 60
                    secureOutput           = $false
                    secureInput            = $false
                }
                typeProperties = @{
                    notebookId  = $Notebook2Id
                    workspaceId = $WorkspaceId
                }
            },
            @{
                name      = "03_SemanticViews"
                type      = "TridentNotebook"
                dependsOn = @(
                    @{
                        activity             = "02_QualityAndSilver"
                        dependencyConditions = @("Succeeded")
                    }
                )
                policy    = @{
                    timeout                = "0.12:00:00"
                    retry                  = 1
                    retryIntervalInSeconds = 60
                    secureOutput           = $false
                    secureInput            = $false
                }
                typeProperties = @{
                    notebookId  = $Notebook3Id
                    workspaceId = $WorkspaceId
                }
            }
        )
        annotations = @()
        concurrency = 1
        parameters  = @{}
        variables   = @{}
    }
} | ConvertTo-Json -Depth 20 -Compress

$encodedDef = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pipelineDef))

$body = @{
    definition = @{
        parts = @(
            @{
                path        = "pipeline-content.json"
                payload     = $encodedDef
                payloadType = "InlineBase64"
            }
        )
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Post `
    -Uri "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/dataPipelines/$PipelineId/updateDefinition" `
    -Headers $headers `
    -Body $body | Out-Null

Write-Host "Pipeline '$PipelineId' definition updated with 3 sequential notebook activities."
