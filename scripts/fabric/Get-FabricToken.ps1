<#
.SYNOPSIS
Retrieve a fresh Fabric API access token using current az login session.

.DESCRIPTION
Calls 'az account get-access-token' with Fabric resource scope.
Returns the token string or throws error if unavailable.

.PARAMETER ResourceId
Optional. The Azure resource ID to request token for. 
Defaults to Fabric API: https://api.fabric.microsoft.com

.EXAMPLE
$token = .\Get-FabricToken.ps1
#>

param(
    [string]$ResourceId = "https://api.fabric.microsoft.com"
)

$ErrorActionPreference = "Stop"

$token = az account get-access-token --resource $ResourceId --query accessToken --output tsv

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Failed to obtain Fabric access token. Ensure you have run 'az login' and have access to Fabric API."
}

Write-Output $token
