[string]$inspectCodeTarget  = Get-VstsInput -Name Target
$inspectCodeToolFolder = "resharper_commandline_tools"
$inspectCodeResultsPath  = "$($inspectCodeToolFolder)\report.xml"
$inspectCodeResultsHtmlPath  = "$($inspectCodeToolFolder)\report.html"
$summaryFilePath  = "$($inspectCodeToolFolder)\Summary.md"
$inspectCodeCacheFolder = "$($inspectCodeToolFolder)\cache";

Write-Output "Install ReSharper CommandLine Tools"
mkdir -p $inspectCodeToolFolder
& nuget install JetBrains.ReSharper.CommandLineTools -OutputDirectory $inspectCodeToolFolder

Write-Output "Run Inspect Code"
& ".\$inspectCodeToolFolder\JetBrains.ReSharper.CommandLineTools*\tools\inspectcode.exe" $inspectCodeTarget "--output=$($inspectCodeToolFolder)\" "--format=Html;Xml" "/disable-settings-layers:SolutionPersonal" "--build" "--properties:Configuration=Release" "--caches-home=$($inspectCodeCacheFolder)"

Write-Output "Analyse Results"
$severityLevels = @{"HINT" = 0; "SUGGESTION" = 1; "WARNING" = 2; "ERROR" = 3}
$severityLevelSuggestion = $severityLevels["SUGGESTION"]
$severityLevelWarning = $severityLevels["WARNING"]
$severityLevelError = $severityLevels["ERROR"]
$failBuildLevelSelector = "ERROR"
$failBuildLevelSelectorValue = $severityLevels[$failBuildLevelSelector]

$xmlContent = [xml] (Get-Content "$inspectCodeResultsPath")
$issuesTypesXpath = "/Report/IssueTypes//IssueType"
$issuesTypesElements = $xmlContent | Select-Xml $issuesTypesXpath | Select-Object -Expand Node
$issuesTypesElementsPSObject = @{}
foreach($issuesTypesElement in $issuesTypesElements) {
    $issuesTypesElementsPSObject.Add($issuesTypesElement.Attributes["Id"].Value, $issuesTypesElement.Attributes["Severity"].Value)
}

$issuesXpath = "/Report/Issues//Issue"
$issuesElements = $xmlContent | Select-Xml $issuesXpath | Select-Object -Expand Node
$issuesElementsPSObject = [System.Collections.ArrayList]::new()
foreach($issuesElement in $issuesElements) {
    $typeId = $issuesElement.Attributes["TypeId"].Value
    $severity = $issuesTypesElementsPSObject[$typeId]
    if($severity -eq "INVALID_SEVERITY") {
        $severity = $issuesElement.Attributes["Severity"].Value
    }
    $severityLevel = $severityLevels[$severity]
    $item = [PSCustomObject] @{
        TypeId = $typeId
        Severity = $severity
        SeverityLevel = $severityLevel
        Message = $issuesElement.Attributes["Message"].Value
        File = $issuesElement.Attributes["File"].Value
        Line = $issuesElement.Attributes["Line"].Value
        }
    $null = $issuesElementsPSObject.Add($item)
}

$filteredElementsFail = [System.Collections.ArrayList]::new()
$filteredElementsReportSuggestion = 0
$filteredElementsReportWarning = 0
$filteredElementsReportError = 0
foreach($issue in $issuesElementsPSObject) {
    if($issue.SeverityLevel -ge $failBuildLevelSelectorValue) {
        $item = New-Object -TypeName PSObject -Property @{
            'Severity' = $issue.Severity
            'Message' = $issue.Message
            'File' = $issue.File
            'Line' = $issue.Line
        }
        $null = $filteredElementsFail.Add($item)
    }
    if($issue.SeverityLevel -eq $severityLevelSuggestion) {
        $filteredElementsReportSuggestion++
    }
    if($issue.SeverityLevel -eq $severityLevelWarning) {
        $filteredElementsReportWarning++
    }
    if($issue.SeverityLevel -eq $severityLevelError) {
        $filteredElementsReportError++
    }
}

Write-Output "Report Results Output"
foreach ($issue in $filteredElementsFail | Sort-Object Severity -Descending) {
    $errorType = "warning"
    if($issue.Severity -eq "ERROR"){
        $errorType = "error"
    }
    Write-Output ("##vso[task.logissue type={0};sourcepath={1};linenumber={2};columnnumber=1]R# {3}" -f $errorType, $issue.File, $issue.Line, $issue.Message)
}

$null = New-Item $summaryFilePath -type file -force
$summaryMessage = "Code inspect found $($filteredElementsReportSuggestion) suggestions, $($filteredElementsReportWarning) warnings and $($filteredElementsReportError) errors"
Write-Output $summaryMessage
Add-Content $summaryFilePath ($summaryMessage)

Write-Output "##vso[artifact.upload containerfolder=inspect_code;artifactname=inspect_code]$([IO.Path]::GetFullPath($summaryFilePath))"
Write-Output "##vso[artifact.upload containerfolder=inspect_code;artifactname=inspect_code]$([IO.Path]::GetFullPath($inspectCodeResultsPath))"
Write-Output "##vso[artifact.upload containerfolder=inspect_code;artifactname=inspect_code]$([IO.Path]::GetFullPath($inspectCodeResultsHtmlPath))"
Write-Output "##vso[task.addattachment type=Distributedtask.Core.Summary;name=Resharper Command Line Tools Inspect Code;]$([IO.Path]::GetFullPath($summaryFilePath))"

Remove-Item $inspectCodeToolFolder -Recurse -Force
$buildResult = "Succeeded"
if($filteredElementsFail.Count -gt 0) {
    $buildResult = "Failed"
}
Write-Output ("##vso[task.complete result={0};]{1}" -f $buildResult, $summaryMessage)