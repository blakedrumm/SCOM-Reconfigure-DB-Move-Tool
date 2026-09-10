[CmdletBinding()]
param
(
	[Parameter(Mandatory = $true)]
	[ValidatePattern('^\d+\.\d+\.\d+\.\d+$')]
	[string]$Version,
	[string]$IconPath,
	[string]$SapienPath = 'C:\Program Files\SAPIEN Technologies, Inc\PrimalScript 2024',
	[string]$OutputDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$sourcePath = Join-Path $repositoryRoot 'SCOM-ReconfigureDatabaseLocations.ps1'
$buildExecutable = Join-Path $SapienPath 'PSBuild.exe'
if (-not $IconPath)
{
	$IconPath = Join-Path $PSScriptRoot 'assets\dbmovetoolicon.ico'
}
foreach ($requiredPath in @($sourcePath, $buildExecutable, $IconPath))
{
	if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf))
	{
		throw "Required build input not found: $requiredPath"
	}
}
$IconPath = (Resolve-Path -LiteralPath $IconPath).Path
$sourceText = [System.IO.File]::ReadAllText($sourcePath)
$versionPattern = '\$ScriptMoveVersion\s*=\s*' + "'" + [regex]::Escape($Version) + "'"
if ($sourceText -notmatch $versionPattern)
{
	throw "The application version must match release version $Version."
}

if (-not $OutputDirectory)
{
	$OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('SCOM-DBMove-v' + $Version + '-' + [guid]::NewGuid().ToString('N'))
}
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory)
{
	throw "Use a new output directory to avoid publishing stale artifacts: $OutputDirectory"
}
$stageDirectory = Join-Path $OutputDirectory 'stage'
$assetDirectory = Join-Path $OutputDirectory 'assets'
[void](New-Item -ItemType Directory -Path $stageDirectory, $assetDirectory)
$stagedSource = Join-Path $stageDirectory 'SCOM-ReconfigureDatabaseLocations.ps1'
Copy-Item -LiteralPath $sourcePath -Destination $stagedSource
$settingsPath = $stagedSource + '.psbuild'
$productCode = '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
$msiDirectory = Join-Path $stageDirectory 'MSI'
[void](New-Item -ItemType Directory -Path $msiDirectory)
$profile = @"
[Package]
PSBuildVersion=4.9
Output=SCOM-ReconfigureDatabaseLocations
OutputPath=.\bin
Manifest=
ManifestType=1
STA=1
GenerateConfigFile=1
Obfuscate=0
ResolveExternalScripts=0
HashType=MD5
Engine=SAPIEN PowerShell V5 Host (Windows Forms)
Target=Microsoft Windows 32 Bit;Microsoft Windows 64 Bit
UseRunAs=0
FileVersion=$Version
ProductVersion=$Version
ProductName=SCOM-ReconfigureDatabaseLocations
Description=https://blakedrumm.com/blog/scom-db-move-tool/
Company=Blake Drumm
Copyright=Copyright (c) 2024 All rights reserved
OriginalName=SCOM-ReconfigureDatabaseLocations
RestrictInstance=0
ProhibitLogging=0
DisableLogging=0
DisableTranscript=0
AutoIncrementVersion=0
Icon1=$IconPath
[MSI]
ProductGUID=$productCode
UpgradeGUID={74374D44-DFAF-4EDA-A008-F88809D26996}
ProductName=System Center Operations Manager - Reconfigure Database Move
ProductVersion=$Version
LastVersion=$Version
ProductType=Windows Application
CompanyName=System Center Operations Manager Tools
ProductIcon=$IconPath
MSIName=SCOM-ReconfigureDatabaseLocations
OutputFolder=$msiDirectory
InstallFolder=[ProgramFiles]\[Company]\System Center Operations Manager - Reconfigure Database Move
UseUI=0
MinimumPowershellVersion=PowerShell Version 5
AllUsers=1
AsAdmin=1
MSIHashType=MD5
Platform=64 Bit Package
UISelection=1
ModuleOverwrite=1
ModuleUninstall=0
ModuleAllUsers=1
[MSI Files]
File1=.\bin\x64\SCOM-ReconfigureDatabaseLocations.exe
File2=.\bin\x64\SCOM-ReconfigureDatabaseLocations.exe.config
File3=.\bin\x64\SCOM-ReconfigureDatabaseLocations.exe.md5
[MSIShortcut_1]
ShortcutName=System Center Operations Manager - Reconfigure Database Move
ShortcutDescription=
ShortcutAdvertised=0
ShortcutArguments=
ShortcutTarget=[INSTALLDIR]SCOM-ReconfigureDatabaseLocations.exe
ShortcutFolder=INSTALLDIR
ShortcutIconfile=$IconPath
ShortcutIconindex=0
ShortcutRunMode=Normal
ShortcutLocation=Start Menu\Programs\System Center Operations Manager Tools
[MSI Shortcuts]
Shortcut1=1
"@
[System.IO.File]::WriteAllText($settingsPath, $profile, [System.Text.Encoding]::Unicode)

