# Release Packaging

The release uses SAPIEN's PowerShell V5 Windows Forms hosts for x86 and x64 and the SAPIEN MSI builder for a per-machine x64 installer. A licensed installation of SAPIEN PrimalScript or PowerShell Studio with `PSBuild.exe`, both V5 Windows Forms engines, and the bundled WiX tools is required. These proprietary tools are not redistributed by this repository.

## Build

Set the application's `$ScriptMoveVersion` in [SCOM-ReconfigureDatabaseLocations.ps1](../SCOM-ReconfigureDatabaseLocations.ps1) to the intended four-part version, then run from the repository root:

```powershell
.\build\Build-Release.ps1 -Version 2.5.1.0
```

The default tool location is `C:\Program Files\SAPIEN Technologies, Inc\PrimalScript 2024`. Use `-SapienPath` for a different installation. The original release icon is included in [build/assets/dbmovetoolicon.ico](assets/dbmovetoolicon.ico); `-IconPath` can select another input explicitly.

The build uses the repository's standalone script, not external PowerShell Studio designer files. It creates a new temporary staging directory and prints the asset directory. `-OutputDirectory` can specify a new directory; existing directories are rejected to avoid mixing artifacts from separate builds.

## Asset Contract

| Release asset | Contents |
| --- | --- |
| `SCOM-Reconfigure-DB-Move-Tool-EXE.zip` | `x64/SCOM-ReconfigureDatabaseLocations.exe`, its `.exe.config`, and its `.exe.md5` |
| `SCOM-Reconfigure-DB-Move-Tool-EXE-32bit+64bit.zip` | The same three files in both `x64/` and `x86/` |
| `SCOM-Reconfigure-DB-Move-Tool-MSI.zip` | `SCOM-ReconfigureDatabaseLocations.msi` and its `.msi.md5` at the ZIP root |
| `SCOM-Reconfigure-DB-Move-Tool.ps1` | An exact copy of the repository script |

GitHub supplies the source ZIP and TAR.GZ archives automatically. The MD5 companions retain the historical format for compatibility; they are not signatures or a security guarantee. Packages are unsigned, matching the existing release process.

The installer retains UpgradeCode `{74374D44-DFAF-4EDA-A008-F88809D26996}`, the original install directory, and the Start Menu shortcut. Each build receives new ProductCode and PackageCode values. Advance one of the first three version fields for an MSI upgrade; do not rely solely on the fourth field.

## Validate

Run the database and workflow tests documented in the root [README.md](../README.md). Download the reference release into a separate directory and compare the new packages:

```powershell
gh release download v2.5.0.0 --repo blakedrumm/SCOM-Reconfigure-DB-Move-Tool --dir C:\Temp\SCOM-Reference-v2.5.0.0
.\tests\Test-ReleasePackages.ps1 -Version 2.5.1.0 -AssetDirectory C:\Temp\SCOM-Build\assets -ReferenceDirectory C:\Temp\SCOM-Reference-v2.5.0.0
```

Replace the example paths with the downloaded reference directory and the asset directory printed by the build. The package test checks exact archive paths, source equality, PE architectures, versions, icons, manifests, runtime configuration, checksums, MSI upgrade metadata, installation layout, and embedded installer payload. It reads binaries as data and does not launch them or install the MSI.

Fresh installation, upgrade, rollback, and uninstall should also be exercised on a disposable Windows VM. Static package checks do not establish those installed-state behaviors or validate a complete production SCOM environment.

The build script does not commit, tag, push, or publish. Publish only validated artifacts from the intended release commit. Keep version-specific changes in [release-notes/v2.5.1.0.md](release-notes/v2.5.1.0.md), not in the product README.