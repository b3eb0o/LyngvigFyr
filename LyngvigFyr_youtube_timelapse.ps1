
<# 
.SYNOPSIS
    YouTube Timelapse Capture Script
.DESCRIPTION
    Creates timelapse videos from YouTube livestream during daylight hours
.NOTES
    Author: Bernhard & claude sonnet 3.4
    Last Updated: 2025-07-13
    Requirements: 
        - FFmpeg (winget install Gyan.FFmpeg)
        - yt-dlp (winget install yt-dlp)
        - Firefox with YouTube login
#>

# Configuration
$youtubeUrl = "https://www.youtube.com/live/5Z6Nhw6USVw?si=_qx2uVVCWuvGKVwE"
$targetVideoLength = 90  # desired length of final timelapse in seconds
$targetFPS = 60          # desired frames per second in final video
$captureInterval = 5     # minimum seconds between captures
$preRunTime = 30        # minutes before sunrise
$postRunTime = 45       # minutes after sunset
$locationName = "Sondervig"  # Location in Denmark
$browserForCookies = "firefox"  # Using Firefox for cookies

# Get the script's directory
$scriptPath = $PSScriptRoot
if (-not $scriptPath) {
    $scriptPath = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
}

# Define folders relative to script location
$baseFolder = Join-Path $scriptPath "timelapse_capture"
$timelapseFolder = Join-Path $scriptPath "timelapses"
$cookieFile = Join-Path $scriptPath "youtube.txt"

# FFmpeg path for your specific installation
$ffmpegPath = "C:\ffmpeg.exe"

# Function to get stream URL with cookies
function Get-StreamUrl {
    param (
        [string]$url
    )
    
    try {
        # First try with cookie file if it exists
        if (Test-Path $cookieFile) {
            Write-Host "Using cookie file..."
            $streamUrl = yt-dlp --cookies $cookieFile -f "b" -g $url
        } else {
            Write-Host "Using Firefox cookies..."
            $streamUrl = yt-dlp --cookies-from-browser firefox -f "b" -g $url
        }
        return $streamUrl
    }
    catch {
        Write-Host "Error getting stream URL: $_"
        return $null
    }
}

# Verify FFmpeg exists
if (-not (Test-Path $ffmpegPath)) {
    Write-Host "Error: FFmpeg not found at: $ffmpegPath"
    Write-Host "Please verify the FFmpeg path"
    exit 1
}
else {
    Write-Host "FFmpeg found at: $ffmpegPath"
    # Test FFmpeg version
    $ffmpegVersion = & $ffmpegPath -version
    Write-Host "FFmpeg version information:"
    Write-Host $ffmpegVersion[0]
}

# Load required assembly for URL encoding
Add-Type -AssemblyName System.Web

function Calculate-CaptureParameters {
    param (
        $sunTimes
    )
    
    $now = Get-Date
    $captureStart = $sunTimes.Sunrise.AddMinutes(-$preRunTime)
    $captureEnd = $sunTimes.Sunset.AddMinutes($postRunTime)
    
    # Adjust start time if we're starting late
    if ($now -gt $captureStart) {
        $captureStart = $now
    }
    
    $totalCaptureSeconds = ($captureEnd - $captureStart).TotalSeconds
    
    # Calculate total frames needed for target video length
    $totalFramesNeeded = $targetFPS * $targetVideoLength
    
    # Calculate interval to achieve desired frames
    $finalInterval = [math]::Ceiling($totalCaptureSeconds / $totalFramesNeeded)
    
    # Ensure minimum interval
    $finalInterval = [math]::Max($finalInterval, $captureInterval)
    
    # Calculate actual frames that will be captured
    $totalFrames = [math]::Floor($totalCaptureSeconds / $finalInterval)
    
    # Calculate actual video length
    $actualVideoLength = $totalFrames / $targetFPS
    
    Write-Host "Debug Info:"
    Write-Host "Total capture seconds: $totalCaptureSeconds"
    Write-Host "Frames needed: $totalFramesNeeded"
    Write-Host "Calculated interval: $finalInterval"
    Write-Host "Expected frames: $totalFrames"
    Write-Host "Expected video length: $actualVideoLength seconds"
    
    return @{
        CaptureInterval = $finalInterval
        TotalFrames = $totalFrames
        ExpectedLength = [math]::Round($actualVideoLength, 1)
        CaptureStart = $captureStart
        CaptureEnd = $captureEnd
        DayProgress = 100
    }
}

