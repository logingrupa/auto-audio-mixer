# Main module script
using namespace System.Management.Automation

# Determine the module's root directory
$ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# List of modules to import with full paths
$ModulesToImport = @(
    "$ModuleRoot\src\Core\Types\AudioTypes.psm1",
    "$ModuleRoot\src\Core\Utils\ErrorHandling.psm1",
    "$ModuleRoot\src\Audio\Analysis\VolumeAnalyzer.psm1",
    "$ModuleRoot\src\IO\MetadataManager.psm1",
    "$ModuleRoot\src\Audio\Processing\Compressor.psm1"
)

# Import required modules with error handling
foreach ($modulePath in $ModulesToImport) {
    if (Test-Path $modulePath) {
        try {
            Import-Module $modulePath -Force -Global -ErrorAction Stop
            Write-Verbose "Successfully imported module: $modulePath"
        }
        catch {
            Write-Error "Failed to import module $modulePath. Error: $_"
        }
    }
    else {
        Write-Error "Module file not found: $modulePath"
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
            Where-Object { ($_.Name -match "Pastor_|Radio1_") -and ($_.Name -notmatch "_automixd") }

        if (-not $wavFiles) {
            Write-Warning "No matching .wav files found."
            return
        }
        
        # Create initial metadata path
        $timestamp = Get-Date -Format 'yyyy-MM-dd'
        $metadataPath = Join-Path $FolderPath "metadata.json"
        
        # Process files in parallel and collect results
        $results = $wavFiles | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            # Store the module root from the parent scope
            $ModuleRoot = $using:ModuleRoot

            # Define functions inline to ensure availability
            function Get-AudioVolumeStats {
                [CmdletBinding()]
                [OutputType([hashtable])]
                param (
                    [Parameter(Mandatory = $true)]
                    [ValidateNotNullOrEmpty()]
                    [ValidateScript({ Test-Path $_ -PathType Leaf })]
                    [string]$FilePath
                )

                begin {
                    Write-Verbose "Analyzing volume for file: $FilePath"
                }

                process {
                    $volumeLog = [System.IO.Path]::ChangeExtension($FilePath, ".volumedetect.log")
                    try {
                        # Run FFmpeg volume detection
                        $ffmpegOutput = & ffmpeg -i $FilePath -af "volumedetect" -f null NUL 2>&1
                        $null = $ffmpegOutput | Out-File -FilePath $volumeLog -Encoding utf8

                        # Extract mean and max volume from log
                        $meanVolume = [double](Select-String -Path $volumeLog -Pattern "mean_volume: (-?\d+\.?\d*) dB" | 
                            ForEach-Object { $_.Matches.Groups[1].Value })
                        $maxVolume = [double](Select-String -Path $volumeLog -Pattern "max_volume: (-?\d+\.?\d*) dB" | 
                            ForEach-Object { $_.Matches.Groups[1].Value })

                        # Construct return object
                        $volumeStats = @{
                            MeanVolume = $meanVolume
                            MaxVolume = $maxVolume
                            MinVolume = -100.0  # Default value
                            FixMeanVolume = [Math]::Min($meanVolume + 27.4, 0.0)
                            RequiresCompression = ($maxVolume - (-100.0)) -gt 40.0 -or $meanVolume -lt -24.0
                        }

                        return $volumeStats
                    }
                    catch {
                        Write-Error "Error analyzing volume: $_"
                        return $null
                    }
                    finally {
                        if (Test-Path $volumeLog) {
                            Remove-Item -Path $volumeLog -Force
                        }
                    }
                }
            }

            function Invoke-AudioCompression {
                [CmdletBinding()]
                [OutputType([string])]
                param (
                    [Parameter(Mandatory = $true)]
                    [ValidateNotNullOrEmpty()]
                    [ValidateScript({ Test-Path $_ -PathType Leaf })]
                    [string]$InputPath,

                    [Parameter(Mandatory = $true)]
                    [ValidateRange(-100, 0)]
                    [double]$Threshold
                )

                begin {
                    Write-Verbose "Starting audio compression for: $InputPath"
                }

                process {
                    try {
                        $directory = [System.IO.Path]::GetDirectoryName($InputPath)
                        $filename = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
                        $extension = [System.IO.Path]::GetExtension($InputPath)
                        $outputPath = Join-Path $directory ($filename + "_automixd" + $extension)

                        $ffmpegArgs = @(
                            "-y",  # Overwrite output files without asking
                            "-i", $InputPath,
                            "-af", "acompressor=threshold=${Threshold}dB:ratio=20:attack=5:release=200",
                            $outputPath
                        )

                        $result = & ffmpeg $ffmpegArgs 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "FFmpeg compression failed with exit code: $LASTEXITCODE"
                        }

                        Write-Verbose "Audio compression successful. Output: $outputPath"
                        return $outputPath
                    }
                    catch {
                        Write-Error "Error applying compression: $_"
                        return $null
                    }
                }
            }

            $file = $_
            $filePath = $file.FullName
            $fileName = $file.Name
            
            try {
                Write-Host "Processing file: $fileName" -ForegroundColor Cyan
                
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

# Export only the main function and add a verbose import confirmation
Export-ModuleMember -Function Invoke-AudioProcessing
Write-Verbose "Auto Audio Mixer v2 module imported successfully."