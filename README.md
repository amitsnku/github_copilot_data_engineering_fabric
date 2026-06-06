# Fabric Copilot Agent — Medallion Architecture Starter Kit

This repository contains a fully automated **Medallion Architecture** deployment for Microsoft Fabric,
driven by GitHub Copilot agent mode. It provisions a Fabric Warehouse, 3 orchestration notebooks, and
an ETL pipeline — all via the Fabric REST API, with no manual portal clicks required.

---

## Repository Structure

```
copilot_fabric_medallion/
├── README.md                                    ← You are here
├── .env.example                                 ← Environment variable template
├── .github/
│   └── agents/
│       └── fabric-data-engineer.agent.md        ← Custom Copilot agent definition
├── scripts/
│   ├── deploy-medallion.ps1                     ← Master all-in-one deployment script
│   └── fabric/
│       ├── Get-FabricToken.ps1                  ← Get bearer token via az login
│       ├── Get-FabricItems.ps1                  ← List all items in a workspace
│       ├── New-FabricNotebook.ps1               ← Create a blank notebook (idempotent)
│       ├── New-FabricNotebookWithContent.ps1    ← Create/update notebook with content
│       ├── New-FabricPipeline.ps1               ← Create a blank pipeline (idempotent)
│       ├── New-FabricWarehouse.ps1              ← Create a Fabric Warehouse (idempotent)
│       └── Update-FabricPipelineDefinition.ps1  ← Wire pipeline activities
└── docs/
    ├── setup-copilot-agent.md                   ← Configure Copilot agent for Fabric
    ├── medallion-architecture.md                ← Architecture design & data model
    └── deployment-guide.md                      ← Step-by-step deployment instructions
```

---

## What Gets Deployed

| Asset | Name | Purpose |
|---|---|---|
| Warehouse | `ou_copilot_dw_poc` | Central Fabric Warehouse hosting all 4 schemas |
| Notebook 1 | `nb_01_raw_data_setup` | Generates ~100K synthetic transactions in `raw` schema |
| Notebook 2 | `nb_02_quality_silver` | Runs 12 quality checks, builds star schema in `silver` |
| Notebook 3 | `nb_03_semantic_views` | Populates 7 analytics tables in `semantic` schema |
| Pipeline | `pl_medallion_etl` | Orchestrates NB-01 → NB-02 → NB-03 sequentially |

---

## Quick Start

```powershell
# 1. Authenticate with Azure
az login

# 2. Set your target Fabric workspace ID
$env:FABRIC_WORKSPACE_ID = "<your-workspace-id>"

# 3. Run the master deployment script
.\scripts\deploy-medallion.ps1
```

The script is **fully idempotent** — re-running it will update existing assets, not duplicate them.

---

## Documentation

| Document | Description |
|---|---|
| [Setup Copilot Agent](docs/setup-copilot-agent.md) | How to configure the Fabric Data Engineer custom agent |
| [Architecture Guide](docs/medallion-architecture.md) | Full data model, schema design, quality rules |
| [Deployment Guide](docs/deployment-guide.md) | Prerequisites, step-by-step deployment, troubleshooting |

---

## Prerequisites

- Windows with PowerShell 7+
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az` command)
- Microsoft Fabric workspace with Contributor or Admin role
- VS Code + [GitHub Copilot extension](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot) (for agent mode)
