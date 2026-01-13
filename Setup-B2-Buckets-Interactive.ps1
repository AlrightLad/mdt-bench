<#
.SYNOPSIS
    Creates Backblaze B2 buckets for Veeam backup storage.

.DESCRIPTION
    This script creates B2 buckets with encryption and lifecycle rules for each client.
    It generates API keys for each bucket and exports the credentials to a CSV file.

    IMPORTANT: This script only works with interactive input. It does not support RMM deployment.

    Prerequisites:
    - b2-windows.exe must be in the same directory as this script (auto-downloaded if missing)
    - Valid Backblaze B2 API credentials with bucket creation permissions

.NOTES
    All logs and exported data are stored in the script root directory.
    Output files:
    - backblaze-create-buckets.log (transcript log)
    - bucket-info.csv (bucket names and API keys)
#>

#Requires -Version 5.1

# Lifecycle rules for bucket - files are deleted 1 day after being hidden
$lifecycleRules = @'
[{
    "daysFromHidingToDeleting": 1,
    "daysFromUploadingToHiding": null,
    "fileNamePrefix": ""
}]
'@

# Permissions required for Veeam backup operations
$bucketPermissions = @(
    "listAllBucketNames",
    "listBuckets",
    "readBuckets",
    "readBucketEncryption",
    "writeBucketEncryption",
    "readBucketRetentions",
    "writeBucketRetentions",
    "listFiles",
    "readFiles",
    "shareFiles",
    "writeFiles",
    "deleteFiles",
    "readFileLegalHolds",
    "writeFileLegalHolds",
    "readFileRetentions",
    "writeFileRetentions",
    "bypassGovernance"
) -join ","

# Start transcript logging
$logPath = Join-Path -Path $PSScriptRoot -ChildPath "backblaze-create-buckets.log"
Start-Transcript -Path $logPath

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Backblaze B2 Bucket Creation Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "All files will be stored in: $PSScriptRoot" -ForegroundColor Yellow
Write-Host ""

# Check for b2-windows.exe and download if missing
$b2ExePath = Join-Path -Path $PSScriptRoot -ChildPath "b2-windows.exe"

if (-not (Test-Path -Path $b2ExePath)) {
    Write-Host "b2-windows.exe not found. Downloading..." -ForegroundColor Yellow

    # Use raw GitHub URL for downloading
    $downloadUrl = "https://github.com/Backblaze/B2_Command_Line_Tool/releases/latest/download/b2-windows.exe"

    try {
        # Try using Invoke-WebRequest first (more reliable)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $b2ExePath -UseBasicParsing
        Write-Host "File downloaded successfully." -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to download b2-windows.exe: $_" -ForegroundColor Red
        Write-Host "Please download b2-windows.exe manually from:" -ForegroundColor Yellow
        Write-Host "https://www.backblaze.com/docs/cloud-storage-command-line-tools" -ForegroundColor Yellow
        Write-Host "Place the file in: $PSScriptRoot" -ForegroundColor Yellow
        Stop-Transcript
        exit 1
    }
} else {
    Write-Host "b2-windows.exe found." -ForegroundColor Green
}

# Get API credentials
Write-Host ""
Write-Host "Enter your Backblaze B2 API credentials:" -ForegroundColor Cyan
$userApiKey = Read-Host "Enter API Key ID (applicationKeyId)"
$userApiSecret = Read-Host "Enter API App Key (applicationKey)"

if ([string]::IsNullOrWhiteSpace($userApiKey) -or [string]::IsNullOrWhiteSpace($userApiSecret)) {
    Write-Host "API credentials cannot be empty." -ForegroundColor Red
    Stop-Transcript
    exit 1
}

# Authorize account first to validate credentials
Write-Host ""
Write-Host "Validating API credentials..." -ForegroundColor Yellow
$authResult = & $b2ExePath authorize-account $userApiKey $userApiSecret 2>&1

if ($LASTEXITCODE -ne 0 -or $authResult -match "ERROR|unauthorized") {
    Write-Host "Failed to authorize with Backblaze B2:" -ForegroundColor Red
    Write-Host $authResult -ForegroundColor Red
    Write-Host ""
    Write-Host "Please verify your API credentials are correct." -ForegroundColor Yellow
    Stop-Transcript
    exit 1
}

Write-Host "Authorization successful!" -ForegroundColor Green

# Get client list
Write-Host ""
Write-Host "How would you like to provide the client list?" -ForegroundColor Cyan
$clientListFile = Read-Host "Enter 1 to import from CSV file, or press Enter to type clients manually"

$clientList = @()

