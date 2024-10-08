[string]$inspectCodeTarget  = Get-VstsInput -Name target
[bool]$onlyChangedFilesIfPullRequest  = Get-VstsInput -Name onlyInspectChangedFilesIfPullRequest -AsBool
[bool]$failOnMaximumErrors  = Get-VstsInput -Name failOnMaximumErrors -AsBool
[bool]$failOnMaximumWarnings  = Get-VstsInput -Name failOnMaximumWarnings -AsBool
[bool]$failOnMaximumNotes  = Get-VstsInput -Name failOnMaximumNotes -AsBool
[int]$maximumExpectedErrors = Get-VstsInput -Name maximumExpectedErrors -AsInt
[int]$maximumExpectedWarnings = Get-VstsInput -Name maximumExpectedWarnings -AsInt
[int]$maximumExpectedNotes = Get-VstsInput -Name maximumExpectedNotes -AsInt
[string]$reportPathPrefix  = Get-VstsInput -Name reportPathPrefix
$inspectCodeToolFolder = $([IO.Path]::GetFullPath("$($env:AGENT_TEMPDIRECTORY)\resharper_commandline_tools"))
$inspectCodeResultsPath  = "$($inspectCodeToolFolder)\resharper_commandline_tools_inspectcode.sarif"
$summaryFilePath  = "$($inspectCodeToolFolder)\Summary.md"
$cacheFolder = "$($inspectCodeToolFolder)\cache"
$inspectCodeCacheFolder = "$($cacheFolder)\inspect"
$dotnetToolsManifestFolder = "$($cacheFolder)\dotnet-tools"
$dotnetToolsManifestFile = "$($dotnetToolsManifestFolder)\.config\dotnet-tools.json"

Write-Output "##[section]DotNet Install Tool JetBrains.ReSharper.GlobalTools"
if(!(Test-Path $dotnetToolsManifestFile))
{
    dotnet new tool-manifest -o $dotnetToolsManifestFolder
}
dotnet tool update JetBrains.ReSharper.GlobalTools --tool-manifest $dotnetToolsManifestFile

$argumentList = @()
$argumentList += "tool run jb inspectcode"
$argumentList += $inspectCodeTarget
$argumentList += "--output=$($inspectCodeResultsPath)"
$argumentList += "--properties:Configuration=Release"
$argumentList += "--caches-home=$($inspectCodeCacheFolder)"
if($onlyChangedFilesIfPullRequest -and $env:System_PullRequest_PullRequestId) {
    Write-Output "##[section]Get list of changed files of pull request"

    # Azure DevOps REST API endpoint for pull request iterations
    $baseUrl = "$($env:System_CollectionUri)$($env:System_TeamProject)/_apis/git/repositories/$($env:Build_Repository_ID)"
    $uri = "$($baseUrl)/pullRequests/$($env:System_PullRequest_PullRequestId)/iterations?api-version=6.0"
    # Base64-encoded PAT
    Write-Output "##[debug]GetIterations:$uri"
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($env:System_AccessToken)"))
    # Invoke the REST API
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{
        Authorization = ("Basic {0}" -f $base64AuthInfo)
    }
    $iterations = $response.value
    $highestIterationId = $iterations | Sort-Object -Property id -Descending | Select-Object -First 1 | Select-Object -ExpandProperty id
    Write-Output "##[debug]HighestIterationId:$highestIterationId"

    # Azure DevOps REST API endpoint for pull request changes
    $uri = "$($baseUrl)/pullRequests/$($env:System_PullRequest_PullRequestId)/iterations/$highestIterationId/changes?api-version=6.0"
    # Base64-encoded PAT
    Write-Output "##[debug]GetIterationChanges:$uri"
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($env:System_AccessToken)"))
    # Invoke the REST API
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{
        Authorization = ("Basic {0}" -f $base64AuthInfo)
    }
    # Output the changed files
    $response.changeEntries | ForEach-Object {
        Write-Output "##[debug]ChangeEntry:$($_.item | ConvertTo-Json)"
        $changedFile = $_.item.path.TrimStart("/");
        $argumentList += "--include=$($changedFile)"
    }
}

