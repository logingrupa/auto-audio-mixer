# /src/Audio/Processing/Compressor.psm1
using namespace System.Management.Automation

function global:Invoke-AudioCompression {
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

# Explicitly export the function
Export-ModuleMember -Function Invoke-AudioCompression