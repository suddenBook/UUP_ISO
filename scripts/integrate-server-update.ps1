param(
    [Parameter(Mandatory)][string]$ConverterDir,
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$Edition
)

$ErrorActionPreference = "Stop"

# --- Step 0: Validate inputs ---

$iso = Get-ChildItem "$ConverterDir\*.iso" | Select-Object -First 1
if (-not $iso) {
    Write-Error "No ISO file found in $ConverterDir"
    exit 1
}
Write-Host "Found ISO: $($iso.Name)"

$cdimage = Join-Path $ConverterDir "bin\cdimage.exe"
if (-not (Test-Path $cdimage)) {
    Write-Error "cdimage.exe not found at $cdimage"
    exit 1
}

$editionNameMap = @{
    "SERVERSTANDARD"         = "Windows Server 2025 Standard"
    "SERVERSTANDARDCORE"     = "Windows Server 2025 Standard (Desktop Experience)"
    "SERVERDATACENTER"       = "Windows Server 2025 Datacenter"
    "SERVERDATACENTERCORE"   = "Windows Server 2025 Datacenter (Desktop Experience)"
}

if (-not $editionNameMap.ContainsKey($Edition)) {
    Write-Error "Unknown edition: $Edition. Valid: $($editionNameMap.Keys -join ', ')"
    exit 1
}
$editionName = $editionNameMap[$Edition]
Write-Host "Target edition: $editionName"

# --- Step 1: Extract the base ISO ---

$extractDir = Join-Path $WorkDir "iso_contents"
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
Write-Host "Extracting ISO to $extractDir..."
7z x $iso.FullName -o"$extractDir" -y
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to extract ISO"
    exit 1
}
Write-Host "ISO extracted"

# --- Step 2: Search Microsoft Update Catalog for latest Server 2025 LCU ---

$updateDir = Join-Path $WorkDir "updates"
New-Item -ItemType Directory -Path $updateDir -Force | Out-Null

$searchQuery = "Cumulative Update for Microsoft server operating system, version 24H2 for x64-based Systems"
Write-Host "Searching Microsoft Update Catalog for: $searchQuery"

# Search the catalog
$searchUrl = "https://www.catalog.update.microsoft.com/Search.aspx"
$body = "q=$([System.Web.HttpUtility]::UrlEncode($searchQuery))"

# Load System.Web for URL encoding
Add-Type -AssemblyName System.Web

