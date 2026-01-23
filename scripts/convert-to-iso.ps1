param(
    [Parameter(Mandatory)][string]$ConverterDir,
    [Parameter(Mandatory)][string]$UUPDir
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConverterDir)) {
    Write-Error "Converter directory not found: $ConverterDir"
    exit 1
}

if (-not (Test-Path $UUPDir)) {
    Write-Error "UUP directory not found: $UUPDir"
    exit 1
}

# Verify UUP files exist
$uupFiles = Get-ChildItem $UUPDir -File
if ($uupFiles.Count -eq 0) {
    Write-Error "No UUP files found in $UUPDir"
    exit 1
}
Write-Host "Found $($uupFiles.Count) UUP files"

# Create ConvertConfig.ini
$configPath = Join-Path $ConverterDir "ConvertConfig.ini"
$configContent = @"
[Configuration]
AutoStart=1
AutoExit=1
AddUpdates=1
Cleanup=1
NetFx3=1
ResetBase=1
"@
$configContent | Out-File -FilePath $configPath -Encoding ascii -NoNewline
Write-Host "Created ConvertConfig.ini with updates, cleanup, ResetBase, and .NET 3.5"

# Copy UUP files to converter's UUPs folder
$converterUUPDir = Join-Path $ConverterDir "UUPs"
New-Item -ItemType Directory -Path $converterUUPDir -Force | Out-Null
Write-Host "Copying UUP files to converter directory..."
Copy-Item -Path "$UUPDir\*" -Destination $converterUUPDir -Force
Write-Host "Copied $($uupFiles.Count) files"

# Check available disk space before conversion
$drive = (Get-Item $ConverterDir).PSDrive
$freeGB = [math]::Round($drive.Free / 1GB, 2)
Write-Host "Available disk space: ${freeGB} GB"

if ($freeGB -lt 20) {
    Write-Warning "Low disk space: ${freeGB} GB free. Conversion may fail if space runs out."
}

# Run the converter
$convertCmd = Join-Path $ConverterDir "convert-UUP.cmd"
if (-not (Test-Path $convertCmd)) {
    Write-Error "convert-UUP.cmd not found at $convertCmd"
    exit 1
}

Write-Host ""
Write-Host "Starting ISO conversion..."
Write-Host "This may take a long time (30-90 minutes depending on updates)..."
Write-Host ""

Push-Location $ConverterDir
try {
    & cmd.exe /c $convertCmd
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($exitCode -ne 0) {
    Write-Warning "Converter exited with code $exitCode (non-zero exit may be normal for this tool)"
}

# Verify ISO was produced
$isoFiles = Get-ChildItem $ConverterDir -Filter "*.iso" -File
if ($isoFiles.Count -eq 0) {
    Write-Error "Conversion failed: no ISO file produced in $ConverterDir"
    Write-Host "Converter directory contents:"
    Get-ChildItem $ConverterDir -Recurse | Select-Object FullName, Length | Format-Table
    exit 1
}

$iso = $isoFiles | Select-Object -First 1
$isoSizeGB = [math]::Round($iso.Length / 1GB, 2)
Write-Host ""
Write-Host "ISO created successfully!"
Write-Host "  File: $($iso.Name)"
Write-Host "  Size: ${isoSizeGB} GB"
Write-Host "  Path: $($iso.FullName)"
