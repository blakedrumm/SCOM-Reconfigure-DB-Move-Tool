[CmdletBinding()]
param
(
	[string]$SourcePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $SourcePath)
{
	$SourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'SCOM-ReconfigureDatabaseLocations.ps1'
}

function Assert-Condition
{
	param([bool]$Condition, [string]$Message)
	if (-not $Condition)
	{
		throw $Message
	}
}

$parseTokens = $null
$parseErrors = $null
$sourceAst = [System.Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$parseTokens, [ref]$parseErrors)
$parseErrorSummary = @($parseErrors | Select-Object -First 3 | ForEach-Object { '{0} at line {1}' -f $_.ErrorId, $_.Extent.StartLineNumber }) -join '; '
Assert-Condition (@($parseErrors).Count -eq 0) "PowerShell syntax errors: $parseErrorSummary"

$modifyFunction = @($sourceAst.FindAll({
	param($node)
	$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Modify-DatabasesSCOM'
}, $true))
Assert-Condition ($modifyFunction.Count -eq 1) 'Expected one database update function.'
. ([scriptblock]::Create($modifyFunction[0].Extent.Text))

function Get-TestJobScriptBlock
{
	param([string]$JobName, [string]$ParameterName = 'JobScript', [string]$FunctionName)
	$searchAst = $sourceAst
	if ($FunctionName)
	{
		$searchAst = $sourceAst.Find({
			param($node)
			$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
		}, $true)
		Assert-Condition ($null -ne $searchAst) "Missing function $FunctionName."
	}
	$jobCommands = @($searchAst.FindAll({
		param($node)
		$node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-JobTracker' -and
		@($node.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -eq $JobName }).Count -eq 1
	}, $true))
	Assert-Condition ($jobCommands.Count -eq 1) "Expected one $JobName job."
	$commandElements = $jobCommands[0].CommandElements
	for ($elementIndex = 0; $elementIndex -lt $commandElements.Count - 1; $elementIndex++)
	{
		if ($commandElements[$elementIndex] -is [System.Management.Automation.Language.CommandParameterAst] -and $commandElements[$elementIndex].ParameterName -eq $ParameterName)
		{
			return $commandElements[$elementIndex + 1].ScriptBlock.GetScriptBlock()
		}
	}
	throw "Missing $ParameterName for $JobName."
}

$script:capturedCommands = New-Object 'System.Collections.Generic.List[object]'
function Invoke-SqlCommand
{
	param($ServerInstance, $Database, $Query, $As, [hashtable]$Parameters)
	$script:capturedCommands.Add([pscustomobject]@{
		ServerInstance = $ServerInstance
		Database = $Database
		Query = $Query
		Parameters = $Parameters
	})
}

$longInstance = 'dbsql-myscom.internal.datacenter.my_company.com\SQLSCOM'
$warehouseInstance = 'dw-' + $longInstance
$longDatabase = 'OperationsManager_' + ('d' * 100)
$updateArguments = @{
	NewOpsDBServerName = $longInstance
	NewOpsDBDatabaseName = $longDatabase
	NewDWServerName = $warehouseInstance
	NewDWDatabaseName = $longDatabase
	OldSQLInstance = '(local)'
	OldSQLDatabase = $longDatabase
}
Modify-DatabasesSCOM @updateArguments -OperationsManagerDB | Out-Null
Modify-DatabasesSCOM @updateArguments -OperationsManagerDW | Out-Null

Assert-Condition ($script:capturedCommands.Count -eq 2) 'Expected one OperationsManager and one Data Warehouse batch.'
foreach ($capturedCommand in $script:capturedCommands)
{
	Assert-Condition ($capturedCommand.Database -ceq $longDatabase) 'The database name changed before reaching the SQL helper.'
	Assert-Condition ($capturedCommand.Query -notmatch '\bn?varchar\s*\(\s*50\s*\)') 'A database update batch still has a truncating 50-character buffer.'
	Assert-Condition ($capturedCommand.Query -match 'OldValue\s+nvarchar\(max\)') 'Old audit values must preserve long Unicode names.'
	Assert-Condition ($capturedCommand.Query -match 'NewValue\s+nvarchar\(max\)') 'New audit values must preserve long Unicode names.'
	Assert-Condition ($capturedCommand.Query -match 'DECLARE\s+@sqlstmt\s+nvarchar\(max\)') 'Dynamic SQL must not be truncated by a fixed-size buffer.'
	Assert-Condition ($capturedCommand.Parameters['@NewDWServerName'] -ceq $warehouseInstance) 'The Data Warehouse instance must be passed intact as a SQL parameter.'
	Assert-Condition (-not $capturedCommand.Query.Contains($longInstance)) 'Instance values must not be interpolated into SQL text.'
}
Assert-Condition ($script:capturedCommands[0].Parameters['@NewOpsDBServerName'] -ceq $longInstance) 'OperationsManager and Data Warehouse instance parameters must remain distinct.'

$previewJobScript = Get-TestJobScriptBlock -JobName 'GetDatabaseData_Job'
& $previewJobScript $longInstance $longDatabase $longInstance $longDatabase '' | Out-Null
Assert-Condition ($script:capturedCommands.Count -eq 12) 'Expected both update batches and all ten preview queries.'
foreach ($capturedCommand in @($script:capturedCommands | Select-Object -Skip 2))
{
	Assert-Condition ($capturedCommand.Query -notmatch '\bn?varchar\s*\(\s*(50|100|1000)\s*\)') 'A database preview query still has a truncating buffer.'
	Assert-Condition (-not $capturedCommand.Query.Contains($longDatabase)) 'Preview database names must come from the connection, not SQL literals.'
}

Write-Output "PASS: Both database update batches and all ten preview queries preserve long-name buffers ($($longInstance.Length)-character instance, $($longDatabase.Length)-character database); source syntax is valid."