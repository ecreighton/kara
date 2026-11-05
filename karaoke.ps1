# Everyday use:
#   .\karaoke.ps1 song1.flac song2.mp3 ...   upload songs, process, download results to .\stems
#   .\karaoke.ps1                            just process whatever is already uploaded + download
#
# Lyrics: if "song1.txt" sits next to "song1.flac", it's uploaded and used instead of the
# automatic lookup. To fix a video's lyrics, edit the .txt and run the script again with the song.
#   .\karaoke.ps1 -Watch <execution-name>    follow a run that's already going, then download
[CmdletBinding(PositionalBinding = $false)]   # bare arguments are always songs
param(
  [string]$Watch,
  [Parameter(ValueFromRemainingArguments)][string[]]$Songs = @()
)
$ErrorActionPreference = "Stop"

# Safety net: a file path given where a run name was expected is a song, not a run to watch
if ($Watch -and (Test-Path $Watch)) { $Songs = @($Watch) + $Songs; $Watch = $null }

# ---- paste the values printed by deploy.ps1 ----
$RG      = "karaoke-rg"
$JOB     = "karaoke-sep"
$STORAGE = "karaokesa77458"
$SHARE   = "karaoke"
# ------------------------------------------------

$KEY = az storage account keys list -g $RG -n $STORAGE --query "[0].value" -o tsv

function Upload($path) {
  $name = Split-Path $path -Leaf
  Write-Host "uploading $name"
  az storage file upload --account-name $STORAGE --account-key $KEY `
    -s $SHARE --source $path --path "in/$name" --only-show-errors -o none
}

foreach ($f in $Songs) {
  if (-not (Test-Path $f)) { Write-Warning "not found: $f"; continue }
  Upload $f
  $txt = [IO.Path]::ChangeExtension($f, ".txt")
  if (Test-Path $txt) { Upload $txt }
}

if ($Watch) {
  $EXEC = $Watch
  Write-Host "watching: $EXEC"
} else {
  $EXEC = az containerapp job start -g $RG -n $JOB --query name -o tsv
  Write-Host "job started: $EXEC"
}

# Latest line of the container's console log (e.g. the separation progress bar)
function Get-LastLog {
  $raw = az containerapp job logs show -n $JOB -g $RG --container separator `
    --execution $EXEC --tail 5 2>$null
  if (-not $raw) { return "" }
  $lines = foreach ($l in $raw) { try { ($l | ConvertFrom-Json).Log } catch { $l } }
  $last = $lines | Where-Object { $_ -and $_.Trim() } | Select-Object -Last 1
  if (-not $last) { return "" }
  # progress bars redraw with carriage returns; keep only the newest redraw
  $last = ($last -split "`r" | Where-Object { $_.Trim() } | Select-Object -Last 1).Trim()
  if ($last.Length -gt 110) { $last = $last.Substring(0, 110) + "..." }
  return $last
}

$ErrorActionPreference = "Continue"   # a network blip shouldn't stop the watcher
do {
  Start-Sleep -Seconds 30
  $STATUS = az containerapp job execution show -g $RG -n $JOB --job-execution-name $EXEC `
    --query properties.status -o tsv 2>$null
  if (-not $STATUS) {
    Write-Host "$(Get-Date -Format t)  (couldn't reach Azure, retrying)"
    continue
  }
  $line = if ($STATUS -eq "Running") { Get-LastLog } else { "" }
  Write-Host "$(Get-Date -Format t)  status: $STATUS  $line"
} until ($STATUS -in "Succeeded", "Failed", "Stopped")

New-Item -ItemType Directory -Force stems | Out-Null
az storage file download-batch --account-name $STORAGE --account-key $KEY `
  -s "$SHARE/out" -d stems --only-show-errors -o none
Write-Host "results saved to .\stems  (look for '<song> (Karaoke).mp4')"
if ($STATUS -ne "Succeeded") { Write-Warning "Job $STATUS - check Console logs in the portal (karaoke-sep > Execution history)." }
