param(
    [Parameter(Mandatory)][string]$Channel,
    [Parameter(Mandatory)][string]$Milestone,
    [Parameter(Mandatory)][string]$Architecture,
    [Parameter(Mandatory)][string]$Language,
    [Parameter(Mandatory)][string]$Edition
)

$ErrorActionPreference = "Stop"

# Validate language code format
if ($Language -notmatch '^[a-z]{2}-[a-z]{2}$') {
    Write-Error "Invalid language code format: '$Language'. Expected format: xx-xx (e.g., en-us, zh-cn)"
    exit 1
}

$baseUrl = "https://api.uupdump.net"

Write-Host "Channel: $Channel"
Write-Host "Milestone: $Milestone"
Write-Host "Architecture: $Architecture"
Write-Host "Language: $Language"
Write-Host "Edition: $Edition"
Write-Host ""

# Step 1: Get UUID based on channel
$uuid = $null
$updateTitle = $null

if ($Channel -in @("Retail", "ReleasePreview")) {
    Write-Host "Querying listid API for $Channel channel, milestone $Milestone..."
    $searchUrl = "$baseUrl/listid.php?search=$Milestone&sortByDate=1"
    $response = Invoke-RestMethod -Uri $searchUrl -Method Get

    if ($response.response.error) {
        Write-Error "API error: $($response.response.error)"
        exit 1
    }

    $builds = $response.response.builds
    if (-not $builds) {
        Write-Error "No builds found for milestone $Milestone"
        exit 1
    }

    # Filter: title contains "Windows 11, version $Milestone" and arch matches
    $matched = $null
    foreach ($prop in $builds.PSObject.Properties) {
        $build = $prop.Value
        $titleMatch = $build.title -like "*Windows 11, version $Milestone*"
        $archMatch = $build.arch -eq $Architecture
        if ($titleMatch -and $archMatch) {
            $matched = $build
            $uuid = $build.uuid
            break
        }
    }

    if (-not $matched) {
        Write-Error "No matching build found for Windows 11 $Milestone ($Architecture) in $Channel channel"
        exit 1
    }

    $updateTitle = $matched.title
    Write-Host "Found: $updateTitle (UUID: $uuid)"
}
else {
    # Beta, Dev, Canary - use fetchupd API
    # Ring must be properly capitalized
    $ringMap = @{
        "Beta"    = "WIF"
        "Dev"     = "WIS"
        "Canary"  = "Canary"
    }
    $ring = $ringMap[$Channel]
    if (-not $ring) {
        Write-Error "Unknown channel: $Channel"
        exit 1
    }

    Write-Host "Querying fetchupd API for $Channel channel (ring: $ring)..."
    $fetchUrl = "$baseUrl/fetchupd.php?arch=$Architecture&ring=$ring"
    $response = Invoke-RestMethod -Uri $fetchUrl -Method Get

    if ($response.response.error) {
        Write-Error "API error: $($response.response.error)"
        exit 1
    }

    $builds = $response.response.builds
    if (-not $builds) {
        Write-Error "No builds found for $Channel channel ($Architecture)"
        exit 1
    }

    # Take the first build
    $firstProp = $builds.PSObject.Properties | Select-Object -First 1
    $uuid = $firstProp.Value.uuid
    $updateTitle = $firstProp.Value.title
    Write-Host "Found: $updateTitle (UUID: $uuid)"
}

# Step 2: Get file list
Write-Host ""
Write-Host "Fetching file list for UUID: $uuid..."
$getUrl = "$baseUrl/get.php?id=$uuid&lang=$Language&edition=$Edition"
$fileResponse = Invoke-RestMethod -Uri $getUrl -Method Get

if ($fileResponse.response.error) {
    Write-Error "API error getting files: $($fileResponse.response.error)"
    exit 1
}

$files = $fileResponse.response.files
if (-not $files) {
    Write-Error "No files returned for this build/language/edition combination"
    exit 1
}

# Step 3: Generate aria2 input file
$aria2File = "D:\aria2_download_list.txt"
$fileCount = 0
$totalSize = 0
$aria2Content = New-Object System.Text.StringBuilder

foreach ($prop in $files.PSObject.Properties) {
    $fileName = $prop.Name
    $fileInfo = $prop.Value

    $url = $fileInfo.url
    $sha1 = $fileInfo.sha1
    $size = $fileInfo.size

    if (-not $url) { continue }

    [void]$aria2Content.AppendLine($url)
    [void]$aria2Content.AppendLine("  out=$fileName")
    if ($sha1) {
        [void]$aria2Content.AppendLine("  checksum=sha-1=$sha1")
    }
    [void]$aria2Content.AppendLine("")

    $fileCount++
    $totalSize += [long]$size
}

$aria2Content.ToString() | Out-File -FilePath $aria2File -Encoding utf8 -NoNewline
$totalSizeGB = [math]::Round($totalSize / 1GB, 2)
Write-Host "Generated aria2 input file: $fileCount files, ~${totalSizeGB} GB total"

# Step 4: Extract build number from title
$buildNumber = "unknown"
if ($updateTitle -match '(\d{5}\.\d+)') {
    $buildNumber = $Matches[1]
} elseif ($updateTitle -match '(\d{5})') {
    $buildNumber = $Matches[1]
}

$buildDate = Get-Date -Format "yyyyMMdd"

# Output to GITHUB_OUTPUT
"update_title=$updateTitle" >> $env:GITHUB_OUTPUT
"build_number=$buildNumber" >> $env:GITHUB_OUTPUT
"build_date=$buildDate" >> $env:GITHUB_OUTPUT
"uuid=$uuid" >> $env:GITHUB_OUTPUT

Write-Host ""
Write-Host "Build: $updateTitle"
Write-Host "Build Number: $buildNumber"
Write-Host "Date: $buildDate"
Write-Host "UUID: $uuid"
