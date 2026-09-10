[CmdletBinding()]
param
(
	[string]$SourcePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'Test-DatabaseQueries.ps1') -SourcePath $SourcePath

$script:workflowTransitions = New-Object 'System.Collections.Generic.List[string]'
$script:workflowLogs = New-Object 'System.Collections.Generic.List[object]'
$opsMgrSQLInstanceTextBox = [pscustomobject]@{ Text = 'fixture-operations' }
$opsMgrDWSQLInstanceTextBox = [pscustomobject]@{ Text = 'fixture-warehouse' }
$toolstripstatusStep = [pscustomobject]@{ Visible = $false; Text = '' }
$toolstripprogressbar1 = [pscustomobject]@{ Value = 0 }
$buttonStart = [pscustomobject]@{ Enabled = $false; BackColor = [System.Drawing.Color]::Gray }
$checkboxUpdateOperationsMana = [pscustomobject]@{ Checked = $true }
$checkboxClearSCOMCache = [pscustomobject]@{ Checked = $true }

function Write-ActivityLog
{
	param([string]$Message, [switch]$IsError)
	$script:workflowLogs.Add([pscustomobject]@{ Message = $Message; IsError = [bool]$IsError })
}

function Update-OperationsManagerDataWarehouseDatabase
{
	$script:workflowTransitions.Add('Warehouse')
}

function Update-OperationsManagerDatabaseConfiguration
{
	$script:workflowTransitions.Add('Configuration')
}

function Clear-SCOMCacheLocalManagementServers
{
	$script:workflowTransitions.Add('Cache')
}

$workflowCases = @(
	@{ FunctionName = 'Update-OperationsManagerDatabase'; WorkerName = 'Modify-DatabasesSCOM'; NextStep = 'Warehouse'; RequiresResults = $true }
	@{ FunctionName = 'Update-OperationsManagerDataWarehouseDatabase'; WorkerName = 'Modify-DatabasesSCOM'; NextStep = 'Configuration'; RequiresResults = $true }
	@{ FunctionName = 'Update-OperationsManagerDatabaseConfiguration'; WorkerName = 'Modify-DatabaseConfigurationSCOM'; NextStep = 'Cache'; RequiresResults = $false }
)

foreach ($workflowCase in $workflowCases)
{
	$workerBlock = Get-TestJobScriptBlock -JobName 'UpdateJob' -FunctionName $workflowCase.FunctionName
	$completionBlock = Get-TestJobScriptBlock -JobName 'UpdateJob' -FunctionName $workflowCase.FunctionName -ParameterName 'CompletedScript'
	foreach ($workerOutcome in @('Failure', 'Success', 'Empty', 'CompletedWithError'))
	{
		$workerBody = switch ($workerOutcome)
		{
			'Failure' { "Write-Error 'SCOM fixture SQL failure'" }
			'Success' { "Write-Output 'SCOM fixture audit result'" }
			'Empty' { '' }
			'CompletedWithError' { "Write-Error 'SCOM fixture SQL failure' -ErrorAction Continue; Write-Output 'SCOM fixture partial result'" }
		}
		$workerDefinition = 'function ' + $workflowCase.WorkerName + ' { ' + $workerBody + ' }'
		$fixtureJob = Start-Job -ScriptBlock $workerBlock -ArgumentList '', '', $workerDefinition, 'fixture-server', 'fixture-database', 'new-server', 'new-database', 'new-warehouse', 'new-warehouse-database'
		try
		{
			$finishedJob = Wait-Job -Job $fixtureJob -Timeout 30
			Assert-Condition ($null -ne $finishedJob) 'The isolated workflow job did not finish.'
			if ($workerOutcome -eq 'Failure')
			{
				Assert-Condition ($fixtureJob.State -eq 'Failed') "$($workflowCase.FunctionName) reported success after a worker error."
			}
			$script:workflowTransitions.Clear()
			$script:workflowLogs.Clear()
			$buttonStart.Enabled = $false
			& $completionBlock $fixtureJob
			$shouldAdvance = $workerOutcome -eq 'Success' -or ($workerOutcome -eq 'Empty' -and -not $workflowCase.RequiresResults)
			if ($shouldAdvance)
			{
				Assert-Condition ($script:workflowTransitions.Count -eq 1 -and $script:workflowTransitions[0] -eq $workflowCase.NextStep) "The successful $($workflowCase.FunctionName) workflow did not retain its next step."
			}
			else
			{
				Assert-Condition ($script:workflowTransitions.Count -eq 0) "$($workflowCase.FunctionName) advanced after $workerOutcome."
				Assert-Condition $buttonStart.Enabled 'The Start button was not re-enabled after a failed database step.'
				Assert-Condition (@($script:workflowLogs | Where-Object { $_.IsError }).Count -gt 0) 'The failed database step was not logged as an error.'
			}
		}
		finally
		{
			if ($fixtureJob.State -eq 'Running') { Stop-Job -Job $fixtureJob }
			Remove-Job -Job $fixtureJob -Force
		}
	}
	$script:workflowTransitions.Clear()
	$buttonStart.Enabled = $false
	& $completionBlock $null
	Assert-Condition ($script:workflowTransitions.Count -eq 0 -and $buttonStart.Enabled) 'A job-start failure did not stop the database workflow.'
}

Write-Output 'PASS: All three database job handlers stop on worker errors, completed jobs with errors, missing jobs and missing required results; successful next steps are preserved.'