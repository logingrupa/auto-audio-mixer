using namespace System.Management.Automation

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
            $errorDetails = @"
[$timestamp] $errorType
Message: $message
StackTrace: $stack
"@

            # Add additional info for custom error types
            if ($Exception -is [AudioProcessingError]) {
                $errorDetails += @"

Operation: $($Exception.Operation)
FilePath: $($Exception.FilePath)
"@
            }

            $errorDetails += "`n" + "="*50 + "`n"

            # Ensure directory exists
            $logDir = Split-Path -Parent $LogPath
            if (-not [string]::IsNullOrEmpty($logDir) -and -not (Test-Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }

            # Append to log file
            Add-Content -Path $LogPath -Value $errorDetails

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

function Test-FFmpegAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    process {
        try {
            $null = Get-Command ffmpeg -ErrorAction Stop
            $null = Get-Command ffprobe -ErrorAction Stop
            return $true
        }
        catch {
            Write-Error "FFmpeg tools not found. Please ensure ffmpeg and ffprobe are installed and in PATH."
            return $false
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
    'Write-ErrorLog',
    'Test-FFmpegAvailable',
    'Invoke-WithErrorHandling'
)