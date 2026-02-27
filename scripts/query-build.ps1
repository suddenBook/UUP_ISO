param(
    [Parameter(Mandatory)][string]$Product,
    [Parameter(Mandatory)][string]$Channel,
    [Parameter(Mandatory)][string]$Milestone,
    [Parameter(Mandatory)][string]$Architecture,
    [Parameter(Mandatory)][string]$Language,
    [Parameter(Mandatory)][string]$Edition
)

$ErrorActionPreference = "Stop"

# Validate product
if ($Product -notin @("Windows 11", "Windows 10", "Windows Server")) {
    Write-Error "Invalid product: '$Product'. Must be 'Windows 11', 'Windows 10', or 'Windows Server'"
    exit 1
}

# Validate product/edition combinations
$serverEditions = @("SERVERSTANDARD", "SERVERSTANDARDCORE", "SERVERDATACENTER", "SERVERDATACENTERCORE")
$clientEditions = @("PROFESSIONAL", "CORE")

if ($Product -eq "Windows Server" -and $Edition -notin $serverEditions) {
    Write-Error "Invalid edition '$Edition' for Windows Server. Must be one of: $($serverEditions -join ', ')"
    exit 1
}
if ($Product -in @("Windows 11", "Windows 10") -and $Edition -notin $clientEditions) {
    Write-Error "Invalid edition '$Edition' for $Product. Must be one of: $($clientEditions -join ', ')"
    exit 1
}

# Validate architecture: arm64 only for Windows 11
if ($Product -in @("Windows 10", "Windows Server") -and $Architecture -eq "arm64") {
    Write-Error "arm64 is only supported for Windows 11. $Product requires amd64."
    exit 1
}

# Validate language code format
if ($Language -notmatch '^[a-z]{2}-[a-z]{2}$') {
    Write-Error "Invalid language code format: '$Language'. Expected format: xx-xx (e.g., en-us, zh-cn)"
    exit 1
}

$baseUrl = "https://api.uupdump.net"

Write-Host "Product: $Product"
Write-Host "Channel: $Channel"
Write-Host "Milestone: $Milestone"
Write-Host "Architecture: $Architecture"
Write-Host "Language: $Language"
Write-Host "Edition: $Edition"
Write-Host ""

# Step 1: Get UUID based on product and channel
$uuid = $null
$updateTitle = $null

