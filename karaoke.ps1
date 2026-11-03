# Everyday use:  .\karaoke.ps1 song1.flac song2.flac ...
# Uploads the songs, runs the GPU job once, waits, then downloads the stems to .\stems
param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Songs)
$ErrorActionPreference = "Stop"

# ---- paste the values printed by deploy.ps1 ----
$RG      = "karaoke-rg"
$JOB     = "karaoke-sep"
$STORAGE = "CHANGE_ME"
$SHARE   = "karaoke"
# ------------------------------------------------

$KEY = az storage account keys list -g $RG -n $STORAGE --query "[0].value" -o tsv

foreach ($f in $Songs) {
  $name = Split-Path $f -Leaf
  Write-Host "uploading $name"
  az storage file upload --account-name $STORAGE --account-key $KEY `
    -s $SHARE --source $f --path "in/$name" --only-show-errors
}

$EXEC = az containerapp job start -g $RG -n $JOB --query name -o tsv
Write-Host "job started: $EXEC"

do {
  Start-Sleep -Seconds 20
  $STATUS = az containerapp job execution show -g $RG -n $JOB --job-execution-name $EXEC `
    --query properties.status -o tsv
  Write-Host "status: $STATUS"
} until ($STATUS -in "Succeeded", "Failed")

New-Item -ItemType Directory -Force stems | Out-Null
az storage file download-batch --account-name $STORAGE --account-key $KEY `
  -s "$SHARE/out" -d stems --only-show-errors
Write-Host "stems saved to .\stems"
if ($STATUS -eq "Failed") { Write-Warning "Job failed - check logs in the Azure portal (Container Apps Job > Execution history)." }
