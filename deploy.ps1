# One-time setup for the karaoke separator on Azure Container Apps serverless GPU.
# The container image is built by GitHub Actions and pulled from GitHub Container Registry (free).
# Run from this folder after the image is built and set to public:
#   az login
#   .\deploy.ps1
$ErrorActionPreference = "Stop"

# ---- edit these ----
$GITHUB_USER = "CHANGE_ME"                         # your GitHub username, lowercase
$RG      = "karaoke-rg"
$LOC     = "northcentralus"                        # T4 serverless GPUs are available here
$STORAGE = "karaokesa$(Get-Random -Max 99999)"     # globally unique, lowercase
$SHARE   = "karaoke"
$ENV     = "karaoke-env"
$JOB     = "karaoke-sep"
# --------------------

if ($GITHUB_USER -eq "CHANGE_ME") { throw "Set `$GITHUB_USER at the top of deploy.ps1 first." }
$IMAGE = "ghcr.io/$($GITHUB_USER.ToLower())/karaoke-sep:latest"

function Run { param([scriptblock]$cmd) & $cmd; if ($LASTEXITCODE -ne 0) { throw "Command failed: $cmd" } }

# New subscriptions must register each Azure service before first use (one-time, takes a few minutes)
foreach ($ns in "Microsoft.App", "Microsoft.Storage", "Microsoft.OperationalInsights") {
  Write-Host "registering $ns ..."
  Run { az provider register --namespace $ns --wait -o none }
}

Run { az group create -n $RG -l $LOC -o none }

# File share for songs, stems and cached models
Run { az storage account create -g $RG -n $STORAGE -l $LOC --sku Standard_LRS --kind StorageV2 -o none }
$KEY = az storage account keys list -g $RG -n $STORAGE --query "[0].value" -o tsv
Run { az storage share-rm create -g $RG --storage-account $STORAGE -n $SHARE --quota 50 -o none }
foreach ($d in "in", "out", "models") {
  Run { az storage directory create --account-name $STORAGE --account-key $KEY -s $SHARE -n $d -o none }
}

# Workload-profiles environment + T4 serverless GPU profile
Run { az containerapp env create -g $RG -n $ENV -l $LOC --enable-workload-profiles -o none }
Run { az containerapp env workload-profile add -g $RG -n $ENV `
        --workload-profile-name gpu-t4 `
        --workload-profile-type Consumption-GPU-NC8as-T4 -o none }

# Attach the file share to the environment
Run { az containerapp env storage set -g $RG -n $ENV `
        --storage-name karaokefiles `
        --azure-file-account-name $STORAGE `
        --azure-file-account-key $KEY `
        --azure-file-share-name $SHARE `
        --access-mode ReadWrite -o none }

# Fill in job.yaml placeholders
$ENV_ID = az containerapp env show -g $RG -n $ENV --query id -o tsv
(Get-Content -Raw job.yaml) `
  -replace "<LOCATION>", $LOC `
  -replace "<ENVIRONMENT_ID>", $ENV_ID `
  -replace "<IMAGE>", $IMAGE |
  Set-Content -NoNewline job.filled.yaml

# Create a small placeholder job, then apply the full GPU definition
Run { az containerapp job create -g $RG -n $JOB --environment $ENV `
        --trigger-type Manual --replica-timeout 3600 `
        --image mcr.microsoft.com/k8se/quickstart-jobs:latest `
        --cpu 0.25 --memory 0.5Gi -o none }
Run { az containerapp job update -g $RG -n $JOB --yaml job.filled.yaml -o none }

Write-Host ""
Write-Host "Setup complete. Paste these into karaoke.ps1:"
Write-Host "  `$RG      = `"$RG`""
Write-Host "  `$JOB     = `"$JOB`""
Write-Host "  `$STORAGE = `"$STORAGE`""
Write-Host "  `$SHARE   = `"$SHARE`""
