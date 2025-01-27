# /src/IO/MetadataManager.psm1
using namespace System.Management.Automation

function Save-AudioMetadata {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$FolderPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$MetadataCollection
    )

    process {
        try {
            $outputPath = Join-Path $FolderPath "metadata_output.json"
            $MetadataCollection | ConvertTo-Json -Depth 10 | Out-File -FilePath $outputPath -Encoding utf8
            Write-Verbose "Metadata saved to $outputPath"
            return $outputPath
        }
        catch {
            Write-Error "Error saving metadata: $_"
            return $null
        }
    }
}

function Update-AudioMetadata {
    [CmdletBinding()]
    [OutputType([bool])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$JsonPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$NewMetadata
    )

    process {
        try {
            $existingMetadata = Get-Content $JsonPath | ConvertFrom-Json | ConvertTo-Hashtable
            $existingMetadata[$FileName] = $NewMetadata

            $existingMetadata | ConvertTo-Json -Depth 10 | Out-File -FilePath $JsonPath -Encoding utf8
            Write-Verbose "Metadata updated for $FileName in $JsonPath"
            return $true
        }
        catch {
            Write-Error "Error updating metadata: $_"
            return $false
        }
    }
}

Export-ModuleMember -Function Save-AudioMetadata, Update-AudioMetadata
