param(
    [Parameter(Mandatory)][string]$BaseIsoPath,
    [Parameter(Mandatory)][string]$ConverterDir,
    [Parameter(Mandatory)][string]$WorkDir,
    [string]$DriversDir,
    [string]$VP9AppxPath
)

$ErrorActionPreference = "Stop"

# Load System.Web for URL encoding
Add-Type -AssemblyName System.Web

# --- Helper: Search Microsoft Update Catalog ---

function Search-UpdateCatalog {
    param([string]$Query, [int]$MaxRetries = 3)

    $searchUrl = "https://www.catalog.update.microsoft.com/Search.aspx"
    $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Host "Catalog search attempt $attempt/$MaxRetries..."
        try {
            $response = Invoke-WebRequest -Uri $searchUrl -Method Post `
                -Body "q=$([System.Web.HttpUtility]::UrlEncode($Query))" `
                -ContentType "application/x-www-form-urlencoded" `
                -Headers $headers -UseBasicParsing

            if ($response.StatusCode -ne 200) {
                Write-Warning "Catalog returned status $($response.StatusCode)"
                Start-Sleep -Seconds (30 * $attempt)
                continue
            }

            $html = $response.Content
            Write-Host "Response size: $($html.Length) chars"

            # Extract GUIDs and titles from <a> tags (titles live inside <a>, not <td>)
            $idMatches = [regex]::Matches($html, 'goToDetails\("([a-f0-9\-]+)"\)')
            $titleMatches = [regex]::Matches($html, '<a[^>]*id="[^"]*_link"[^>]*>\s*(.*?)\s*</a>', `
                [System.Text.RegularExpressions.RegexOptions]::Singleline)

            Write-Host "Regex matches: $($idMatches.Count) GUIDs, $($titleMatches.Count) titles"

            if ($idMatches.Count -eq 0) {
                # Check for common catalog issues
                if ($html -match "catalog\.s\.download\.windowsupdate\.com") {
                    Write-Host "Page appears to contain results but regex didn't match"
                }
                if ($html.Length -lt 5000) {
                    Write-Warning "Response too short, catalog may be blocking or rate-limiting"
                }
                Write-Warning "No results found, retrying in $(30 * $attempt)s..."
                Start-Sleep -Seconds (30 * $attempt)
                continue
            }

            $results = @()
            for ($i = 0; $i -lt [Math]::Min($idMatches.Count, $titleMatches.Count); $i++) {
                $results += [PSCustomObject]@{
                    GUID  = $idMatches[$i].Groups[1].Value
                    Title = ($titleMatches[$i].Groups[1].Value -replace '<[^>]+>', '').Trim()
                }
            }
            return $results
        } catch {
            Write-Warning "Catalog request failed: $_"
            Start-Sleep -Seconds (30 * $attempt)
        }
    }

    Write-Warning "Catalog search failed after $MaxRetries attempts"
    return @()
}

# --- Helper: Get download URLs for a catalog entry ---

