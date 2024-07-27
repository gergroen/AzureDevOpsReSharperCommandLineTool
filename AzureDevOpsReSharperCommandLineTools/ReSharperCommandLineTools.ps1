[string]$inspectCodeTarget  = Get-VstsInput -Name Target
$inspectCodeToolFolder = $([IO.Path]::GetFullPath("$($env:AGENT_TEMPDIRECTORY)\resharper_commandline_tools"))
$inspectCodeResultsPath  = "$($inspectCodeToolFolder)\resharper_commandline_tools_inspectcode.sarif"
$summaryFilePath  = "$($inspectCodeToolFolder)\Summary.md"
$inspectCodeCacheFolder = "$($inspectCodeToolFolder)\cache"

Write-Output "##[section]DotNet Install Tool JetBrains.ReSharper.GlobalTools"
dotnet tool update -g JetBrains.ReSharper.GlobalTools

# Azure DevOps REST API endpoint for pull request changes
$baseUrl = "=$(System.CollectionUri)/$(System.TeamProject)/_apis/git/repositories/$(Build.Repository.ID)"
$uri = "$($baseUrl)/pullRequests/$(System.PullRequest.PullRequestId)/iterations/1/changes?api-version=6.0"

# Base64-encoded PAT
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$(System.AccessToken)"))
# Invoke the REST API
Write-Output "Invoke the REST API $($uri)"
$response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{
    Authorization = ("Basic {0}" -f $base64AuthInfo)
}
# Output the changed files
$response.changes | ForEach-Object {
    Write-Output $_.item.path
}

Write-Output "##[section]Run Inspect Code"
New-Item -Path $inspectCodeToolFolder -ItemType Directory | Out-Null

#"--include=**.cs"
& jb inspectcode $inspectCodeTarget "--output=$($inspectCodeResultsPath)" "--format=Sarif" "/disable-settings-layers:SolutionPersonal" "--no-build" "--no-swea" "--properties:Configuration=Release" "--caches-home=$($inspectCodeCacheFolder)"

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
        Write-Output ("##vso[task.logissue type={0};sourcepath={1};linenumber={2};columnnumber={3};]R# {4}" -f $issue.level, $issueLocationFile, $issueLocationLine, $issueLocationColumn, $issue.message.text)
    }
}

$null = New-Item $summaryFilePath -type file -force
$summaryMessage = "Code inspect found $($filteredElementsReportSuggestion) suggestions, $($filteredElementsReportWarning) warnings and $($filteredElementsReportError) errors"
Write-Output $summaryMessage
Add-Content $summaryFilePath ($summaryMessage) 

Write-Output "##vso[artifact.upload containerfolder=resharper_commandline_tools_inspectcode;artifactname=resharper_commandline_tools_inspectcode]$summaryFilePath"
Write-Output "##vso[artifact.upload containerfolder=CodeAnalysisLogs;artifactname=CodeAnalysisLogs]$inspectCodeResultsPath"
Write-Output "##vso[task.addattachment type=Distributedtask.Core.Summary;name=Resharper Command Line Tools Inspect Code;]$summaryFilePath"

$buildResult = "Succeeded"
if($filteredElementsFail.Count -gt 0) {
    $buildResult = "Failed"
}
Write-Output ("##vso[task.complete result={0};]{1}" -f $buildResult, $summaryMessage)