function Get-Coordinates {
    param (
        [string]$location
    )
    
    try {
        # Simple URL encoding without HttpUtility
        $encodedLocation = $location.Replace(' ', '%20')
        $apiUrl = "https://nominatim.openstreetmap.org/search?q=$encodedLocation&format=json&limit=1"
        
        # Add User-Agent header as required by Nominatim
        $headers = @{
            "User-Agent" = "PowerShell/TimeLapseScript"
        }
        
        # Add delay to respect Nominatim usage policy
        Start-Sleep -Seconds 1
        
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers
        
        if ($response.Count -eq 0) {
            Write-Host "Location not found. Please check the spelling or try a different location."
            exit 1
        }
        
        $coordinates = @{
            Latitude = [double]$response[0].lat
            Longitude = [double]$response[0].lon
            DisplayName = $response[0].display_name
        }
        
        return $coordinates
    }
    catch {
        Write-Host "Error getting coordinates: $_"
        Write-Host "API Response: $response"
        Write-Host "URL used: $apiUrl"
        exit 1
    }
}
function Get-SunTimes {
    param (
        [double]$lat,
        [double]$lng,
        [datetime]$date
    )
    
    $dateStr = $date.ToString("yyyy-MM-dd")
    $apiUrl = "https://api.sunrise-sunset.org/json?lat=$lat&lng=$lng&date=$dateStr&formatted=0"
    
    try {
        $response = Invoke-RestMethod -Uri $apiUrl
        $sunrise = [datetime]::ParseExact($response.results.sunrise, "yyyy-MM-ddTHH:mm:ssK", $null).ToLocalTime()
        $sunset = [datetime]::ParseExact($response.results.sunset, "yyyy-MM-ddTHH:mm:ssK", $null).ToLocalTime()
        
        return @{
            Sunrise = $sunrise
            Sunset = $sunset
        }
    }
    catch {
        Write-Host "Error getting sun times: $_"
        return $null
    }
}

function Should-CaptureNow {
    param (
        $sunTimes
    )
    
    $now = Get-Date
    $captureStart = $sunTimes.Sunrise.AddMinutes(-$preRunTime)
    $captureEnd = $sunTimes.Sunset.AddMinutes($postRunTime)
    
    # Capture between (sunrise - preRunTime) and (sunset + postRunTime)
    return ($now -ge $captureStart -and $now -le $captureEnd)
}

# Get coordinates from location name
Write-Host "Looking up coordinates for $locationName..."
$coordinates = Get-Coordinates -location $locationName
$latitude = $coordinates.Latitude
$longitude = $coordinates.Longitude

Write-Host "Location found: $($coordinates.DisplayName)"
Write-Host "Coordinates: $latitude, $longitude"

# Create base folders if they don't exist
$framesFolder = Join-Path $baseFolder "frames"
New-Item -ItemType Directory -Force -Path $framesFolder | Out-Null
New-Item -ItemType Directory -Force -Path $timelapseFolder | Out-Null

Write-Host "Frames will be saved in: $framesFolder"
Write-Host "Timelapses will be saved in: $timelapseFolder"

# Initialize daily capture flag
$todaysCaptureComplete = $false
$currentDate = (Get-Date).Date

Write-Host "Starting continuous capture... Press Ctrl+C to stop"
Write-Host "Target video length: $targetVideoLength seconds"
Write-Host "Target frame rate: $targetFPS fps"
Write-Host "Minimum capture interval: $captureInterval seconds"
Write-Host "Location: $locationName ($latitude, $longitude)"
Write-Host "Pre-run time: $preRunTime minutes before sunrise"
Write-Host "Post-run time: $postRunTime minutes after sunset"
Write-Host "Using cookies from: $(if (Test-Path $cookieFile) { "cookie file" } else { "Firefox browser" })"