Write-Output "##[section]Run Inspect Code"
if(!(Test-Path $inspectCodeToolFolder))
{
    New-Item -Path $inspectCodeToolFolder -ItemType Directory | Out-Null
}
Write-Output "##[debug]dotnet argumentList:$($argumentList | ConvertTo-Json)"
Start-Process -FilePath "dotnet" -WorkingDirectory $dotnetToolsManifestFolder -ArgumentList $argumentList -Wait -NoNewWindow

if(!(Test-Path $inspectCodeResultsPath))
{
    Write-Output "##vso[task.complete result=SucceededWithIssues;]No report generated"
    return
}

if($reportPathPrefix.Length -gt 0)
{
    Write-Output "##[section]Add path prefix in report"
    $sarifContent = Get-Content -Path $inspectCodeResultsPath -Raw
    $sarifObject = $sarifContent | ConvertFrom-Json
    foreach ($run in $sarifObject.runs) {
        foreach ($result in $run.results) {
            foreach ($location in $result.locations) {
                $locatino.physicalLocation.artifactLocation.uri = $reportPathPrefix + $locatino.physicalLocation.artifactLocation.uri
            }
        }
        foreach ($artifact in $run.artifacts) {
            $artifact.location.uri = $reportPathPrefix + $artifact.location.uri
        }
    }
    $modifiedSarifContent = $sarifObject | ConvertTo-Json -Depth 100
    Set-Content -Path $inspectCodeResultsPath -Value $modifiedSarifContent
}


Write-Output "##[section]Analyse Results"
$sarifContent = Get-Content -Path $inspectCodeResultsPath -Raw
$sarifObject = $sarifContent | ConvertFrom-Json
$filteredElementsReportNote = 0
$filteredElementsReportWarning = 0
$filteredElementsReportError = 0
$filteredElementsFail = [System.Collections.ArrayList]::new()
foreach ($run in $sarifObject.runs) {
    foreach ($result in $run.results) {
        if ($result.level -eq "note") {
            $filteredElementsReportNote++
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
$summaryMessage = "Code inspect found $($filteredElementsReportNote) notes, $($filteredElementsReportWarning) warnings and $($filteredElementsReportError) errors"
Write-Output $summaryMessage
Add-Content $summaryFilePath ($summaryMessage) 

Write-Output "##vso[artifact.upload containerfolder=resharper_commandline_tools_inspectcode;artifactname=resharper_commandline_tools_inspectcode]$summaryFilePath"
Write-Output "##vso[artifact.upload containerfolder=CodeAnalysisLogs;artifactname=CodeAnalysisLogs]$inspectCodeResultsPath"
Write-Output "##vso[task.addattachment type=Distributedtask.Core.Summary;name=Resharper Command Line Tools Inspect Code;]$summaryFilePath"

$buildResult = "Succeeded"
if($failOnMaximumNotes -and $filteredElementsReportNote -gt $maximumExpectedNotes) {
    $summaryMessage = "Found $($filteredElementsReportNote) notes. Maximum is $($maximumExpectedNotes) notes"
    $buildResult = "Failed"
}
if($failOnMaximumWarnings -and $filteredElementsReportWarning -gt $maximumExpectedWarnings) {
    $summaryMessage = "Found $($filteredElementsReportWarning) warnings. Maximum is $($maximumExpectedWarnings) warnings"
    $buildResult = "Failed"
}
if($failOnMaximumErrors -and $filteredElementsReportError -gt $maximumExpectedErrors) {
    $summaryMessage = "Found $($filteredElementsReportError) errors. Maximum is $($maximumExpectedErrors) errors"
    $buildResult = "Failed"
}
Write-Output ("##vso[task.complete result={0};]{1}" -f $buildResult, $summaryMessage)