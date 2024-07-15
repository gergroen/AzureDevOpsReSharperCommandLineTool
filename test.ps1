param (
   [Parameter(Mandatory = $true)] 
   [string]$targetSolutionFile
)

function Get-VstsInput {
    return  $targetSolutionFile;
}

.\AzureDevOpsReSharperCommandLineTools\ReSharperCommandLineTools.ps1