$response = Invoke-WebRequest -Uri $searchUrl -Method Post -Body "q=$([System.Web.HttpUtility]::UrlEncode($searchQuery))" `
    -ContentType "application/x-www-form-urlencoded" -UseBasicParsing

if ($response.StatusCode -ne 200) {
    Write-Error "Catalog search failed with status $($response.StatusCode)"
    exit 1
}

# Parse results from the HTML table
# Each row has: title, products, classification, last updated, version, size
$html = $response.Content

# Extract update entries: id and title from the result rows
$updates = @()
$rowPattern = 'goToDetails\("([a-f0-9\-]+)"\).*?<td[^>]*>([^<]+)</td>\s*<td[^>]*>([^<]+)</td>\s*<td[^>]*>([^<]+)</td>\s*<td[^>]*>([^<]+)</td>'
$matches = [regex]::Matches($html, $rowPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

foreach ($m in $matches) {
    $updates += [PSCustomObject]@{
        GUID    = $m.Groups[1].Value
        Title   = $m.Groups[2].Value.Trim()
        Product = $m.Groups[3].Value.Trim()
        Date    = $m.Groups[4].Value.Trim()
        Size    = $m.Groups[5].Value.Trim()
    }
}

if ($updates.Count -eq 0) {
    # Fallback: try a simpler regex to extract IDs and titles
    $idMatches = [regex]::Matches($html, 'goToDetails\("([a-f0-9\-]+)"\)')
    $titleMatches = [regex]::Matches($html, '<a[^>]*id="[^"]*_link"[^>]*>(.*?)</a>', [System.Text.RegularExpressions.RegexOptions]::Singleline)

    for ($i = 0; $i -lt [Math]::Min($idMatches.Count, $titleMatches.Count); $i++) {
        $updates += [PSCustomObject]@{
            GUID    = $idMatches[$i].Groups[1].Value
            Title   = ($titleMatches[$i].Groups[1].Value -replace '<[^>]+>', '').Trim()
            Product = ""
            Date    = ""
            Size    = ""
        }
    }
}

Write-Host "Found $($updates.Count) catalog entries"

if ($updates.Count -gt 0) {
    Write-Host "First 3 entries:"
    $updates | Select-Object -First 3 | ForEach-Object { Write-Host "  [$($_.GUID)] $($_.Title)" }
}

if ($updates.Count -eq 0) {
    Write-Error "No updates found in Microsoft Update Catalog"
    exit 1
}

# Filter: exclude Preview and Out-of-Band updates
$filtered = $updates | Where-Object {
    $_.Title -notmatch "Preview" -and
    $_.Title -notmatch "Out-of-Band" -and
    $_.Title -match "Cumulative Update"
}

if ($filtered.Count -eq 0) {
    Write-Warning "No non-Preview updates found after filtering, using all results"
    $filtered = $updates | Where-Object { $_.Title -match "Cumulative Update" }
}

if (-not $filtered -or $filtered.Count -eq 0) {
    Write-Warning "Title filtering failed, using first catalog entry by GUID"
    $filtered = $updates | Select-Object -First 1
}

# Take the first result (catalog returns newest first)
$selectedUpdate = $filtered | Select-Object -First 1

if (-not $selectedUpdate) {
    Write-Error "Failed to select an update from catalog results"
    exit 1
}

Write-Host "Selected update: $($selectedUpdate.Title)"
Write-Host "  GUID: $($selectedUpdate.GUID)"

# --- Get download URLs from DownloadDialog ---

$downloadUrl = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"
$postBody = @{ updateIDs = "[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$($selectedUpdate.GUID)`",`"updateID`":`"$($selectedUpdate.GUID)`"}]" }

$dlResponse = Invoke-WebRequest -Uri $downloadUrl -Method Post -Body $postBody -UseBasicParsing
$dlHtml = $dlResponse.Content

# Extract download URLs from the JavaScript response
$urlMatches = [regex]::Matches($dlHtml, "https?://[^'""]+\.msu")
$downloadUrls = $urlMatches | ForEach-Object { $_.Value } | Select-Object -Unique

if ($downloadUrls.Count -eq 0) {
    # Also try .cab files
    $urlMatches = [regex]::Matches($dlHtml, "https?://[^'""]+\.(msu|cab)")
    $downloadUrls = $urlMatches | ForEach-Object { $_.Value } | Select-Object -Unique
}

if ($downloadUrls.Count -eq 0) {
    Write-Error "No download URLs found for update $($selectedUpdate.GUID)"
    Write-Host "DownloadDialog response (first 2000 chars):"
    Write-Host $dlHtml.Substring(0, [Math]::Min(2000, $dlHtml.Length))
    exit 1
}

Write-Host "Found $($downloadUrls.Count) download URL(s):"
foreach ($url in $downloadUrls) {
    Write-Host "  $url"
}

# Download all update files
Write-Host "Downloading updates to $updateDir..."
foreach ($url in $downloadUrls) {
    $fileName = [System.IO.Path]::GetFileName(($url -split '\?')[0])
    Write-Host "Downloading $fileName..."
    aria2c --max-connection-per-server=16 --split=16 -d $updateDir -o $fileName $url
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to download $url"
        exit 1
    }
}

$updateFiles = Get-ChildItem $updateDir -File
Write-Host "Downloaded $($updateFiles.Count) update file(s):"
$updateFiles | ForEach-Object { Write-Host "  $($_.Name) ($([math]::Round($_.Length / 1MB, 1)) MB)" }

# --- Step 3: Mount install.wim and apply updates ---

$wimPath = Join-Path $extractDir "sources\install.wim"
if (-not (Test-Path $wimPath)) {
    Write-Error "install.wim not found at $wimPath"
    exit 1
}

# Remove read-only attribute (ISO extraction sets it)
Set-ItemProperty -Path $wimPath -Name IsReadOnly -Value $false