while ($true) {
    # Check if we need to reset for a new day
    if ((Get-Date).Date -ne $currentDate) {
        $todaysCaptureComplete = $false
        $currentDate = (Get-Date).Date
        Write-Host "`nStarting new day: $($currentDate.ToString('yyyy-MM-dd'))"
    }
    
    # Skip if today's capture is already complete
    if ($todaysCaptureComplete) {
        $now = Get-Date
        $tomorrow = $currentDate.AddDays(1)
        $waitTime = ($tomorrow - $now).TotalSeconds
        Write-Host "Today's capture complete. Waiting for tomorrow..."
        Write-Host "Next capture will start at: $($tomorrow.ToString('yyyy-MM-dd HH:mm:ss'))"
        Start-Sleep -Seconds $waitTime
        continue
    }

    # Get sun times for today
    $sunTimes = Get-SunTimes -lat $latitude -lng $longitude -date (Get-Date)
    if ($null -eq $sunTimes) {
        Write-Host "Could not get sun times. Waiting 5 minutes..."
        Start-Sleep -Seconds 300
        continue
    }
    
    # Calculate capture parameters for today
    $captureParams = Calculate-CaptureParameters -sunTimes $sunTimes
    
    Write-Host "`nToday's capture parameters:"
    Write-Host "Capture interval: $($captureParams.CaptureInterval) seconds"
    Write-Host "Total frames to capture: $($captureParams.TotalFrames)"
    Write-Host "Expected video length: $($captureParams.ExpectedLength) seconds at $targetFPS fps"
    Write-Host "Capture start: $($captureParams.CaptureStart.ToString('HH:mm:ss'))"
    Write-Host "Capture end: $($captureParams.CaptureEnd.ToString('HH:mm:ss'))"
    
    # Check if we should be capturing now
    if (-not (Should-CaptureNow -sunTimes $sunTimes)) {
        $now = Get-Date
        Write-Host "Outside capture window. Waiting..."
        Write-Host "Today's schedule:"
        Write-Host "Capture start: $($captureParams.CaptureStart.ToString('HH:mm:ss'))"
        Write-Host "Sunrise: $($sunTimes.Sunrise.ToString('HH:mm:ss'))"
        Write-Host "Sunset: $($sunTimes.Sunset.ToString('HH:mm:ss'))"
        Write-Host "Capture end: $($captureParams.CaptureEnd.ToString('HH:mm:ss'))"
        
        # Calculate next capture window
        $nextWindow = if ($now -lt $captureParams.CaptureStart) {
            $captureParams.CaptureStart
        } else {
            $tomorrow = (Get-Date).AddDays(1)
            (Get-SunTimes -lat $latitude -lng $longitude -date $tomorrow).Sunrise.AddMinutes(-$preRunTime)
        }
        
        Write-Host "Next capture window starts at: $($nextWindow.ToString('HH:mm:ss'))"
        $waitTime = ($nextWindow - $now).TotalSeconds
        if ($waitTime -gt 0) {
            Start-Sleep -Seconds $waitTime
        }
        continue
    }

    # Get the direct stream URL using yt-dlp with cookies
    Write-Host "Getting stream URL..."
    $streamUrl = Get-StreamUrl -url $youtubeUrl
    if (-not $streamUrl) {
        Write-Host "Error: Could not get stream URL. Retrying in 5 minutes..."
        Start-Sleep -Seconds 300
        continue
    }

    $frameCounter = 0
    $currentFramesFolder = Join-Path $framesFolder (Get-Date).ToString("yyyy-MM-dd")
    New-Item -ItemType Directory -Force -Path $currentFramesFolder | Out-Null
    
    Write-Host "`nStarting daily capture"
    Write-Host "Saving frames to: $currentFramesFolder"
    
    while ($frameCounter -lt $captureParams.TotalFrames -and (Should-CaptureNow -sunTimes $sunTimes)) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $outputFile = Join-Path $currentFramesFolder "frame_$timestamp.jpg"
        
        try {
            # Refresh stream URL periodically
            if ($frameCounter % 50 -eq 0 -and $frameCounter -gt 0) {
                Write-Host "Refreshing stream URL..."
                $streamUrl = Get-StreamUrl -url $youtubeUrl
                if (-not $streamUrl) {
                    Write-Host "Error: Lost stream URL. Retrying..."
                    Start-Sleep -Seconds 5
                    continue
                }
            }

            # Capture frame
            & $ffmpegPath -y -i $streamUrl -vframes 1 -q:v 2 $outputFile -loglevel error
            
            if (Test-Path $outputFile) {
                $frameCounter++
                Write-Host "Captured frame $frameCounter of $($captureParams.TotalFrames)"
            } else {
                Write-Host "Failed to capture frame - retrying..."
                Start-Sleep -Seconds 2
                continue
            }
        }
        catch {
            Write-Host "Error capturing frame: $_"
            Start-Sleep -Seconds 2
            continue
        }
        
        Start-Sleep -Seconds $captureParams.CaptureInterval
    }
    
    # Create timelapse if we have enough frames
    if ($frameCounter -gt 0) {
        Write-Host "`nCreating daily timelapse..."
        
        # Generate timestamp for timelapse filename
        $timelapseTimestamp = (Get-Date).ToString("yyyy-MM-dd")
        $timelapseFile = Join-Path $timelapseFolder "LyngvigFyr_${timelapseTimestamp}.mp4"
        
        # Get all frames and create the file list without BOM
        $frames = Get-ChildItem -Path $currentFramesFolder -Filter "frame_*.jpg" | Sort-Object Name
        $fileContent = @()
        foreach ($frame in $frames) {
            $escapedPath = $frame.FullName -replace '\\', '/'
            $fileContent += "file '$escapedPath'"
        }
        
        # Create a temporary file list for FFmpeg without BOM
        $frameListFile = Join-Path $currentFramesFolder "frames.txt"
        [System.IO.File]::WriteAllLines($frameListFile, $fileContent)

        # Create timelapse using FFmpeg with the file list
        Write-Host "Creating video from $($frames.Count) frames..."
        Write-Host "Output will be saved to: $timelapseFile"
        & $ffmpegPath -y -f concat -safe 0 -i $frameListFile -framerate $targetFPS -c:v libx264 -pix_fmt yuv420p -loglevel error $timelapseFile
        
        if (Test-Path $timelapseFile) {
            Write-Host "Daily timelapse completed: $timelapseFile"
            $todaysCaptureComplete = $true
        } else {
            Write-Host "Error: Failed to create timelapse video!"
        }
        
        # Clean up frames and list file
        Remove-Item -Path $currentFramesFolder -Recurse -Force
        Write-Host "Cleaned up temporary frames"
    }
}
