[string]$inspectCodeTarget  = Get-VstsInput -Name Target
[string]$onlyChangedFilesIfPullRequest  = Get-VstsInput -Name OnlyInspectChangedFilesIfPullRequest
$inspectCodeToolFolder = $([IO.Path]::GetFullPath("$($env:AGENT_TEMPDIRECTORY)\resharper_commandline_tools"))
$inspectCodeResultsPath  = "$($inspectCodeToolFolder)\resharper_commandline_tools_inspectcode.sarif"
$summaryFilePath  = "$($inspectCodeToolFolder)\Summary.md"
$cacheFolder = "$($inspectCodeToolFolder)\cache"
$inspectCodeCacheFolder = "$($cacheFolder)\inspect"
$dotnetToolsMManifestFile = "$($cacheFolder )\dotnet-tools\dotnet-tools.json"

Write-Output "##[section]DotNet Install Tool JetBrains.ReSharper.GlobalTools"
dotnet tool install JetBrains.ReSharper.GlobalTools --create-manifest-if-needed --tool-manifest $dotnetToolsMManifestFile

$include = "";
if($onlyChangedFilesIfPullRequest -and $env:System_PullRequest_PullRequestId) {
    Write-Output "##[section]Get list of changed files of pull request"
    # Azure DevOps REST API endpoint for pull request changes
    $baseUrl = "$($env:System_CollectionUri)$($env:System_TeamProject)/_apis/git/repositories/$($env:Build_Repository_ID)"
    $uri = "$($baseUrl)/pullRequests/$($env:System_PullRequest_PullRequestId)/iterations/1/changes?api-version=6.0"
    # Base64-encoded PAT
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($env:System_AccessToken)"))
    # Invoke the REST API
    $response = Invoke-RestMethod -Uri $uri -Method Get -Headers @{
        Authorization = ("Basic {0}" -f $base64AuthInfo)
    }
    # Output the changed files
    $include = "--include="
    $response.changeEntries | ForEach-Object {
        $changedFile = $_.item.path.TrimStart("/");
        $include ="$($include)$($changedFile);"
    }
}

Write-Output "##[section]Run Inspect Code"
New-Item -Path $inspectCodeToolFolder -ItemType Directory | Out-Null

& "$($dotnetToolsFolder)\jb" inspectcode $inspectCodeTarget "--output=$($inspectCodeResultsPath)" "--properties:Configuration=Release" "--caches-home=$($inspectCodeCacheFolder)" "$($include)"

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
# if($filteredElementsFail.Count -gt 0) {
#     $buildResult = "Failed"
# }
Write-Output ("##vso[task.complete result={0};]{1}" -f $buildResult, $summaryMessage)