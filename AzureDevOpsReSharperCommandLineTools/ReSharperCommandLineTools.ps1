[string]$inspectCodeTarget  = Get-VstsInput -Name Target
$inspectCodeToolFolder = "resharper_commandline_tools"
$inspectCodeResultsPath  = "$($inspectCodeToolFolder)\report.sarif"
$inspectCodeResultsHtmlPath  = "$($inspectCodeToolFolder)\report.html"
$inspectCodeResultsTxtPath = "$($inspectCodeToolFolder)\report.txt"
$summaryFilePath  = "$($inspectCodeToolFolder)\Summary.md"
$inspectCodeCacheFolder = "$($inspectCodeToolFolder)\cache";

Write-Output "##[section]DotNet Install Tool JetBrains.ReSharper.GlobalTools"
dotnet tool update -g JetBrains.ReSharper.GlobalTools

Write-Output "##[section]Run Inspect Code"
mkdir -p $inspectCodeToolFolder
#"--include=**.cs"
& jb inspectcode $inspectCodeTarget "--output=$($inspectCodeToolFolder)" "--format=Html;Text;Sarif" "/disable-settings-layers:SolutionPersonal" "--no-build" "--no-swea" "--properties:Configuration=Release" "--caches-home=$($inspectCodeCacheFolder)"

Write-Output "##[section]Analyse Results"
$sarifContent = Get-Content -Path $inspectCodeResultsPath -Raw
$sarifObject = $sarifContent | ConvertFrom-Json
$filteredElementsReportSuggestion = 0
$filteredElementsReportWarning = 0
$filteredElementsReportError = 0
$filteredElementsFail = [System.Collections.ArrayList]::new()
foreach ($run in $sarifObject.runs) {
    foreach ($result in $run.results) {
        if ($result.level -eq "note") {
            $filteredElementsReportSuggestion++
        }
        if ($result.level -eq "warning") {
            $null = $filteredElementsFail.Add($result);
            $filteredElementsReportWarning++
        }
        if ($result.level -eq "error") {
            $null = $filteredElementsFail.Add($result);
            $filteredElementsReportError++
        }
    }
}

Write-Output "##[section]Report Results Output"
foreach ($issue in $filteredElementsFail | Sort-Object level -Descending) {
    foreach ($issueLocation in $issue.locations)
    {
        $issueLocationFile = $issueLocation.physicalLocation.artifactLocation.uri;
        $issueLocationLine = $issueLocation.physicalLocation.region.startLine;
        $issueLocationColumn = $issueLocation.physicalLocation.region.startColumn;
        Write-Output ("##vso[task.logissue type={0};sourcepath={1};linenumber={2};columnnumber={3}]R# {4}" -f $errorType, $issueLocationFile, $issueLocationLine, $issueLocationColumn, $issue.message.text)
    }
}

$null = New-Item $summaryFilePath -type file -force
$summaryMessage = "Code inspect found $($filteredElementsReportSuggestion) suggestions, $($filteredElementsReportWarning) warnings and $($filteredElementsReportError) errors"
Write-Output $summaryMessage
Add-Content $summaryFilePath ($summaryMessage) 

Write-Output "##vso[artifact.upload containerfolder=inspect_code;artifactname=inspect_code]$([IO.Path]::GetFullPath($summaryFilePath))"
Write-Output "##vso[artifact.upload containerfolder=inspect_code;artifactname=inspect_code]$([IO.Path]::GetFullPath($inspectCodeResultsPath))"
Write-Output "##vso[artifact.upload containerfolder=inspect_code;artifactname=inspect_code]$([IO.Path]::GetFullPath($inspectCodeResultsTxtPath))"
Write-Output "##vso[artifact.upload containerfolder=inspect_code;artifactname=inspect_code]$([IO.Path]::GetFullPath($inspectCodeResultsHtmlPath))"
Write-Output "##vso[task.addattachment type=Distributedtask.Core.Summary;name=Resharper Command Line Tools Inspect Code;]$([IO.Path]::GetFullPath($summaryFilePath))"

Remove-Item $inspectCodeToolFolder -Recurse -Force
$buildResult = "Succeeded"
if($filteredElementsFail.Count -gt 0) {
    $buildResult = "Failed"
}
Write-Output ("##vso[task.complete result={0};]{1}" -f $buildResult, $summaryMessage)