if ($Product -eq "Windows 10") {
    # Windows 10: always use Feature Update for 22H2
    Write-Host "Querying listid API for Windows 10 22H2 Feature Update..."
    $searchUrl = "$baseUrl/listid.php?search=Feature+update+to+Windows+10%2C+version+22H2&sortByDate=1"
    $response = Invoke-RestMethod -Uri $searchUrl -Method Get

    if ($response.response.error) {
        Write-Error "API error: $($response.response.error)"
        exit 1
    }

    $builds = $response.response.builds
    if (-not $builds) {
        Write-Error "No Feature Update builds found for Windows 10 22H2"
        exit 1
    }

    $matched = $null
    foreach ($prop in $builds.PSObject.Properties) {
        $build = $prop.Value
        $titleMatch = $build.title -like "*Feature update to Windows 10, version 22H2*"
        $archMatch = $build.arch -eq $Architecture
        if ($titleMatch -and $archMatch) {
            $matched = $build
            $uuid = $build.uuid
            break
        }
    }

    if (-not $matched) {
        Write-Error "No matching Feature Update found for Windows 10 22H2 ($Architecture)"
        exit 1
    }

    $updateTitle = $matched.title
    Write-Host "Found: $updateTitle (UUID: $uuid)"
}
elseif ($Product -eq "Windows Server") {
    # Windows Server: always use Server 2025 (24H2)
    Write-Host "Querying listid API for Windows Server 2025..."
    $searchUrl = "$baseUrl/listid.php?search=Windows+Server+2025&sortByDate=1"
    $response = Invoke-RestMethod -Uri $searchUrl -Method Get

    if ($response.response.error) {
        Write-Error "API error: $($response.response.error)"
        exit 1
    }

    $builds = $response.response.builds
    if (-not $builds) {
        Write-Error "No builds found for Windows Server 2025"
        exit 1
    }

    $matched = $null
    foreach ($prop in $builds.PSObject.Properties) {
        $build = $prop.Value
        $titleMatch = $build.title -like "*Windows Server 2025*"
        $archMatch = $build.arch -eq $Architecture
        if ($titleMatch -and $archMatch) {
            $matched = $build
            $uuid = $build.uuid
            break
        }
    }

    if (-not $matched) {
        Write-Error "No matching build found for Windows Server 2025 ($Architecture)"
        exit 1
    }

    $updateTitle = $matched.title
    Write-Host "Found: $updateTitle (UUID: $uuid)"
}
elseif ($Channel -in @("Retail", "ReleasePreview")) {
    # Windows 11: Retail/ReleasePreview channels
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
    # Windows 11: Beta, Dev, Canary - use fetchupd API
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

# Step 2b: Add en-us language pack if primary language is not en-us
if ($Language -ne "en-us") {
    Write-Host "Adding en-us language pack alongside primary language ($Language)..."
    Write-Host "Waiting 10 seconds before API call..."
    Start-Sleep -Seconds 10

    $enUrl = "$baseUrl/get.php?id=$uuid&lang=en-us&edition=$Edition"
    try {
        $enResponse = Invoke-RestMethod -Uri $enUrl -Method Get
        if (-not $enResponse.response.error) {
            $enFiles = $enResponse.response.files
            $enCount = 0
            foreach ($prop in $enFiles.PSObject.Properties) {
                if (-not ($files.PSObject.Properties.Name -contains $prop.Name)) {
                    $files | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
                    $enCount++
                }
            }
            Write-Host "Added $enCount en-us language files"
        } else {
            Write-Warning "Could not fetch en-us files: $($enResponse.response.error)"
        }
    } catch {
        Write-Warning "Failed to fetch en-us language pack: $_"
        Write-Warning "Continuing with primary language only"
    }
}

# Step 2c: Get Store App packages if available
if ($fileResponse.response.appxPresent -eq $true) {
    Write-Host "Store App packages detected, fetching app file list..."
    $appUrl = "$baseUrl/get.php?id=$uuid&lang=neutral&edition=APP"
    $maxRetries = 3
    $appFiles = $null

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Host "Waiting 10 seconds before API call (attempt $attempt/$maxRetries)..."
        Start-Sleep -Seconds 10

        try {
            $appResponse = Invoke-RestMethod -Uri $appUrl -Method Get
            if ($appResponse.response.error) {
                Write-Warning "API returned error: $($appResponse.response.error)"
            } else {
                $appFiles = $appResponse.response.files
                break
            }
        } catch {
            Write-Warning "Request failed: $_"
        }
    }

    if (-not $appFiles) {
        Write-Error "Failed to fetch Store App packages after $maxRetries attempts"
        exit 1
    }

    $appCount = 0
    foreach ($prop in $appFiles.PSObject.Properties) {
        $appCount++
        $files | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
    }
    Write-Host "Added $appCount app package files"
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

# Create a clean release title by stripping common prefixes
$releaseTitle = $updateTitle -replace '^Feature update to ', ''

# Output to GITHUB_OUTPUT
"update_title=$updateTitle" >> $env:GITHUB_OUTPUT
"release_title=$releaseTitle" >> $env:GITHUB_OUTPUT
"build_number=$buildNumber" >> $env:GITHUB_OUTPUT
"build_date=$buildDate" >> $env:GITHUB_OUTPUT
"uuid=$uuid" >> $env:GITHUB_OUTPUT

Write-Host ""
Write-Host "Build: $updateTitle"
Write-Host "Release Title: $releaseTitle"
Write-Host "Build Number: $buildNumber"
Write-Host "Date: $buildDate"
Write-Host "UUID: $uuid"
