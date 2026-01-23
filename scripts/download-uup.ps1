param(
    [Parameter(Mandatory)][string]$DownloadDir
)

$ErrorActionPreference = "Stop"

$aria2File = "D:\aria2_download_list.txt"

if (-not (Test-Path $aria2File)) {
    Write-Error "aria2 input file not found at $aria2File"
    exit 1
}

# Create download directory
New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null

# Check available disk space
$drive = (Get-Item $DownloadDir).PSDrive
$freeGB = [math]::Round($drive.Free / 1GB, 2)
Write-Host "Available disk space on $($drive.Name): drive: ${freeGB} GB"

if ($freeGB -lt 10) {
    Write-Error "Insufficient disk space: ${freeGB} GB free, need at least 10 GB"
    exit 1
}

# Run aria2c
Write-Host "Starting download to $DownloadDir..."
$aria2Args = @(
    "--input-file=$aria2File"
    "--dir=$DownloadDir"
    "--max-connection-per-server=16"
    "--split=16"
    "--max-concurrent-downloads=8"
    "--min-split-size=1M"
    "--check-integrity=true"
    "--continue=true"
    "--retry-wait=5"
    "--max-tries=5"
    "--console-log-level=notice"
    "--summary-interval=30"
)

& aria2c @aria2Args
if ($LASTEXITCODE -ne 0) {
    Write-Error "aria2c failed with exit code $LASTEXITCODE"
    exit 1
}

# Verify downloads
$downloadedFiles = Get-ChildItem $DownloadDir -File
Write-Host ""
Write-Host "Downloaded $($downloadedFiles.Count) files:"
$downloadedFiles | ForEach-Object {
    $sizeGB = [math]::Round($_.Length / 1GB, 3)
    Write-Host "  $($_.Name) (${sizeGB} GB)"
}

$totalGB = [math]::Round(($downloadedFiles | Measure-Object -Property Length -Sum).Sum / 1GB, 2)
Write-Host "Total download size: ${totalGB} GB"
