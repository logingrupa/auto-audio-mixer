# /src/Core/Utils/ErrorHandling.psm1
using namespace System.Management.Automation

function Test-FFmpegAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    begin {
        Write-Verbose "Checking FFmpeg availability"
    }

    process {
        try {
            # Try to get FFmpeg version info
            $ffmpegVersion = & ffmpeg -version
            if ($LASTEXITCODE -eq 0 -and $ffmpegVersion) {
                Write-Verbose "FFmpeg found and working"
                return $true
            }
            Write-Warning "FFmpeg command executed but returned unexpected results"
            return $false
        }
        catch {
            Write-Warning "FFmpeg not found or not accessible: $_"
            return $false
        }
    }
}

function Test-FFmpegCapabilities {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    process {
        $capabilities = @{
            HasFFmpeg = $false
            HasVolumeDetect = $false
            HasCompressor = $false
            Version = $null
        }

        try {
            # Check basic FFmpeg availability
            $versionOutput = & ffmpeg -version 2>&1
            if ($LASTEXITCODE -eq 0) {
                $capabilities.HasFFmpeg = $true
                
                # Extract version
                if ($versionOutput -match 'ffmpeg version (\S+)') {
                    $capabilities.Version = $matches[1]
                }

                # Check for volume detection capability
                $filterOutput = & ffmpeg -filters 2>&1
                if ($filterOutput -match 'volumedetect') {
                    $capabilities.HasVolumeDetect = $true
                }

                # Check for compressor capability
                if ($filterOutput -match 'acompressor') {
                    $capabilities.HasCompressor = $true
                }
            }
        }
        catch {
            Write-Warning "Error checking FFmpeg capabilities: $_"
        }

        return $capabilities
    }
}

# Custom error types
class AudioProcessingError : Exception {
    [string]$Operation
    [string]$FilePath
    [datetime]$Timestamp

    AudioProcessingError([string]$message, [string]$operation, [string]$filePath) : base($message) {
        $this.Operation = $operation
        $this.FilePath = $filePath
        $this.Timestamp = [datetime]::Now
    }
}

class AudioAnalysisError : AudioProcessingError {
    AudioAnalysisError([string]$message, [string]$filePath) : base($message, "Analysis", $filePath) { }
}

class AudioCompressionError : AudioProcessingError {
    AudioCompressionError([string]$message, [string]$filePath) : base($message, "Compression", $filePath) { }
}

# Error handling functions
function Write-ErrorLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Exception]$Exception,

        [Parameter(Mandatory = $false)]
        [string]$LogPath = ".\errors.log",

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    process {
        try {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $errorType = $Exception.GetType().Name
            $message = $Exception.Message
            $stack = $Exception.StackTrace

            # Format error details
            $errorLog = @{
                Timestamp = $timestamp
                ErrorType = $errorType
                Message = $message
                StackTrace = $stack
            }

            # Add additional info for custom error types
            if ($Exception -is [AudioProcessingError]) {
                $errorLog.Operation = $Exception.Operation
                $errorLog.FilePath = $Exception.FilePath
            }

            # Convert to JSON for structured logging
            $jsonError = $errorLog | ConvertTo-Json

            # Ensure directory exists
            $logDir = Split-Path -Parent $LogPath
            if (-not [string]::IsNullOrEmpty($logDir) -and -not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }

            # Append to log file
            Add-Content -Path $LogPath -Value $jsonError

            # Write to error stream
            Write-Error -Exception $Exception -ErrorAction Continue

            # Return exception if PassThru is specified
            if ($PassThru) {
                return $Exception
            }
        }
        catch {
            Write-Error "Failed to log error: $_"
            if ($PassThru) {
                return $Exception
            }
        }
    }
}

function Invoke-WithErrorHandling {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [string]$ErrorMessage = "Operation failed",

        [Parameter(Mandatory = $false)]
        [string]$Operation = "Unknown",

        [Parameter(Mandatory = $false)]
        [string]$FilePath = "",

        [Parameter(Mandatory = $false)]
        [switch]$ContinueOnError
    )

    process {
        try {
            return & $ScriptBlock
        }
        catch {
            $exception = if ($_.Exception -is [AudioProcessingError]) {
                $_.Exception
            }
            else {
                [AudioProcessingError]::new(
                    "$ErrorMessage`: $($_.Exception.Message)",
                    $Operation,
                    $FilePath
                )
            }

            Write-ErrorLog -Exception $exception

            if (-not $ContinueOnError) {
                throw $exception
            }
        }
    }
}

# Export public functions
Export-ModuleMember -Function @(
    'Test-FFmpegAvailable',
    'Test-FFmpegCapabilities',
    'Write-ErrorLog',
    'Invoke-WithErrorHandling'
)