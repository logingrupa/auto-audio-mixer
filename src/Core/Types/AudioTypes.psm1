using namespace System.Management.Automation

# Define enums for better type safety
enum AudioFileType {
    WAV
    MP3
    FLAC
    Unknown
}

enum ProcessingStage {
    Raw
    Analyzed
    Compressed
    Mixed
    Completed
    Error
}

# Enhanced AudioVolumeStats class with validation and additional properties
class AudioVolumeStats {
    [ValidateRange(-100.0, 0.0)]
    [double]$MeanVolume

    [ValidateRange(-100.0, 0.0)]
    [double]$MaxVolume

    [ValidateRange(-100.0, 0.0)]
    [double]$MinVolume

    [ValidateRange(-100.0, 100.0)]
    [double]$FixMeanVolume

    [bool]$RequiresCompression

    # Constructor with validation
    AudioVolumeStats([double]$mean, [double]$max, [double]$min) {
        $this.ValidateVolumeRange($mean, "MeanVolume")
        $this.ValidateVolumeRange($max, "MaxVolume")
        $this.ValidateVolumeRange($min, "MinVolume")

        $this.MeanVolume = $mean
        $this.MaxVolume = $max
        $this.MinVolume = $min
        $this.FixMeanVolume = $this.CalculateFixMeanVolume()
        $this.RequiresCompression = $this.DetermineCompressionNeed()
    }

    # Private method for volume validation
    hidden [void]ValidateVolumeRange([double]$value, [string]$paramName) {
        if ($value -lt -100.0 -or $value -gt 0.0) {
            throw [ArgumentException]::new(
                "Volume must be between -100.0 and 0.0 dB",
                $paramName
            )
        }
    }

    # Calculate adjusted mean volume with improvement factor
    hidden [double]CalculateFixMeanVolume() {
        # Enhanced algorithm for calculating fix mean volume
        $improvedVolume = $this.MeanVolume + 27.4
        
        # Ensure we don't exceed 0 dB
        return [Math]::Min($improvedVolume, 0.0)
    }

    # Determine if compression is needed based on volume metrics
    hidden [bool]DetermineCompressionNeed() {
        $dynamicRange = $this.MaxVolume - $this.MinVolume
        return $dynamicRange -gt 40.0 -or $this.MeanVolume -lt -24.0
    }

    # Public method to get volume analysis summary
    [hashtable]GetAnalysisSummary() {
        return @{
            MeanVolume = $this.MeanVolume
            MaxVolume = $this.MaxVolume
            MinVolume = $this.MinVolume
            FixMeanVolume = $this.FixMeanVolume
            DynamicRange = ($this.MaxVolume - $this.MinVolume)
            RequiresCompression = $this.RequiresCompression
        }
    }
}

# Audio file metadata class
class AudioFileMetadata {
    [string]$FilePath
    [AudioFileType]$FileType
    [ProcessingStage]$Stage
    [AudioVolumeStats]$VolumeStats
    [hashtable]$AdditionalMetadata

    # Constructor
    AudioFileMetadata([string]$path) {
        $this.FilePath = $path
        $this.FileType = $this.DetermineFileType($path)
        $this.Stage = [ProcessingStage]::Raw
        $this.AdditionalMetadata = @{}
    }

    # Determine file type from extension
    hidden [AudioFileType] DetermineFileType([string]$path) {
        $extension = [System.IO.Path]::GetExtension($path).ToLower()
        switch ($extension) {
            '.wav' { return [AudioFileType]::WAV }
            '.mp3' { return [AudioFileType]::MP3 }
            '.flac' { return [AudioFileType]::FLAC }
            default { return [AudioFileType]::Unknown }
        }

        # Failsafe return if no conditions match (this should never execute)
        return [AudioFileType]::Unknown
    }

    # Update volume stats
    [void]UpdateVolumeStats([AudioVolumeStats]$stats) {
        $this.VolumeStats = $stats
        $this.Stage = [ProcessingStage]::Analyzed
    }

    # Add or update additional metadata
    [void]AddMetadata([string]$key, [object]$value) {
        $this.AdditionalMetadata[$key] = $value
    }

    # Get full metadata summary
    [hashtable]GetMetadataSummary() {
        return @{
            FilePath = $this.FilePath
            FileType = $this.FileType.ToString()
            Stage = $this.Stage.ToString()
            VolumeStats = if ($this.VolumeStats) {
                $this.VolumeStats.GetAnalysisSummary()
            } else {
                $null
            }
            AdditionalMetadata = $this.AdditionalMetadata.Clone()
        }
    }
}

# Export public types
Export-ModuleMember -Function *