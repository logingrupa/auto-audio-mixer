# Optimized version of auto-audio-mixer-v2.psm1
using namespace System.Management.Automation

# Import required functions at module scope
$modulePath = Split-Path -Parent $MyInvocation.MyCommand.Path
@(
    'src/Core/Types/AudioTypes.psm1',
    'src/Core/Utils/ErrorHandling.psm1',
    'src/Audio/Analysis/VolumeAnalyzer.psm1',
    'src/IO/MetadataManager.psm1',
    'src/Audio/Processing/Compressor.psm1'
) | ForEach-Object {
    $fullPath = Join-Path $modulePath $_
    if (Test-Path $fullPath) {
        Import-Module $fullPath -Force
    }
    else {
        Write-Warning "Module not found: $_"
    }
}

function Invoke-AudioProcessing {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderPath,
        
        [Parameter()]
        [int]$ThrottleLimit = 4,
        
        [Parameter()]
        [switch]$Force
    )

    begin {
        Write-Verbose "Starting audio processing for folder: $FolderPath"
        Set-StrictMode -Version Latest
    }

    process {
        # Validate folder and FFmpeg
        if (-not (Test-Path -Path $FolderPath -PathType Container)) {
            throw [System.IO.DirectoryNotFoundException]::new("The specified folder does not exist: $FolderPath")
        }

        if (-not (Test-FFmpegAvailable)) {
            throw [System.InvalidOperationException]::new("FFmpeg is required but not available")
        }

        # Get .wav files
        $wavFiles = Get-ChildItem -Path $FolderPath -Filter "*.wav" | 
            Where-Object { ($_.Name -match "Pastor_|Radio1_") -and ($_.Name -notmatch "_automix") }

        if (-not $wavFiles) {
            Write-Warning "No matching .wav files found."
            return
        }

        # Create initial metadata path
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $metadataPath = Join-Path $FolderPath "metadata_$timestamp.json"

        # Process files in parallel and collect results
        $results = $wavFiles | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $file = $_
            $filePath = $file.FullName
            $fileName = $file.Name
            
            try {
                Write-Host "Processing file: $fileName" -ForegroundColor Cyan
                
                # Load required functions in parallel scope
                $moduleFunctions = {
                    function Get-AudioVolumeStats {
                        param ([string]$FilePath)
                        $volumeLog = [System.IO.Path]::ChangeExtension($FilePath, ".volumedetect.log")
                        try {
                            $ffmpegOutput = & ffmpeg -i $FilePath -af "volumedetect" -f null NUL 2>&1
                            $null = $ffmpegOutput | Out-File -FilePath $volumeLog -Encoding utf8
                            
                            $meanVolume = [double](Select-String -Path $volumeLog -Pattern "mean_volume: (-?\d+\.?\d*) dB" | 
                                ForEach-Object { $_.Matches.Groups[1].Value })
                            $maxVolume = [double](Select-String -Path $volumeLog -Pattern "max_volume: (-?\d+\.?\d*) dB" | 
                                ForEach-Object { $_.Matches.Groups[1].Value })
                            
                            return @{
                                MeanVolume = $meanVolume
                                MaxVolume = $maxVolume
                                MinVolume = -100.0  # Default value
                                FixMeanVolume = [Math]::Min($meanVolume + 27.4, 0.0)
                                RequiresCompression = ($maxVolume - (-100.0)) -gt 40.0 -or $meanVolume -lt -24.0
                            }
                        }
                        finally {
                            if (Test-Path $volumeLog) {
                                Remove-Item -Path $volumeLog -Force
                            }
                        }
                    }

                    function Invoke-AudioCompression {
                        param (
                            [string]$InputPath,
                            [double]$Threshold
                        )
                        
                        $directory = [System.IO.Path]::GetDirectoryName($InputPath)
                        $filename = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
                        $extension = [System.IO.Path]::GetExtension($InputPath)
                        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
                        $outputPath = Join-Path $directory ($filename + "_automixd_$timestamp" + $extension)

                        $ffmpegArgs = @(
                            "-i", $InputPath,
                            "-af", "acompressor=threshold=${Threshold}dB:ratio=20:attack=5:release=200",
                            $outputPath
                        )

                        $result = & ffmpeg $ffmpegArgs 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            return $outputPath
                        }
                        return $null
                    }
                }.ToString()

                Invoke-Expression $moduleFunctions
                
                # Analyze volume
                $volumeStats = Get-AudioVolumeStats -FilePath $filePath
                if (-not $volumeStats) {
                    throw "Failed to analyze volume"
                }

                # Create metadata entry
                $metadata = @{
                    FilePath = $filePath
                    VolumeStats = $volumeStats
                    ProcessingTimestamp = [datetime]::UtcNow
                }

                # Apply compression if needed
                $compressedPath = $null
                if ($volumeStats.RequiresCompression) {
                    $compressedPath = Invoke-AudioCompression `
                        -InputPath $filePath `
                        -Threshold $volumeStats.FixMeanVolume

                    if ($compressedPath) {
                        Write-Host "Compression complete: $compressedPath" -ForegroundColor Green
                    }
                }

                # Return both metadata and processing result
                return @{
                    Status = "Success"
                    File = $fileName
                    Metadata = $metadata
                    CompressedPath = $compressedPath
                }
            }
            catch {
                Write-Error "Error processing ${fileName}: $_"
                return @{
                    Status = "Error"
                    File = $fileName
                    Error = $_.Exception.Message
                }
            }
        }

        # Collect metadata from successful results
        $metadataCollection = @{}
        $successfulResults = @($results | Where-Object Status -eq "Success")
        foreach ($result in $successfulResults) {
            $metadataCollection[$result.File] = $result.Metadata
        }

        # Save metadata efficiently
        if ($successfulResults.Length -gt 0) {
            $metadataCollection | 
                ConvertTo-Json -Depth 10 | 
                Set-Content -Path $metadataPath -NoNewline -Encoding utf8
        }

        # Summarize results
        $successCount = @($results | Where-Object Status -eq "Success").Length
        $errorCount = @($results | Where-Object Status -eq "Error").Length

        Write-Host "`nProcessing Summary:" -ForegroundColor Cyan
        Write-Host "Successfully processed: $successCount files" -ForegroundColor Green
        if ($errorCount -gt 0) {
            Write-Host "Failed to process: $errorCount files" -ForegroundColor Red
            Write-Host "Failed files with errors:" -ForegroundColor Red
            $results | Where-Object Status -eq "Error" | ForEach-Object {
                Write-Host "- $($_.File) - $($_.Error)" -ForegroundColor Red
            }
        }
        
        if ($metadataCollection.Count -gt 0) {
            Write-Host "Metadata saved to: $metadataPath" -ForegroundColor Green
        }

        # Return results object for potential further processing
        return @{
            SuccessCount = $successCount
            ErrorCount = $errorCount
            MetadataPath = $metadataPath
            Results = $results
        }
    }
}

# Export only the main function
Export-ModuleMember -Function Invoke-AudioProcessing