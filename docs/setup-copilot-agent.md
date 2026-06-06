# Setting Up GitHub Copilot Agent for Microsoft Fabric

This guide explains how to configure the **Fabric Data Engineer** custom Copilot agent in VS Code
so you can talk to Fabric in any repository — on any machine or workspace.

---

## What Is a Copilot Custom Agent?

A custom agent is a Markdown file placed in `.github/agents/` that teaches Copilot:
- **What it specialises in** (Fabric data engineering)
- **What tools it can use** (read, edit, execute scripts, search)
- **What rules to follow** (security guardrails, idempotency, no secrets)

Once configured, you invoke it by typing `@fabric-data-engineer` in the Copilot Chat panel.

---

## Step 1 — Prerequisites

| Requirement | How to install |
|---|---|
| VS Code | https://code.visualstudio.com |
| GitHub Copilot extension | VS Code → Extensions → search "GitHub Copilot" |
| GitHub Copilot Chat extension | VS Code → Extensions → search "GitHub Copilot Chat" |
| Azure CLI | https://learn.microsoft.com/cli/azure/install-azure-cli |
| PowerShell 7+ | https://learn.microsoft.com/powershell/scripting/install/installing-powershell |

> **Copilot agent mode** requires GitHub Copilot Pro, Business, or Enterprise.

---

## Step 2 — Copy the Agent File

Copy the agent definition into your target repository's `.github/agents/` folder:

```
your-repo/
└── .github/
    └── agents/
        └── fabric-data-engineer.agent.md   ← copy this file
```

The file is provided at `.github/agents/fabric-data-engineer.agent.md` in this repository.

---

## Step 3 — Copy the Helper Scripts

Copy the `scripts/` folder into your target repository:

```
your-repo/
└── scripts/
    ├── deploy-medallion.ps1
    └── fabric/
        ├── Get-FabricToken.ps1
        ├── Get-FabricItems.ps1
        ├── New-FabricNotebook.ps1
        ├── New-FabricNotebookWithContent.ps1
        ├── New-FabricPipeline.ps1
        ├── New-FabricWarehouse.ps1
        └── Update-FabricPipelineDefinition.ps1
```

---

## Step 4 — Set Environment Variables

Set your Fabric workspace ID before starting any session:

```powershell
# Required — your Fabric workspace GUID
$env:FABRIC_WORKSPACE_ID = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

To find your workspace ID:
1. Open [app.fabric.microsoft.com](https://app.fabric.microsoft.com)
2. Navigate to your workspace
3. Copy the GUID from the browser URL: `.../groups/<workspace-id>/...`

For service principal auth (CI/CD), set these instead:

```powershell
$env:FABRIC_CLIENT_ID     = "<app-registration-client-id>"
$env:FABRIC_CLIENT_SECRET = "<client-secret>"          # never commit this
$env:FABRIC_TENANT_ID     = "<azure-tenant-id>"
```

> See `.env.example` for the full list of supported variables.

---

## Step 5 — Authenticate with Azure CLI

```powershell
# Log in (opens browser)
az login

# Verify the correct subscription/tenant is active
az account show

# If needed, switch to the right tenant
az login --tenant "<your-tenant-id>"
```

---

## Step 6 — Open VS Code and Invoke the Agent

1. Open your repository folder in VS Code
2. Open **Copilot Chat** (`Ctrl+Alt+I` or the chat icon in the sidebar)
3. Switch to **Agent mode** using the dropdown at the top of the chat panel
4. Select **Fabric Data Engineer** from the agent list
5. Start chatting:

```
List all items in my Fabric workspace
```

```
Create a new notebook called nb_test in workspace 632718e4-...
```

```
Deploy the full medallion architecture to my workspace
```

---

## Step 7 — Validate Connectivity

Run the connectivity check script to confirm everything is working:

```powershell
$env:FABRIC_WORKSPACE_ID = "<your-workspace-id>"
.\scripts\fabric\Get-FabricItems.ps1
```

Expected output: a list of items in your workspace (notebooks, lakehouses, warehouses, pipelines).

---

## Agent Capabilities

| Capability | How it works |
|---|---|
| List workspace items | Calls `GET /v1/workspaces/{id}/items` via `Get-FabricItems.ps1` |
| Create warehouse | Calls `POST /v1/workspaces/{id}/warehouses` via `New-FabricWarehouse.ps1` |
| Create / update notebook | Calls item definition API via `New-FabricNotebookWithContent.ps1` |
| Create pipeline | Calls `POST /v1/workspaces/{id}/items` via `New-FabricPipeline.ps1` |
| Wire pipeline activities | Calls `updateDefinition` API via `Update-FabricPipelineDefinition.ps1` |
| Deploy full medallion | Runs `deploy-medallion.ps1` (all-in-one) |
| Trigger pipeline run | Calls `POST /v1/workspaces/{id}/dataPipelines/{id}/jobs/instances` |

---

## Adapting for a New Workspace

To redeploy to a **different workspace**, you only need to change two things:

1. **Environment variable:**
   ```powershell
   $env:FABRIC_WORKSPACE_ID = "<new-workspace-id>"
   ```

2. **Hardcoded workspace ID in notebooks** — search `deploy-medallion.ps1` for the line:
   ```python
   ws_id  = '632718e4-2ab9-4c28-a6e4-54d95836ec62'  # Fabric workspace ID
   ```
   Replace with your new workspace ID, then re-run `deploy-medallion.ps1`.

> **Tip:** To make this fully dynamic, replace the hardcoded value with a notebook parameter
> and pass it via the pipeline's `parametersSpec`.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `az: command not found` | Azure CLI not installed | Install from link in Step 1 |
| `Failed to obtain Fabric access token` | Not logged in | Run `az login` |
| `Workspace ID not set` | Missing env var | Set `$env:FABRIC_WORKSPACE_ID` |
| `AttributeError: module 'notebookutils.mssparkutils.env' has no attribute 'getWorkspaceId'` | Wrong mssparkutils API | Use hardcoded workspace ID (already fixed in scripts) |
| `Convert data from py to ipynb failed` | Wrong notebook format | Ensure first line is `# Fabric notebook source`, no multi-line `# META` blocks |
| `Operation failed (Failed)` | Async API error | Check `x-ms-operation-id` and poll `/v1/operations/{id}` |