function Get-CatalogDownloadUrls {
    param([string]$GUID)

    $downloadUrl = "https://www.catalog.update.microsoft.com/DownloadDialog.aspx"
    $postBody = @{ updateIDs = "[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$GUID`",`"updateID`":`"$GUID`"}]" }

    $dlResponse = Invoke-WebRequest -Uri $downloadUrl -Method Post -Body $postBody -UseBasicParsing
    $dlHtml = $dlResponse.Content

    $urlMatches = [regex]::Matches($dlHtml, "https?://[^'""]+\.(msu|cab)")
    return ($urlMatches | ForEach-Object { $_.Value } | Select-Object -Unique)
}

# --- Step 0: Validate inputs ---

if (-not (Test-Path $BaseIsoPath)) {
    Write-Error "Base ISO not found at $BaseIsoPath"
    exit 1
}
Write-Host "Base ISO: $BaseIsoPath"

$cdimage = Join-Path $ConverterDir "bin\cdimage.exe"
if (-not (Test-Path $cdimage)) {
    Write-Error "cdimage.exe not found at $cdimage"
    exit 1
}

if ($DriversDir -and -not (Test-Path $DriversDir)) {
    Write-Error "Drivers directory not found at $DriversDir"
    exit 1
}

# --- Step 1: Extract the base ISO ---

$extractDir = Join-Path $WorkDir "iso_contents"
New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
Write-Host "Extracting ISO to $extractDir..."
7z x $BaseIsoPath -o"$extractDir" -y
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to extract ISO"
    exit 1
}
Write-Host "ISO extracted"

# --- Step 2: Search and download OS cumulative update ---

$cuDir = Join-Path $WorkDir "cu_updates"
New-Item -ItemType Directory -Path $cuDir -Force | Out-Null

$searchQuery = "Cumulative Update for Windows 11 Version 24H2 for x64-based Systems"
Write-Host "Searching Microsoft Update Catalog for: $searchQuery"

$updates = Search-UpdateCatalog -Query $searchQuery
Write-Host "Found $($updates.Count) catalog entries"

if ($updates.Count -gt 0) {
    Write-Host "First 5 entries:"
    $updates | Select-Object -First 5 | ForEach-Object { Write-Host "  [$($_.GUID)] $($_.Title)" }
}

if ($updates.Count -eq 0) {
    Write-Error "No updates found in Microsoft Update Catalog"
    exit 1
}

# Filter: non-Preview, non-Out-of-Band cumulative updates
$filtered = $updates | Where-Object {
    $_.Title -notmatch "Preview" -and
    $_.Title -notmatch "Out-of-Band" -and
    $_.Title -match "Cumulative Update"
}

if (-not $filtered -or $filtered.Count -eq 0) {
    Write-Warning "Filtering failed, using first catalog entry"
    $filtered = $updates | Select-Object -First 1
}

$selectedCU = $filtered | Select-Object -First 1
Write-Host "Selected CU: $($selectedCU.Title)"
Write-Host "  GUID: $($selectedCU.GUID)"

# Get download URLs
$cuUrls = Get-CatalogDownloadUrls -GUID $selectedCU.GUID

if ($cuUrls.Count -eq 0) {
    Write-Error "No download URLs found for CU $($selectedCU.GUID)"
    exit 1
}

Write-Host "Found $($cuUrls.Count) download URL(s)"

# Download CU files
foreach ($url in $cuUrls) {
    $fileName = [System.IO.Path]::GetFileName(($url -split '\?')[0])
    Write-Host "Downloading $fileName..."
    aria2c --max-connection-per-server=16 --split=16 -d $cuDir -o $fileName $url
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to download $url"
        exit 1
    }
}

$cuFiles = Get-ChildItem $cuDir -File
Write-Host "Downloaded CU file(s):"
$cuFiles | ForEach-Object { Write-Host "  $($_.Name) ($([math]::Round($_.Length / 1MB, 1)) MB)" }

# --- Step 3: Search and download .NET Framework cumulative update ---

$netDir = Join-Path $WorkDir "net_updates"
New-Item -ItemType Directory -Path $netDir -Force | Out-Null

$netQuery = "Cumulative Update for .NET Framework 3.5 and 4.8.1 for Windows 11, version 24H2 for x64"
Write-Host ""
Write-Host "Searching Microsoft Update Catalog for: $netQuery"

$netUpdates = Search-UpdateCatalog -Query $netQuery
Write-Host "Found $($netUpdates.Count) .NET catalog entries"

$selectedNet = $null
if ($netUpdates.Count -gt 0) {
    Write-Host "First 3 entries:"
    $netUpdates | Select-Object -First 3 | ForEach-Object { Write-Host "  [$($_.GUID)] $($_.Title)" }

    # Filter for non-Preview .NET updates
    $netFiltered = $netUpdates | Where-Object {
        $_.Title -notmatch "Preview" -and
        $_.Title -match "\.NET Framework" -and
        $_.Title -match "x64"
    }

    if (-not $netFiltered -or $netFiltered.Count -eq 0) {
        $netFiltered = $netUpdates | Where-Object { $_.Title -match "\.NET" } | Select-Object -First 1
    }

    if ($netFiltered -and $netFiltered.Count -gt 0) {
        $selectedNet = $netFiltered | Select-Object -First 1
        Write-Host "Selected .NET update: $($selectedNet.Title)"

        $netUrls = Get-CatalogDownloadUrls -GUID $selectedNet.GUID
        if ($netUrls.Count -gt 0) {
            foreach ($url in $netUrls) {
                $fileName = [System.IO.Path]::GetFileName(($url -split '\?')[0])
                Write-Host "Downloading $fileName..."
                aria2c --max-connection-per-server=16 --split=16 -d $netDir -o $fileName $url
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to download .NET update: $url"
                    $selectedNet = $null
                }
            }
        } else {
            Write-Warning "No download URLs for .NET update"
            $selectedNet = $null
        }
    }
}

if (-not $selectedNet) {
    Write-Warning "Skipping .NET CU integration (not found or download failed)"
}

$netFiles = Get-ChildItem $netDir -File -ErrorAction SilentlyContinue
if ($netFiles) {
    Write-Host "Downloaded .NET CU file(s):"
    $netFiles | ForEach-Object { Write-Host "  $($_.Name) ($([math]::Round($_.Length / 1MB, 1)) MB)" }
}

# --- Step 4: Mount install.wim and patch ALL indexes ---

$wimPath = Join-Path $extractDir "sources\install.wim"
if (-not (Test-Path $wimPath)) {
    Write-Error "install.wim not found at $wimPath"
    exit 1
}

# Remove read-only attribute (ISO extraction sets it)
Set-ItemProperty -Path $wimPath -Name IsReadOnly -Value $false

$mountDir = Join-Path $WorkDir "mount"
New-Item -ItemType Directory -Path $mountDir -Force | Out-Null

# Check for .NET 3.5 SxS source in ISO
$sxsDir = Join-Path $extractDir "sources\sxs"
$hasSxs = Test-Path $sxsDir
if ($hasSxs) {
    Write-Host ".NET 3.5 SxS source found at $sxsDir"
} else {
    Write-Warning ".NET 3.5 SxS source not found in ISO, skipping .NET 3.5 enablement"
}

# Get WIM image info
$wimInfo = Get-WindowsImage -ImagePath $wimPath
Write-Host "WIM images:"
$editionList = @()
foreach ($img in $wimInfo) {
    Write-Host "  Index $($img.ImageIndex): $($img.ImageName)"
    $editionList += $img.ImageName
}

$patchedVersion = $null

# Patch ALL indexes
foreach ($img in $wimInfo) {
    $idx = $img.ImageIndex
    Write-Host ""
    Write-Host "=== Patching WIM index $idx ($($img.ImageName)) ==="

    # Mount the image
    Write-Host "Mounting WIM index $idx..."
    Mount-WindowsImage -ImagePath $wimPath -Index $idx -Path $mountDir

    # 4a: Enable .NET Framework 3.5
    if ($hasSxs) {
        Write-Host "Enabling .NET Framework 3.5..."
        try {
            Enable-WindowsOptionalFeature -Path $mountDir -FeatureName "NetFx3" -All `
                -Source $sxsDir -LimitAccess -ErrorAction Stop | Out-Null
            Write-Host ".NET Framework 3.5 enabled"
        } catch {
            Write-Warning "Failed to enable .NET Framework 3.5: $_"
        }
    }

    # 4b: Apply CU packages one by one (skip already-applied)
    Write-Host "Applying OS cumulative update packages..."
    foreach ($pkg in $cuFiles) {
        Write-Host "  Applying $($pkg.Name)..."
        try {
            Add-WindowsPackage -Path $mountDir -PackagePath $pkg.FullName -ErrorAction Stop | Out-Null
            Write-Host "    Applied successfully"
        } catch {
            $errMsg = $_.Exception.Message
            # 0x80070228 / 0x800f081e = already applied or not applicable — safe to skip
            if ($errMsg -match "0x80070228|0x800f081e|already installed|not applicable") {
                Write-Host "    Skipped (already applied or not applicable)"
            } else {
                Write-Warning "    Failed: $errMsg"
                Write-Warning "    Continuing with remaining packages"
            }
        }
    }

    # 4c: Apply .NET CU
    if ($netFiles -and $netFiles.Count -gt 0) {
        Write-Host "Applying .NET Framework cumulative update..."
        foreach ($pkg in $netFiles) {
            Write-Host "  Applying $($pkg.Name)..."
            try {
                Add-WindowsPackage -Path $mountDir -PackagePath $pkg.FullName -ErrorAction Stop | Out-Null
                Write-Host "    Applied successfully"
            } catch {
                $errMsg = $_.Exception.Message
                if ($errMsg -match "0x80070228|0x800f081e|already installed|not applicable") {
                    Write-Host "    Skipped (already applied or not applicable)"
                } else {
                    Write-Warning "    Failed: $errMsg"
                }
            }
        }
    }

    # 4d: Add VP9 Video Extensions
    if ($VP9AppxPath -and (Test-Path $VP9AppxPath)) {
        Write-Host "Adding VP9 Video Extensions..."
        try {
            Add-AppxProvisionedPackage -Path $mountDir -PackagePath $VP9AppxPath `
                -SkipLicense -ErrorAction Stop | Out-Null
            Write-Host "VP9 Video Extensions added"
        } catch {
            Write-Warning "Failed to add VP9 Video Extensions: $_"
        }
    }

    # 4e: Add drivers
    if ($DriversDir) {
        Write-Host "Adding drivers from $DriversDir..."
        try {
            Add-WindowsDriver -Path $mountDir -Driver $DriversDir -Recurse -ErrorAction Stop
            Write-Host "Drivers added successfully"
        } catch {
            Write-Warning "Add-WindowsDriver encountered an error: $_"
            Write-Warning "Continuing without some drivers"
        }
    }

    # 4f: Extract version from first index only
    if (-not $patchedVersion) {
        Write-Host "Reading patched image version..."
        $softwareHive = Join-Path $mountDir "Windows\System32\config\SOFTWARE"
        & reg load "HKLM\OfflineImage" $softwareHive | Out-Null
        try {
            $ntCurrent = Get-ItemProperty "HKLM:\OfflineImage\Microsoft\Windows NT\CurrentVersion"
            $patchedBuild = $ntCurrent.CurrentBuildNumber
            $patchedUBR = $ntCurrent.UBR
            $patchedVersion = "${patchedBuild}.${patchedUBR}"
            Write-Host "Patched image version: $patchedVersion"
        } finally {
            & reg unload "HKLM\OfflineImage" | Out-Null
        }
    }

    # 4g: Dismount, remount, cleanup, dismount
    Write-Host "Dismounting WIM (saving changes)..."
    Dismount-WindowsImage -Path $mountDir -Save

    Write-Host "Remounting WIM for cleanup..."
    Mount-WindowsImage -ImagePath $wimPath -Index $idx -Path $mountDir

    Write-Host "Running DISM cleanup with ResetBase..."
    & dism /Image:$mountDir /Cleanup-Image /StartComponentCleanup /ResetBase
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "DISM cleanup returned exit code $LASTEXITCODE (non-zero may be acceptable)"
    }

    Write-Host "Dismounting WIM (saving changes)..."
    Dismount-WindowsImage -Path $mountDir -Save
    Write-Host "Index $idx patched successfully"
}

Write-Host ""
Write-Host "All WIM indexes patched"

# --- Step 5: Rebuild ISO with cdimage.exe ---

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

# Remove read-only attributes from extracted files
Get-ChildItem $extractDir -Recurse -File | ForEach-Object {
    if ($_.IsReadOnly) { $_.IsReadOnly = $false }
}

$outputIso = Join-Path $ConverterDir "LtscUpdated.iso"

# Build BIOS + UEFI hybrid bootable ISO
$bootdataArg = "-bootdata:2#p0,e,b${bootEtfs}#pEF,e,b${bootEfi}"
& $cdimage $bootdataArg -o -m -u2 -udfver102 -lW11LTSC2024 $extractDir $outputIso

if ($LASTEXITCODE -ne 0) {
    Write-Error "cdimage failed with exit code $LASTEXITCODE"
    exit 1
}

if (-not (Test-Path $outputIso)) {
    Write-Error "cdimage did not produce output ISO"
    exit 1
}

# Rename output ISO
$updatedSize = [math]::Round((Get-Item $outputIso).Length / 1GB, 2)
Write-Host "Updated ISO size: ${updatedSize} GB"

$newIsoName = "W11_LTSC2024_${patchedVersion}_amd64.iso"
$newIsoPath = Join-Path $ConverterDir $newIsoName
Move-Item $outputIso $newIsoPath
Write-Host "Created patched ISO: $newIsoName"

# Set GitHub Actions outputs
if ($env:GITHUB_OUTPUT) {
    "patched_version=$patchedVersion" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "patched_iso_name=$newIsoName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "editions=$($editionList -join ', ')" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "update_title=$($selectedCU.Title)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}

# Cleanup work directory
Write-Host "Cleaning up work directory..."
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Cumulative update integration complete! ==="
Write-Host "  ISO: $newIsoName"
Write-Host "  Version: $patchedVersion"
Write-Host "  Editions: $($editionList -join ', ')"
Write-Host "  OS CU: $($selectedCU.Title)"
if ($selectedNet) { Write-Host "  .NET CU: $($selectedNet.Title)" }
if ($hasSxs) { Write-Host "  .NET 3.5: Enabled" }
if ($VP9AppxPath) { Write-Host "  VP9: Integrated" }
if ($DriversDir) { Write-Host "  Drivers: Integrated" }