Push-Location $stageDirectory
try
{
	& $buildExecutable /PACKAGE $settingsPath
	if ($LASTEXITCODE -ne 0) { throw "SAPIEN packaging failed with exit code $LASTEXITCODE." }
	foreach ($architecture in @('x86', 'x64'))
	{
		$executablePath = Join-Path $stageDirectory "bin\$architecture\SCOM-ReconfigureDatabaseLocations.exe"
		foreach ($artifactPath in @($executablePath, "$executablePath.config", "$executablePath.md5"))
		{
			if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "Missing SAPIEN output: $artifactPath" }
		}
		$versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($executablePath)
		if ($versionInfo.FileVersion -ne $Version -or $versionInfo.ProductVersion -ne $Version)
		{
			throw "Incorrect executable version in $executablePath."
		}
	}
	& $buildExecutable /MSI $settingsPath
	if ($LASTEXITCODE -ne 0) { throw "SAPIEN MSI build failed with exit code $LASTEXITCODE." }
	$installerPath = Join-Path $msiDirectory 'SCOM-ReconfigureDatabaseLocations.msi'
	foreach ($artifactPath in @($installerPath, "$installerPath.md5"))
	{
		if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "Missing installer output: $artifactPath" }
	}
	Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
	$executableFiles = @('SCOM-ReconfigureDatabaseLocations.exe', 'SCOM-ReconfigureDatabaseLocations.exe.config', 'SCOM-ReconfigureDatabaseLocations.exe.md5')
	$x64Entries = @($executableFiles | ForEach-Object { 'x64/' + $_ })
	$x86Entries = @($executableFiles | ForEach-Object { 'x86/' + $_ })
	$archiveDefinitions = @(
		@{ Name = 'SCOM-Reconfigure-DB-Move-Tool-EXE.zip'; Root = (Join-Path $stageDirectory 'bin'); Entries = $x64Entries }
		@{ Name = 'SCOM-Reconfigure-DB-Move-Tool-EXE-32bit+64bit.zip'; Root = (Join-Path $stageDirectory 'bin'); Entries = ($x64Entries + $x86Entries) }
		@{ Name = 'SCOM-Reconfigure-DB-Move-Tool-MSI.zip'; Root = $msiDirectory; Entries = @('SCOM-ReconfigureDatabaseLocations.msi', 'SCOM-ReconfigureDatabaseLocations.msi.md5') }
	)
	foreach ($archiveDefinition in $archiveDefinitions)
	{
		$archivePath = Join-Path $assetDirectory $archiveDefinition.Name
		$archive = [System.IO.Compression.ZipFile]::Open($archivePath, [System.IO.Compression.ZipArchiveMode]::Create)
		try
		{
			foreach ($entryName in $archiveDefinition.Entries)
			{
				$inputPath = Join-Path $archiveDefinition.Root $entryName
				[void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $inputPath, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
			}
		}
		finally { $archive.Dispose() }
	}
	Copy-Item -LiteralPath $stagedSource -Destination (Join-Path $assetDirectory 'SCOM-Reconfigure-DB-Move-Tool.ps1')
}
finally
{
	Pop-Location
}

Write-Output "Release assets: $assetDirectory"