if ($clientListFile -eq "1") {
    # Import from CSV file
    $csvPath = Read-Host "Enter full path to client list CSV file"

    if (-not (Test-Path -Path $csvPath)) {
        Write-Host "CSV file not found: $csvPath" -ForegroundColor Red
        Stop-Transcript
        exit 1
    }

    try {
        $csvData = Import-Csv -Path $csvPath

        # Get the first column name (assuming client names are in the first column)
        $firstColumn = ($csvData | Get-Member -MemberType NoteProperty | Select-Object -First 1).Name

        foreach ($row in $csvData) {
            $clientName = $row.$firstColumn
            if (-not [string]::IsNullOrWhiteSpace($clientName)) {
                # Clean the client name: remove non-word characters, replace spaces with hyphens, lowercase
                $cleanedName = $clientName -replace '[^\w\s-]', '' -replace '\s+', '-'
                $cleanedName = $cleanedName.ToLower()
                $bucketName = "veeam-dtc-$cleanedName"
                $clientList += $bucketName
            }
        }

        Write-Host "Imported $($clientList.Count) clients from CSV." -ForegroundColor Green
    }
    catch {
        Write-Host "Error reading CSV file: $_" -ForegroundColor Red
        Stop-Transcript
        exit 1
    }
} else {
    # Manual entry
    $clientInput = Read-Host "Enter client names (comma-separated, exactly as in your PSA)"

    if ([string]::IsNullOrWhiteSpace($clientInput)) {
        Write-Host "No clients provided." -ForegroundColor Red
        Stop-Transcript
        exit 1
    }

    $clients = $clientInput -split ',' | ForEach-Object { $_.Trim() }

    foreach ($client in $clients) {
        if (-not [string]::IsNullOrWhiteSpace($client)) {
            # Clean the client name: remove non-word characters, replace spaces with hyphens, lowercase
            $cleanedName = $client -replace '[^\w\s-]', '' -replace '\s+', '-'
            $cleanedName = $cleanedName.ToLower()
            $bucketName = "veeam-dtc-$cleanedName"
            $clientList += $bucketName
        }
    }

    Write-Host "Parsed $($clientList.Count) clients." -ForegroundColor Green
}

if ($clientList.Count -eq 0) {
    Write-Host "No valid clients found." -ForegroundColor Red
    Stop-Transcript
    exit 1
}

# Display buckets to be created
Write-Host ""
Write-Host "The following buckets will be created:" -ForegroundColor Cyan
foreach ($bucket in $clientList) {
    Write-Host "  - $bucket" -ForegroundColor White
}

Write-Host ""
$confirm = Read-Host "Continue? (Y/N)"
if ($confirm -notmatch '^[Yy]') {
    Write-Host "Operation cancelled." -ForegroundColor Yellow
    Stop-Transcript
    exit 0
}

# CSV output file path
$csvOutputPath = Join-Path -Path $PSScriptRoot -ChildPath "bucket-info.csv"

# Create buckets for each client
Write-Host ""
Write-Host "Creating buckets..." -ForegroundColor Cyan
Write-Host ""

$successCount = 0
$failCount = 0

foreach ($bucketName in $clientList) {
    Write-Host "============================================" -ForegroundColor Gray
    Write-Host "Creating bucket: $bucketName" -ForegroundColor Yellow

    # Re-authorize before each operation (session may expire)
    $null = & $b2ExePath authorize-account $userApiKey $userApiSecret 2>&1

    # Create the bucket with encryption and file lock enabled
    $createResult = & $b2ExePath create-bucket `
        --defaultServerSideEncryptionAlgorithm "AES256" `
        --defaultServerSideEncryption "SSE-B2" `
        --fileLockEnabled `
        --lifecycleRules $lifecycleRules `
        $bucketName "allPrivate" 2>&1

    if ($LASTEXITCODE -ne 0 -or $createResult -match "ERROR") {
        Write-Host "Failed to create bucket: $createResult" -ForegroundColor Red
        $failCount++
        continue
    }

    Write-Host "Bucket created successfully." -ForegroundColor Green

    # Create API key for the bucket
    Write-Host "Creating API key for bucket..." -ForegroundColor Yellow
    $keyOut = & $b2ExePath create-key $bucketName $bucketPermissions --bucket $bucketName 2>&1

    if ($LASTEXITCODE -ne 0 -or $keyOut -match "ERROR") {
        Write-Host "Failed to create API key: $keyOut" -ForegroundColor Red
        $failCount++
        continue
    }

    # Parse the key output (format: keyId keyApp)
    $keyParts = $keyOut -split '\s+'
    $keyId = $keyParts[0]
    $keyApp = $keyParts[1]

    Write-Host "API Key created successfully." -ForegroundColor Green
    Write-Host "  Key ID: $keyId" -ForegroundColor White
    Write-Host "  App Key: $keyApp" -ForegroundColor White

    # Export to CSV
    $data = [PSCustomObject]@{
        BucketName = $bucketName
        KeyId = $keyId
        KeyApp = $keyApp
    }

    $data | Export-Csv -Path $csvOutputPath -NoTypeInformation -Append

    $successCount++
    Write-Host ""
}

# Summary
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Buckets created successfully: $successCount" -ForegroundColor Green
Write-Host "Buckets failed: $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host ""
Write-Host "Output files:" -ForegroundColor Yellow
Write-Host "  Transcript log: $logPath" -ForegroundColor White
Write-Host "  Bucket info CSV: $csvOutputPath" -ForegroundColor White
Write-Host ""

Stop-Transcript
