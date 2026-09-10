[CmdletBinding()]
param
(
	[Parameter(Mandatory = $true)]
	[string]$Version,
	[Parameter(Mandatory = $true)]
	[string]$AssetDirectory,
	[Parameter(Mandatory = $true)]
	[string]$ReferenceDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not ('ScomReleaseInspection' -as [type]))
{
	Add-Type -Path (Join-Path $PSScriptRoot 'ReleaseInspection.cs')
}

function Assert-Release
{
	param([bool]$Condition, [string]$Message)
	if (-not $Condition) { throw $Message }
}

function Get-ByteHash
{
	param([byte[]]$Bytes)
	$algorithm = [System.Security.Cryptography.SHA256]::Create()
	try { [System.BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-', '') }
	finally { $algorithm.Dispose() }
}

function Assert-ArtifactChecksum
{
	param([string]$ArtifactPath)
	$checksum = [System.IO.File]::ReadAllText($ArtifactPath + '.md5')
	Assert-Release ($checksum -cmatch '^[0-9a-f]{32}$' -and $checksum.Length -eq 32) "Invalid legacy checksum format: $ArtifactPath"
	Assert-Release ($checksum -ceq (Get-FileHash -LiteralPath $ArtifactPath -Algorithm MD5).Hash.ToLowerInvariant()) "Checksum mismatch: $ArtifactPath"
}

function Get-InstallerSnapshot
{
	param([string]$Path)
	$columnsByTable = [ordered]@{
		Property = @('Property', 'Value')
		Upgrade = @('UpgradeCode', 'VersionMin', 'VersionMax', 'Language', 'Attributes', 'Remove', 'ActionProperty')
		File = @('File', 'Component_', 'FileName', 'FileSize', 'Version', 'Language', 'Attributes', 'Sequence')
		Directory = @('Directory', 'Directory_Parent', 'DefaultDir')
		Component = @('Component', 'Directory_', 'Attributes', 'Condition', 'KeyPath')
		Shortcut = @('Shortcut', 'Directory_', 'Name', 'Component_', 'Target', 'Arguments', 'Description', 'Hotkey', 'Icon_', 'IconIndex', 'ShowCmd', 'WkDir')
		Registry = @('Registry', 'Root', 'Key', 'Name', 'Value', 'Component_')
		LaunchCondition = @('Condition', 'Description')
		InstallExecuteSequence = @('Action', 'Condition', 'Sequence')
	}
	$installer = New-Object -ComObject WindowsInstaller.Installer
	$database = $null
	try
	{
		$database = $installer.OpenDatabase($Path, 0)
		$snapshot = @{}
		foreach ($tableName in $columnsByTable.Keys)
		{
			$columnNames = $columnsByTable[$tableName]
			$quotedColumns = ($columnNames | ForEach-Object { '`' + $_ + '`' }) -join ', '
			$view = $database.OpenView('SELECT ' + $quotedColumns + ' FROM `' + $tableName + '`')
			try
			{
				[void]$view.Execute()
				$tableRows = New-Object 'System.Collections.Generic.List[object]'
				while ($null -ne ($record = $view.Fetch()))
				{
					try
					{
						$row = [ordered]@{}
						for ($fieldIndex = 0; $fieldIndex -lt $columnNames.Count; $fieldIndex++)
						{
							$row[$columnNames[$fieldIndex]] = $record.StringData($fieldIndex + 1)
						}
						$tableRows.Add([pscustomobject]$row)
					}
					finally { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
				}
				$snapshot[$tableName] = @($tableRows.ToArray() | Sort-Object -Property $columnNames[0])
			}
			finally
			{
				[void]$view.Close()
				[void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
			}
		}
		$summary = $database.SummaryInformation(0)
		try
		{
			$snapshot.Template = $summary.Property(7)
			$snapshot.PackageCode = $summary.Property(9)
		}
		finally { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
		$snapshot.Properties = @{}
		foreach ($propertyRow in $snapshot.Property) { $snapshot.Properties[$propertyRow.Property] = $propertyRow.Value }
		return $snapshot
	}
	finally
	{
		if ($database) { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
		[void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
	}
}

$expectedAssets = @(
	'SCOM-Reconfigure-DB-Move-Tool-EXE-32bit+64bit.zip'
	'SCOM-Reconfigure-DB-Move-Tool-EXE.zip'
	'SCOM-Reconfigure-DB-Move-Tool-MSI.zip'
	'SCOM-Reconfigure-DB-Move-Tool.ps1'
) | Sort-Object
$actualAssets = @(Get-ChildItem -LiteralPath $AssetDirectory -File | Select-Object -ExpandProperty Name | Sort-Object)
Assert-Release (($expectedAssets -join '|') -ceq ($actualAssets -join '|')) 'The release must contain exactly the four original asset names.'
$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'SCOM-ReconfigureDatabaseLocations.ps1'
$releaseSource = Join-Path $AssetDirectory 'SCOM-Reconfigure-DB-Move-Tool.ps1'
Assert-Release ((Get-FileHash -LiteralPath $sourcePath).Hash -ceq (Get-FileHash -LiteralPath $releaseSource).Hash) 'The source asset differs from the repository source.'
& (Join-Path $PSScriptRoot 'Test-DatabaseQueries.ps1') -SourcePath $releaseSource

$verificationDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('SCOM-Release-Verify-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $verificationDirectory)
try
{
	foreach ($assetName in $expectedAssets | Where-Object { $_.EndsWith('.zip') })
	{
		$currentZip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $AssetDirectory $assetName))
		$previousZip = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $ReferenceDirectory $assetName))
		try
		{
			$currentEntries = @($currentZip.Entries | Select-Object -ExpandProperty FullName | Sort-Object)
			$previousEntries = @($previousZip.Entries | Select-Object -ExpandProperty FullName | Sort-Object)
			Assert-Release (($currentEntries -join '|') -ceq ($previousEntries -join '|')) "Archive paths differ from the prior release: $assetName"
			foreach ($entryName in $currentEntries)
			{
				Assert-Release ($entryName -notmatch '(^[\\/]|:|(^|[\\/])\.\.([\\/]|$))') 'An archive contains an unsafe extraction path.'
			}
		}
		finally { $currentZip.Dispose(); $previousZip.Dispose() }
		[System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $AssetDirectory $assetName), (Join-Path $verificationDirectory ('current-' + $assetName)))
		[System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $ReferenceDirectory $assetName), (Join-Path $verificationDirectory ('previous-' + $assetName)))
	}
	Write-Output 'PASS: All four asset names and every ZIP entry exactly match the prior release; the source asset matches the repository.'

	$combinedName = 'SCOM-Reconfigure-DB-Move-Tool-EXE-32bit+64bit.zip'
	foreach ($architecture in @('x86', 'x64'))
	{
		$relativeExecutable = "$architecture\SCOM-ReconfigureDatabaseLocations.exe"
		$currentExecutable = Join-Path (Join-Path $verificationDirectory ('current-' + $combinedName)) $relativeExecutable
		$previousExecutable = Join-Path (Join-Path $verificationDirectory ('previous-' + $combinedName)) $relativeExecutable
		$currentVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($currentExecutable)
		$previousVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($previousExecutable)
		Assert-Release ($currentVersion.FileVersion -ceq $Version -and $currentVersion.ProductVersion -ceq $Version) "Incorrect $architecture executable version."
		foreach ($metadataName in @('ProductName', 'CompanyName', 'FileDescription', 'OriginalFilename', 'LegalCopyright'))
		{
			Assert-Release ($currentVersion.$metadataName -ceq $previousVersion.$metadataName) "Executable metadata changed: $metadataName"
		}
		$executableBytes = [System.IO.File]::ReadAllBytes($currentExecutable)
		$peOffset = [System.BitConverter]::ToInt32($executableBytes, 0x3c)
		$expectedMachine = 0x8664
		if ($architecture -eq 'x86') { $expectedMachine = 0x14c }
		Assert-Release ([System.BitConverter]::ToUInt16($executableBytes, $peOffset + 4) -eq $expectedMachine) "Incorrect $architecture PE architecture."
		Assert-ArtifactChecksum $currentExecutable
		Assert-Release ((Get-FileHash -LiteralPath ($currentExecutable + '.config')).Hash -ceq (Get-FileHash -LiteralPath ($previousExecutable + '.config')).Hash) 'The runtime configuration differs from the prior release.'
		Assert-Release ((Get-AuthenticodeSignature -LiteralPath $currentExecutable).Status -eq 'NotSigned') 'The signing state differs from the prior unsigned release.'
		foreach ($resourceType in @(3, 14, 24))
		{
			$currentResources = [ScomReleaseInspection]::ReadResources($currentExecutable, $resourceType)
			$previousResources = [ScomReleaseInspection]::ReadResources($previousExecutable, $resourceType)
			Assert-Release ($currentResources.Count -eq $previousResources.Count) "Icon or manifest resource counts changed for $architecture."
			foreach ($resourceName in $previousResources.Keys)
			{
				Assert-Release ($currentResources.ContainsKey($resourceName)) "Missing executable resource $resourceName."
				if ($resourceType -eq 24)
				{
					$currentManifest = [xml][System.Text.Encoding]::UTF8.GetString($currentResources[$resourceName])
					$previousManifest = [xml][System.Text.Encoding]::UTF8.GetString($previousResources[$resourceName])
					$identityPath = "/*[local-name()='assembly']/*[local-name()='assemblyIdentity']"
					Assert-Release ($currentManifest.SelectSingleNode($identityPath).GetAttribute('version') -ceq $Version) 'Incorrect executable manifest version.'
					$previousManifest.SelectSingleNode($identityPath).SetAttribute('version', $Version)
					Assert-Release ($currentManifest.OuterXml -ceq $previousManifest.OuterXml) "Manifest behavior changed for $architecture."
				}
				else
				{
					Assert-Release ((Get-ByteHash $currentResources[$resourceName]) -ceq (Get-ByteHash $previousResources[$resourceName])) "Icon changed for $architecture, resource type $resourceType."
				}
			}
		}
	}
	$currentX64 = Join-Path (Join-Path $verificationDirectory ('current-' + $combinedName)) 'x64\SCOM-ReconfigureDatabaseLocations.exe'
	$singleX64 = Join-Path $verificationDirectory 'current-SCOM-Reconfigure-DB-Move-Tool-EXE.zip\x64\SCOM-ReconfigureDatabaseLocations.exe'
	Assert-Release ((Get-FileHash -LiteralPath $currentX64).Hash -ceq (Get-FileHash -LiteralPath $singleX64).Hash) 'The two executable ZIPs contain different x64 binaries.'
	Write-Output 'PASS: Native x86/x64 architectures and release versions are correct; runtime configs, icons, manifests and metadata match the prior release; checksums are valid.'

	$currentInstaller = Join-Path $verificationDirectory 'current-SCOM-Reconfigure-DB-Move-Tool-MSI.zip\SCOM-ReconfigureDatabaseLocations.msi'
	$previousInstaller = Join-Path $verificationDirectory 'previous-SCOM-Reconfigure-DB-Move-Tool-MSI.zip\SCOM-ReconfigureDatabaseLocations.msi'
	Assert-ArtifactChecksum $currentInstaller
	$currentSnapshot = Get-InstallerSnapshot $currentInstaller
	$previousSnapshot = Get-InstallerSnapshot $previousInstaller
	Assert-Release ($currentSnapshot.Properties.ProductVersion -ceq $Version) 'Incorrect MSI version.'
	Assert-Release ($currentSnapshot.Properties.ProductCode -ne $previousSnapshot.Properties.ProductCode -and $currentSnapshot.PackageCode -ne $previousSnapshot.PackageCode) 'A new full installer needs new product and package identities.'
	Assert-Release ($currentSnapshot.Template -ceq $previousSnapshot.Template -and $currentSnapshot.Template -eq 'x64;1033') 'The installer architecture or language changed.'
	foreach ($propertyName in @('UpgradeCode', 'ProductName', 'Manufacturer', 'ALLUSERS', 'ARPNOREPAIR'))
	{
		Assert-Release ($currentSnapshot.Properties[$propertyName] -ceq $previousSnapshot.Properties[$propertyName]) "Installer property changed: $propertyName"
	}
	$currentProductIcon = [ScomReleaseInspection]::ReadInstallerIcon($currentInstaller, $currentSnapshot.Properties.ARPPRODUCTICON)
	$previousProductIcon = [ScomReleaseInspection]::ReadInstallerIcon($previousInstaller, $previousSnapshot.Properties.ARPPRODUCTICON)
	Assert-Release ((Get-ByteHash $currentProductIcon) -ceq (Get-ByteHash $previousProductIcon)) 'The installed product icon changed.'
	foreach ($shortcutRow in $currentSnapshot.Shortcut)
	{
		$shortcutRow.Icon_ = Get-ByteHash ([ScomReleaseInspection]::ReadInstallerIcon($currentInstaller, $shortcutRow.Icon_))
	}
	foreach ($shortcutRow in $previousSnapshot.Shortcut)
	{
		$shortcutRow.Icon_ = Get-ByteHash ([ScomReleaseInspection]::ReadInstallerIcon($previousInstaller, $shortcutRow.Icon_))
	}
	foreach ($tableName in @('Directory', 'Component', 'Shortcut', 'Registry', 'LaunchCondition', 'InstallExecuteSequence'))
	{
		Assert-Release (($currentSnapshot[$tableName] | ConvertTo-Json -Depth 5 -Compress) -ceq ($previousSnapshot[$tableName] | ConvertTo-Json -Depth 5 -Compress)) "Installer behavior differs in table $tableName."
	}
	$currentUpgrade = ($currentSnapshot.Upgrade | ConvertTo-Json -Depth 5 -Compress).Replace($Version, 'RELEASE_VERSION')
	$previousUpgrade = ($previousSnapshot.Upgrade | ConvertTo-Json -Depth 5 -Compress).Replace($previousSnapshot.Properties.ProductVersion, 'RELEASE_VERSION')
	Assert-Release ($currentUpgrade -ceq $previousUpgrade) 'The installer upgrade/downgrade rules changed.'
	$oldVersion = [version]$previousSnapshot.Properties.ProductVersion
	$newVersion = [version]$Version
	Assert-Release ([version]$newVersion.ToString(3) -gt [version]$oldVersion.ToString(3)) 'The first three MSI version fields must advance.'
	Assert-Release ($currentSnapshot.File.Count -eq 3) 'The installer payload must retain exactly three files.'
	$oldFileContract = $previousSnapshot.File | Select-Object File, Component_, FileName, Language, Attributes, Sequence
	$newFileContract = $currentSnapshot.File | Select-Object File, Component_, FileName, Language, Attributes, Sequence
	Assert-Release (($newFileContract | ConvertTo-Json -Compress) -ceq ($oldFileContract | ConvertTo-Json -Compress)) 'Installer file names or component mappings changed.'
	$extractionDirectory = Join-Path $verificationDirectory 'cabinet'
	[void](New-Item -ItemType Directory -Path $extractionDirectory)
	$cabinetPath = Join-Path $verificationDirectory 'product.cab'
	[System.IO.File]::WriteAllBytes($cabinetPath, [ScomReleaseInspection]::ReadInstallerCabinet($currentInstaller))
	& (Join-Path $env:SystemRoot 'System32\expand.exe') '-F:*' $cabinetPath $extractionDirectory | Out-Null
	Assert-Release ($LASTEXITCODE -eq 0) 'The installer cabinet could not be extracted.'
	foreach ($fileRow in $currentSnapshot.File)
	{
		$longName = ($fileRow.FileName -split '\|')[-1]
		$archivedPath = Join-Path $extractionDirectory $fileRow.File
		$standalonePath = Join-Path (Split-Path $currentX64 -Parent) $longName
		Assert-Release ((Get-FileHash -LiteralPath $archivedPath).Hash -ceq (Get-FileHash -LiteralPath $standalonePath).Hash) "The MSI payload differs from the standalone package: $longName"
	}
	Write-Output 'PASS: MSI identity, upgrade rules, install scope, paths, shortcuts and conditions preserve the previous contract; its embedded files exactly match the standalone x64 package.'

	$originalChecksum = [System.IO.File]::ReadAllBytes($currentX64 + '.md5')
	try
	{
		[System.IO.File]::WriteAllText($currentX64 + '.md5', ('0' * 32), [System.Text.Encoding]::ASCII)
		$negativeControlFailed = $false
		try { Assert-ArtifactChecksum $currentX64 }
		catch
		{
			if ($_.Exception.Message -notlike 'Checksum mismatch:*') { throw }
			$negativeControlFailed = $true
		}
		Assert-Release $negativeControlFailed 'The checksum negative control did not detect artifact corruption.'
	}
	finally { [System.IO.File]::WriteAllBytes($currentX64 + '.md5', $originalChecksum) }
	Assert-ArtifactChecksum $currentX64
	Write-Output 'PASS: A corrupted checksum fails validation; restoring it passes. No executable or installer was launched.'
}
finally
{
	Remove-Item -LiteralPath $verificationDirectory -Recurse -Force
}