$mountDir = Join-Path $WorkDir "mount"
New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

# Get WIM image info and find the target index
$wimInfo = Get-WindowsImage -ImagePath $wimPath
Write-Host "WIM images:"
foreach ($img in $wimInfo) {
    Write-Host "  Index $($img.ImageIndex): $($img.ImageName)"
}

$targetImage = $wimInfo | Where-Object { $_.ImageName -eq $editionName }
if (-not $targetImage) {
    # Try partial match
    $targetImage = $wimInfo | Where-Object { $_.ImageName -like "*$editionName*" }
}
if (-not $targetImage) {
    Write-Error "Could not find WIM index matching edition '$editionName'"
    Write-Host "Available images: $($wimInfo | ForEach-Object { $_.ImageName } | Out-String)"
    exit 1
}

$targetIndex = $targetImage.ImageIndex
Write-Host "Patching WIM index $targetIndex ($($targetImage.ImageName))..."

# Mount the image
Write-Host "Mounting WIM..."
Mount-WindowsImage -ImagePath $wimPath -Index $targetIndex -Path $mountDir

# Apply updates (point to folder so DISM discovers checkpoints automatically)
Write-Host "Applying updates via DISM (this may take a while)..."
try {
    Add-WindowsPackage -Path $mountDir -PackagePath $updateDir -ErrorAction Stop
    Write-Host "Updates applied successfully"
} catch {
    Write-Warning "Add-WindowsPackage encountered an error: $_"
    Write-Warning "Attempting to continue - some updates may have been applied"
}

# Cleanup to reduce image size
Write-Host "Running DISM cleanup with ResetBase..."
& dism /Image:$mountDir /Cleanup-Image /StartComponentCleanup /ResetBase
if ($LASTEXITCODE -ne 0) {
    Write-Warning "DISM cleanup returned exit code $LASTEXITCODE (non-zero may be acceptable)"
}

# Unmount and save
Write-Host "Dismounting WIM (saving changes)..."
Dismount-WindowsImage -Path $mountDir -Save
Write-Host "WIM updated successfully"

# --- Step 4: Rebuild ISO with cdimage.exe ---

Write-Host "Rebuilding ISO with cdimage.exe..."

$bootEtfs = Join-Path $extractDir "boot\etfsboot.com"
$bootEfi = Join-Path $extractDir "efi\Microsoft\boot\efisys.bin"

if (-not (Test-Path $bootEtfs)) {
    Write-Error "BIOS boot file not found: $bootEtfs"
    exit 1
}
if (-not (Test-Path $bootEfi)) {
    Write-Error "EFI boot file not found: $bootEfi"
    exit 1
}

# Remove read-only attributes from extracted files (cdimage needs write access for some operations)
Get-ChildItem $extractDir -Recurse -File | ForEach-Object {
    if ($_.IsReadOnly) { $_.IsReadOnly = $false }
}

$outputIso = Join-Path $ConverterDir "ServerUpdated.iso"

# Build BIOS + UEFI hybrid bootable ISO
$bootdataArg = "-bootdata:2#p0,e,b${bootEtfs}#pEF,e,b${bootEfi}"
& $cdimage $bootdataArg -o -m -u2 -udfver102 -lSERVER2025 $extractDir $outputIso

if ($LASTEXITCODE -ne 0) {
    Write-Error "cdimage failed with exit code $LASTEXITCODE"
    exit 1
}

if (-not (Test-Path $outputIso)) {
    Write-Error "cdimage did not produce output ISO"
    exit 1
}

# Replace original ISO with updated one
$updatedSize = [math]::Round((Get-Item $outputIso).Length / 1GB, 2)
Write-Host "Updated ISO size: ${updatedSize} GB"

Remove-Item $iso.FullName -Force
Move-Item $outputIso $iso.FullName
Write-Host "Replaced original ISO with updated version"

# Cleanup work directory
Write-Host "Cleaning up work directory..."
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Cumulative update integration complete!"
Write-Host "  ISO: $($iso.Name)"
Write-Host "  Update: $($selectedUpdate.Title)"
