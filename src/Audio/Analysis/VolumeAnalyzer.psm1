# /src/Audio/Analysis/VolumeAnalyzer.psm1
using namespace System.Management.Automation
using namespace System.IO

# Dependencies: AudioTypes.psm1 (AudioVolumeStats)

function Get-AudioVolumeStats {
    [CmdletBinding()]
    [OutputType([AudioVolumeStats])]
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

            return [AudioVolumeStats]::new($meanVolume, $maxVolume, -100.0)  # Min volume defaulted
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

Export-ModuleMember -Function Get-AudioVolumeStats
