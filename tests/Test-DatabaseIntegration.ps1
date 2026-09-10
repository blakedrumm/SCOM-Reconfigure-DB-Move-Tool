[CmdletBinding()]
param
(
	[string]$SourcePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data
. (Join-Path $PSScriptRoot 'Test-DatabaseQueries.ps1') -SourcePath $SourcePath

$localDbCommand = Get-Command SqlLocalDB.exe -ErrorAction Stop
$fixtureId = [guid]::NewGuid().ToString('N')
$fixtureInstance = 'SCOMDBMoveTest_' + $fixtureId.Substring(0, 12)
$fixtureServer = '(localdb)\' + $fixtureInstance
$fixtureDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('SCOMDBMoveTest_' + $fixtureId)
$fixtureDatabase = ('SCOM_DBMove_' + ('d' * 100) + "]';_" + [char]0x6570 + [char]0x636E).PadRight(128, 'x')
$instanceCreated = $false
$databaseCreated = $false

$sqlHelperAst = $sourceAst.Find({
	param($node)
	$node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-SqlCommand'
}, $true)
Assert-Condition ($null -ne $sqlHelperAst) 'The production SQL helper was not found.'
. ([scriptblock]::Create($sqlHelperAst.Extent.Text))
$script:fixtureSqlErrors = New-Object 'System.Collections.Generic.List[string]'

function Write-ActivityLog
{
	param([string]$Message, [switch]$IsError)
	if ($IsError) { $script:fixtureSqlErrors.Add($Message) }
}

function ConvertTo-FixtureIdentifier
{
	param([string]$Name)
	$identifierBuilder = New-Object System.Data.SqlClient.SqlCommandBuilder
	try { $identifierBuilder.QuoteIdentifier($Name) }
	finally { $identifierBuilder.Dispose() }
}

function New-FixtureConnection
{
	param([string]$Database = 'master')
	$connectionBuilder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
	$connectionBuilder['Data Source'] = $fixtureServer
	$connectionBuilder['Initial Catalog'] = $Database
	$connectionBuilder['Integrated Security'] = $true
	$connectionBuilder['Pooling'] = $false
	$connectionBuilder['Connect Timeout'] = 15
	$fixtureConnection = New-Object System.Data.SqlClient.SqlConnection $connectionBuilder.ConnectionString
	$fixtureConnection.Open()
	return $fixtureConnection
}

function Invoke-FixtureSql
{
	param([string]$Query, [string]$Database = 'master', [hashtable]$Parameters = @{})
	$fixtureConnection = New-FixtureConnection -Database $Database
	$fixtureCommand = $fixtureConnection.CreateCommand()
	$fixtureAdapter = New-Object System.Data.SqlClient.SqlDataAdapter $fixtureCommand
	$fixtureTable = New-Object System.Data.DataTable
	try
	{
		$fixtureCommand.CommandText = $Query
		foreach ($parameterName in $Parameters.Keys)
		{
			[void]$fixtureCommand.Parameters.AddWithValue($parameterName, $Parameters[$parameterName])
		}
		[void]$fixtureAdapter.Fill($fixtureTable)
		$fixtureTable.Rows
	}
	finally
	{
		$fixtureAdapter.Dispose()
		$fixtureCommand.Dispose()
		$fixtureConnection.Dispose()
	}
}

$fixtureTables = @(
	@{ TableName = 'MT_Microsoft$SystemCenter$ManagementGroup'; Prefix = 'SQLServerName_'; Target = 'Operations' }
	@{ TableName = 'MT_Microsoft$SystemCenter$OpsMgrDB$AppMonitoring'; Prefix = 'MainDatabaseServerName_'; Target = 'Operations' }
	@{ TableName = 'MT_Microsoft$SystemCenter$OpsMgrDB$AppMonitoring_Log'; Prefix = 'Post_MainDatabaseServerName_'; Target = 'Operations' }
	@{ TableName = 'MT_Microsoft$SystemCenter$DataWarehouse'; Prefix = 'MainDatabaseServerName_'; Target = 'Warehouse' }
	@{ TableName = 'MT_Microsoft$SystemCenter$DataWarehouse$AppMonitoring'; Prefix = 'MainDatabaseServerName_'; Target = 'Warehouse' }
	@{ TableName = 'MT_Microsoft$SystemCenter$DataWarehouse$AppMonitoring_Log'; Prefix = 'Post_MainDatabaseServerName_'; Target = 'Warehouse' }
	@{ TableName = 'MT_Microsoft$SystemCenter$DataWarehouse_Log'; Prefix = 'Post_MainDatabaseServerName_'; Target = 'Warehouse' }
	@{ TableName = 'MT_Microsoft$SystemCenter$OpsMgrDWWatcher'; Prefix = 'DatabaseServerName_'; Target = 'Warehouse' }
	@{ TableName = 'MT_Microsoft$SystemCenter$OpsMgrDWWatcher_Log'; Prefix = 'Post_DatabaseServerName_'; Target = 'Warehouse' }
)
foreach ($fixtureTable in $fixtureTables)
{
	$fixtureTable.ColumnName = ($fixtureTable.Prefix + "]'_" + ('c' * 128)).Substring(0, 128)
	$fixtureTable.QuotedTable = '[dbo].' + (ConvertTo-FixtureIdentifier $fixtureTable.TableName)
	$fixtureTable.QuotedColumn = ConvertTo-FixtureIdentifier $fixtureTable.ColumnName
}
$oldFirstValue = 'old-' + [char]0x6570 + "'" + ('a' * 140)
$oldSecondValue = 'old-' + [char]0x636E + "'" + ('b' * 140)

function Reset-FixtureValues
{
	foreach ($fixtureTable in $fixtureTables)
	{
		Invoke-FixtureSql -Database $fixtureDatabase -Query "DELETE FROM $($fixtureTable.QuotedTable); INSERT INTO $($fixtureTable.QuotedTable) ($($fixtureTable.QuotedColumn)) VALUES (@FirstValue), (@SecondValue);" -Parameters @{
			'@FirstValue' = $oldFirstValue
			'@SecondValue' = $oldSecondValue
		} | Out-Null
	}
	Invoke-FixtureSql -Database $fixtureDatabase -Query 'UPDATE dbo.GlobalSettings SET SettingValue = @OldValue; UPDATE dbo.MemberDatabase SET ServerName = @OldValue;' -Parameters @{ '@OldValue' = $oldFirstValue } | Out-Null
}

function Assert-FixtureUnchanged
{
	foreach ($fixtureTable in $fixtureTables)
	{
		$storedRows = @(Invoke-FixtureSql -Database $fixtureDatabase -Query "SELECT $($fixtureTable.QuotedColumn) AS Value FROM $($fixtureTable.QuotedTable) ORDER BY RowId;")
		Assert-Condition ($storedRows.Count -eq 2 -and $storedRows[0].Value -ceq $oldFirstValue -and $storedRows[1].Value -ceq $oldSecondValue) "Rollback did not preserve $($fixtureTable.TableName)."
	}
}

try
{
	& $localDbCommand.Source create $fixtureInstance -s | Write-Verbose
	if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated LocalDB instance.' }
	$instanceCreated = $true
	[void](New-Item -ItemType Directory -Path $fixtureDirectory)
	$quotedDatabase = ConvertTo-FixtureIdentifier $fixtureDatabase
	$dataPath = (Join-Path $fixtureDirectory 'Data.mdf').Replace("'", "''")
	$logPath = (Join-Path $fixtureDirectory 'Log.ldf').Replace("'", "''")
	Invoke-FixtureSql -Query "CREATE DATABASE $quotedDatabase ON PRIMARY (NAME = N'ScomTestData', FILENAME = N'$dataPath') LOG ON (NAME = N'ScomTestLog', FILENAME = N'$logPath');" | Out-Null
	$databaseCreated = $true

	foreach ($fixtureTable in $fixtureTables)
	{
		Invoke-FixtureSql -Database $fixtureDatabase -Query "CREATE TABLE $($fixtureTable.QuotedTable) (RowId int IDENTITY PRIMARY KEY, $($fixtureTable.QuotedColumn) nvarchar(256) NOT NULL);" | Out-Null
	}
	Invoke-FixtureSql -Database $fixtureDatabase -Query @'
CREATE TABLE dbo.ManagedTypeProperty (ManagedTypePropertyId uniqueidentifier PRIMARY KEY, ManagedTypePropertyName nvarchar(256));
CREATE TABLE dbo.GlobalSettings (ManagedTypePropertyId uniqueidentifier, SettingValue nvarchar(max));
INSERT INTO dbo.ManagedTypeProperty VALUES ('00000000-0000-0000-0000-000000000001', N'MainDatabaseServerName');
INSERT INTO dbo.GlobalSettings VALUES ('00000000-0000-0000-0000-000000000001', N'old');
CREATE TABLE dbo.MemberDatabase (ServerName nvarchar(256));
INSERT INTO dbo.MemberDatabase VALUES (N'old');
'@ | Out-Null
	Invoke-FixtureSql -Database $fixtureDatabase -Query 'CREATE SCHEMA Shadow;' | Out-Null
	Invoke-FixtureSql -Database $fixtureDatabase -Query 'CREATE TABLE Shadow.[MT_Microsoft$SystemCenter$ManagementGroup] (SQLServerName_Shadow nvarchar(256));' | Out-Null

	$operationsBatch = $script:capturedCommands[0].Query
	$warehouseBatch = $script:capturedCommands[1].Query
	$aliasCases = @(
		('a' * 49)
		('b' * 50)
		('c' * 51)
		$longInstance
		('d' * 256)
		("sql-'" + [char]0x6570 + [char]0x636E + '; --.internal\INSTANCE')
	)
	foreach ($aliasValue in $aliasCases)
	{
		Reset-FixtureValues
		$warehouseValue = 'DW-' + $aliasValue
		if ($warehouseValue.Length -gt 256) { $warehouseValue = $aliasValue }
		$updateParameters = @{ '@NewOpsDBServerName' = $aliasValue; '@NewDWServerName' = $warehouseValue }
		$operationsRows = @(Invoke-SqlCommand -ServerInstance $fixtureServer -Database $fixtureDatabase -Query $operationsBatch -Parameters $updateParameters -As DataRow -ErrorAction Stop)
		$warehouseRows = @(Invoke-SqlCommand -ServerInstance $fixtureServer -Database $fixtureDatabase -Query $warehouseBatch -Parameters @{ '@NewDWServerName' = $warehouseValue } -As DataRow -ErrorAction Stop)
		Assert-Condition ($operationsRows.Count -eq 10) 'Expected all ten OperationsManager audit rows.'
		Assert-Condition ($warehouseRows.Count -eq 1) 'Expected one Data Warehouse audit row.'
		foreach ($fixtureTable in $fixtureTables)
		{
			$expectedValue = $warehouseValue
			if ($fixtureTable.Target -eq 'Operations') { $expectedValue = $aliasValue }
			$auditRows = @($operationsRows | Where-Object { $_.TableName -ceq $fixtureTable.TableName })
			Assert-Condition ($auditRows.Count -eq 1 -and $auditRows[0].NewValue -ceq $expectedValue) "Audit truncated or changed $($fixtureTable.TableName)."
			Assert-Condition ($auditRows[0].OldValue -ceq $oldFirstValue -or $auditRows[0].OldValue -ceq $oldSecondValue) 'The original Unicode audit value was changed.'
			$storedRows = @(Invoke-FixtureSql -Database $fixtureDatabase -Query "SELECT $($fixtureTable.QuotedColumn) AS Value FROM $($fixtureTable.QuotedTable);")
			Assert-Condition (@($storedRows | Where-Object { $_.Value -ceq $expectedValue }).Count -eq 1) 'The existing TOP(1) update scope changed or storage lost characters.'
			$unchangedValue = $oldSecondValue
			if ($auditRows[0].OldValue -ceq $oldSecondValue) { $unchangedValue = $oldFirstValue }
			Assert-Condition (@($storedRows | Where-Object { $_.Value -ceq $unchangedValue }).Count -eq 1) 'Audit values did not describe the row actually updated.'
		}
		Assert-Condition ($warehouseRows[0].OldValue -ceq $oldFirstValue -and $warehouseRows[0].NewValue -ceq $warehouseValue) 'Data Warehouse audit values did not round-trip.'
		$globalRows = @($operationsRows | Where-Object { $_.TableName -eq 'GlobalSettings' })
		Assert-Condition ($globalRows.Count -eq 1 -and $globalRows[0].NewValue -ceq $warehouseValue) 'GlobalSettings did not preserve the Data Warehouse value.'
	}
	Write-Output 'PASS: SQL updates and matching audit rows round-trip 49/50/51/55/256-character aliases, quotes and Unicode using 128-character database and column identifiers.'

	Reset-FixtureValues
	$functionArguments = @{
		OldSQLInstance = $fixtureServer
		OldSQLDatabase = $fixtureDatabase
		NewOpsDBServerName = $longInstance
		NewOpsDBDatabaseName = $fixtureDatabase
		NewDWServerName = $warehouseInstance
		NewDWDatabaseName = $fixtureDatabase
	}
	$operationsOutput = Modify-DatabasesSCOM @functionArguments -OperationsManagerDB
	$warehouseOutput = Modify-DatabasesSCOM @functionArguments -OperationsManagerDW
	Assert-Condition ($operationsOutput.Contains($longInstance) -and $operationsOutput.Contains($warehouseInstance) -and $warehouseOutput.Contains($warehouseInstance)) 'The complete update function did not preserve instance names in its formatted audit output.'
	Write-Output 'PASS: Both complete update-function paths preserve distinct instance parameters and formatted audit output.'

	Reset-FixtureValues
	$mutationBatch = $operationsBatch.Replace('DECLARE @OpsMgrSQLInstance nvarchar(max)', 'DECLARE @OpsMgrSQLInstance nvarchar(50)')
	Assert-Condition ($mutationBatch -cne $operationsBatch) 'The truncation negative control did not alter the batch.'
	$mutationRows = @(Invoke-FixtureSql -Database $fixtureDatabase -Query $mutationBatch -Parameters @{ '@NewOpsDBServerName' = $longInstance; '@NewDWServerName' = $longInstance })
	$mutationValue = @($mutationRows | Where-Object { $_.TableName -eq $fixtureTables[0].TableName })[0].NewValue
	Assert-Condition ($mutationValue -ceq $longInstance.Substring(0, 50)) 'The nvarchar(50) negative control did not reproduce truncation.'
	Write-Output 'PASS: Restoring nvarchar(50) in an isolated SQL copy reproduces the truncation; the unmodified batch passes.'

	Reset-FixtureValues
	$oversizeRejected = $false
	try
	{
		Invoke-SqlCommand -ServerInstance $fixtureServer -Database $fixtureDatabase -Query $operationsBatch -Parameters @{ '@NewOpsDBServerName' = $longInstance; '@NewDWServerName' = ('z' * 257) } -As DataRow -ErrorAction Stop | Out-Null
	}
	catch
	{
		if ($_.Exception.ToString() -notmatch 'truncat') { throw }
		$oversizeRejected = $true
	}
	Assert-Condition $oversizeRejected 'An oversized value must fail, not truncate silently.'
	Assert-FixtureUnchanged
	Write-Output 'PASS: A destination-column overflow is reported and all preceding updates in that database are rolled back.'

	$missingColumnTable = $fixtureTables[$fixtureTables.Count - 1]
	Invoke-FixtureSql -Database $fixtureDatabase -Query "ALTER TABLE $($missingColumnTable.QuotedTable) ADD FixtureBackup nvarchar(256);" | Out-Null
	Invoke-FixtureSql -Database $fixtureDatabase -Query "UPDATE $($missingColumnTable.QuotedTable) SET FixtureBackup = $($missingColumnTable.QuotedColumn);" | Out-Null
	Invoke-FixtureSql -Database $fixtureDatabase -Query "ALTER TABLE $($missingColumnTable.QuotedTable) DROP COLUMN $($missingColumnTable.QuotedColumn);" | Out-Null
	$missingColumnRejected = $false
	try
	{
		Invoke-SqlCommand -ServerInstance $fixtureServer -Database $fixtureDatabase -Query $operationsBatch -Parameters @{ '@NewOpsDBServerName' = $longInstance; '@NewDWServerName' = $warehouseInstance } -As DataRow -ErrorAction Stop | Out-Null
	}
	catch
	{
		if ($_.Exception.ToString() -notmatch 'required SCOM server-name column') { throw }
		$missingColumnRejected = $true
	}
	finally
	{
		Invoke-FixtureSql -Database $fixtureDatabase -Query "ALTER TABLE $($missingColumnTable.QuotedTable) ADD $($missingColumnTable.QuotedColumn) nvarchar(256);" | Out-Null
		Invoke-FixtureSql -Database $fixtureDatabase -Query "UPDATE $($missingColumnTable.QuotedTable) SET $($missingColumnTable.QuotedColumn) = FixtureBackup; ALTER TABLE $($missingColumnTable.QuotedTable) DROP COLUMN FixtureBackup;" | Out-Null
	}
	Assert-Condition $missingColumnRejected 'A missing required column was silently skipped.'
	Assert-FixtureUnchanged
	Write-Output 'PASS: A missing required column fails explicitly and rolls back earlier updates.'

	$previewValue = 'preview-' + [char]0x6570 + [char]0x636E + "'; --" + ('p' * 150)
	foreach ($fixtureTable in $fixtureTables)
	{
		Invoke-FixtureSql -Database $fixtureDatabase -Query "UPDATE $($fixtureTable.QuotedTable) SET $($fixtureTable.QuotedColumn) = @Value;" -Parameters @{ '@Value' = $previewValue } | Out-Null
	}
	Invoke-FixtureSql -Database $fixtureDatabase -Query 'UPDATE dbo.GlobalSettings SET SettingValue = @Value; UPDATE dbo.MemberDatabase SET ServerName = @Value;' -Parameters @{ '@Value' = $previewValue } | Out-Null
	$previewRows = @(& $previewJobScript $fixtureServer $fixtureDatabase $fixtureServer $fixtureDatabase '')
	Assert-Condition ($previewRows.Count -eq 10) 'The actual preview job must return ten entries.'
	foreach ($previewRow in $previewRows)
	{
		Assert-Condition ($previewRow.Value -ceq $previewValue) 'A preview value was truncated, changed, or reported unavailable.'
	}
	Write-Output 'PASS: All ten actual preview queries preserve long Unicode values with embedded quotes.'

	Invoke-FixtureSql -Database $fixtureDatabase -Query 'UPDATE dbo.GlobalSettings SET SettingValue = NULL; UPDATE dbo.MemberDatabase SET ServerName = NULL;' | Out-Null
	$nullPreviewRows = @(& $previewJobScript $fixtureServer $fixtureDatabase $fixtureServer $fixtureDatabase '')
	Assert-Condition ($nullPreviewRows.Count -eq 10 -and $nullPreviewRows[0].Value -is [DBNull] -and $nullPreviewRows[9].Value -is [DBNull]) 'NULL preview values must not corrupt the result positions.'

	$ownedConnectionErrorCaught = $false
	try
	{
		Invoke-SqlCommand -ServerInstance $fixtureServer -Database $fixtureDatabase -Query "THROW 51000, 'SCOM owned-connection failure', 1;" -Verbose -ErrorAction Stop | Out-Null
	}
	catch
	{
		if ($_.Exception.ToString() -notmatch 'SCOM owned-connection failure') { throw }
		$ownedConnectionErrorCaught = $true
	}
	Assert-Condition $ownedConnectionErrorCaught 'Verbose logging converted an owned-connection SQL error into an informational message.'

	$callerConnection = New-FixtureConnection -Database $fixtureDatabase
	try
	{
		foreach ($resultShape in @('Scalar', 'NonQuery', 'DataSet', 'DataTable', 'DataRow', 'PSCustomObject'))
		{
			Invoke-SqlCommand -ServerInstance $fixtureServer -Database $fixtureDatabase -Connection $callerConnection -Query 'SELECT @Value AS Value;' -Parameters @{ '@Value' = $previewValue } -As $resultShape -ErrorAction Stop | Out-Null
			Assert-Condition ($callerConnection.State -eq 'Open') "The caller connection was closed for $resultShape."
		}
		$expectedErrorCaught = $false
		try
		{
			Invoke-SqlCommand -ServerInstance $fixtureServer -Database $fixtureDatabase -Connection $callerConnection -Query "THROW 51000, 'SCOM fixture failure', 1;" -Verbose -ErrorAction Stop | Out-Null
		}
		catch
		{
			if ($_.Exception.ToString() -notmatch 'SCOM fixture failure') { throw }
			$expectedErrorCaught = $true
		}
		Assert-Condition $expectedErrorCaught 'SQL failures must remain terminating errors with verbose logging enabled.'
		Assert-Condition ($callerConnection.State -eq 'Open') 'A failed query disposed the caller connection.'
		$scalarResult = Invoke-SqlCommand -ServerInstance $fixtureServer -Database $fixtureDatabase -Connection $callerConnection -Query 'SELECT 1;' -As Scalar -ErrorAction Stop
		Assert-Condition ($scalarResult -eq 1) 'The caller connection could not be reused after an error.'
	}
	finally
	{
		$callerConnection.Dispose()
	}
	Write-Output 'PASS: SQL failures propagate and caller-owned connections remain usable for every output mode and after failure.'
}
finally
{
	if ($databaseCreated)
	{
		Invoke-FixtureSql -Query "ALTER DATABASE $quotedDatabase SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE $quotedDatabase;" | Out-Null
	}
	if ($instanceCreated)
	{
		& $localDbCommand.Source stop $fixtureInstance -k | Write-Verbose
		if ($LASTEXITCODE -ne 0) { throw "Could not stop owned test instance $fixtureInstance." }
		& $localDbCommand.Source delete $fixtureInstance | Write-Verbose
		if ($LASTEXITCODE -ne 0) { throw "Could not delete owned test instance $fixtureInstance." }
	}
	if (Test-Path -LiteralPath $fixtureDirectory)
	{
		Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
	}
}