using namespace System.Management.Automation

# Import necessary files
$modulePath = Split-Path -Parent $MyInvocation.MyCommand.Path
@(
    'src/Core/Types/AudioTypes.psm1',
    'src/Core/Utils/ErrorHandling.psm1',
    'src/Audio/Analysis/VolumeAnalyzer.psm1',
    'src/IO/MetadataManager.psm1',
    'src/Audio/Processing/Compressor.psm1'
) | ForEach-Object {
    Import-Module (Join-Path $modulePath $_) -Force
}

function Invoke-AudioProcessing {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FolderPath
    )

    begin {
        Write-Verbose "Starting audio processing for folder: $FolderPath"
        Set-StrictMode -Version Latest
    }

    process {
        # Step 1: Validate folder
        if (-not (Test-Path -Path $FolderPath -PathType Container)) {
            Write-Error "The specified folder does not exist: $FolderPath"
            return
        }

        # Step 2: Get .wav files
        $wavFiles = Get-ChildItem -Path $FolderPath -Filter "*.wav" | Where-Object {
            ($_.Name -match "Pastor_|Radio1_") -and ($_.Name -notmatch "_automix")
        }

        if (-not $wavFiles) {
            Write-Warning "No matching .wav files found."
            return
        }

        # Step 3: Process each file
        $metadataCollection = @{}
        foreach ($file in $wavFiles) {
            $filePath = $file.FullName
            $fileName = $file.Name
            Write-Host "Processing file: $fileName" -ForegroundColor Cyan

            try {
                # Analyze volume
                $volumeStats = Get-AudioVolumeStats -FilePath $filePath
                if (-not $volumeStats) {
                    Write-Error "Failed to analyze volume for $fileName"
                    continue
                }

                # Save metadata
                $metadataCollection[$fileName] = @{
                    FilePath = $filePath
                    VolumeStats = $volumeStats.GetAnalysisSummary()
                }
            }
            catch {
                Write-Error "Error processing ${fileName}: $_"
                continue
            }
        }

        # Step 4: Save metadata
        $metadataPath = Save-AudioMetadata -FolderPath $FolderPath -MetadataCollection $metadataCollection
        if ($metadataPath) {
            Write-Host "Metadata saved to: $metadataPath" -ForegroundColor Green
        } else {
            Write-Error "Failed to save metadata."
            return
        }

        # Step 5: Apply compression
        foreach ($fileName in $metadataCollection.Keys) {
            $fileData = $metadataCollection[$fileName]
            $filePath = $fileData.FilePath
            $fixMeanVolume = $fileData.VolumeStats.FixMeanVolume

            Write-Host "Applying compression to: $fileName" -ForegroundColor Cyan
            try {
                $compressedFile = Invoke-AudioCompression `
                    -InputPath $filePath `
                    -Threshold $fixMeanVolume

                if ($compressedFile) {
                    Write-Host "Compression complete: $compressedFile" -ForegroundColor Green
                } else {
                    Write-Error "Compression failed for $fileName"
                }
            }
            catch {
                Write-Error "Error compressing ${fileName}: $_"
            }
        }
    }
}

Export-ModuleMember -Function Invoke-AudioProcessing
