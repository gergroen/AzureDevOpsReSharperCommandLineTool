
function Get-VstsInput {
    return "path";
}

if(!(Test-Path .\nuget.exe -PathType Leaf))
{
    Invoke-WebRequest "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile "nuget.exe"
}
Set-Alias -Name nuget -Value .\nuget.exe

.\AzureDevOpsReSharperCommandLineTools\ReSharperCommandLineTools.ps1