> :notebook: **Blog Post:** [https://blakedrumm.com/blog/scom-db-move-tool/](https://blakedrumm.com/blog/scom-db-move-tool) \
> :arrow_down_small: **Quick Download:** [https://aka.ms/SCOM-DB-Move-Tool](https://aka.ms/SCOM-DB-Move-Tool)

[![Visits Badge](https://badges.strrl.dev/visits/blakedrumm/SCOM-Reconfigure-DB-Move-Tool)](https://badges.strrl.dev) \
[![Latest Version](https://img.shields.io/github/v/release/blakedrumm/SCOM-Reconfigure-DB-Move-Tool)](https://github.com/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/releases/latest) \
[![Download Count Releases](https://img.shields.io/github/downloads/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/total.svg?style=for-the-badge&color=brightgreen)](https://github.com/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/releases) \
[![Download Count Latest](https://img.shields.io/github/downloads/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/latest/SCOM-Reconfigure-DB-Move-Tool-EXE.zip?style=for-the-badge&color=brightgreen)](https://aka.ms/SCOM-DB-Move-Tool)

[![SCOM Reconfigure DB Move Tool](https://user-images.githubusercontent.com/63755224/210493526-88f9e06d-8117-4fdc-9770-602afc751bae.png)](https://github.com/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/releases/latest)


## Introduction

SCOM Reconfigure Database Move Tool provides a Windows GUI for updating System Center Operations Manager database connection settings after a database move. It updates management-server configuration files, registry settings, and the related OperationsManager and Data Warehouse database tables. It does not copy, back up, or restore SQL database files.

## Features

- Configure OperationsManager and Data Warehouse server and database connection settings.
- Select local and remote management servers to update.
- Inspect related configuration-file, registry, and database values from the GUI.
- Use fully qualified SQL server names, DNS aliases, named instances, and Unicode values.
- Record database before/after values and activity in the Windows Application event log.
- Optionally configure SQL Service Broker, CLR, and full-text settings, and clear the SCOM cache.

## Downloads

Choose a package from the [latest GitHub release](https://github.com/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/releases/latest):

| Package | Download |
| --- | --- |
| Standalone executable | [EXE ZIP](https://github.com/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/releases/latest/download/SCOM-Reconfigure-DB-Move-Tool-EXE.zip) |
| 32-bit and 64-bit executables | [Combined EXE ZIP](https://github.com/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/releases/latest/download/SCOM-Reconfigure-DB-Move-Tool-EXE-32bit+64bit.zip) |
| Windows installer | [MSI ZIP](https://github.com/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/releases/latest/download/SCOM-Reconfigure-DB-Move-Tool-MSI.zip) |
| PowerShell script | [PS1 download](https://github.com/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/releases/latest/download/SCOM-Reconfigure-DB-Move-Tool.ps1) |

GitHub also provides source-code ZIP and TAR.GZ archives on each release page. The repository script is [SCOM-ReconfigureDatabaseLocations.ps1](SCOM-ReconfigureDatabaseLocations.ps1).

## Requirements

- Windows with Windows PowerShell 5.1 for running the GUI script.
- Administrator rights on the management servers being updated.
- SQL permissions for the selected database-table and database-configuration operations.
- PowerShell remoting configured for remote management-server operations.
- Database and configuration backups, with a validated migration plan for your SCOM environment.

## How to Use

1. Complete the database move and confirm that the destination databases are accessible.
2. Run the executable or PowerShell script as Administrator.
3. Review **Database Connection**. The tool attempts to populate these fields from the local registry; enter the reachable OperationsManager and Data Warehouse connections when necessary.
4. Enter the intended SQL instance and database names in **Values to Set**.
5. Select the management servers and operations to perform.
6. Inspect the related settings and verify the connections before starting the update.
7. Review the results and the Windows Application event log using event source `SCOMDBMoveTool`.

## Database Safety

Connection values are supplied through Unicode SQL parameters. Database and column identifiers support SQL Server's 128-character identifier limit. The existing SCOM schema and each destination column's length limit remain authoritative; the tool does not resize database columns.

Table updates are transactional within each database. A failed database job stops subsequent database, database-configuration, and cache steps. The overall migration is not a single transaction: earlier successful database, registry, or configuration-file changes are not rolled back. Validate the complete workflow in a test environment before updating production.

## Testing

Developers can run these checks from the repository root in Windows PowerShell 5.1 or PowerShell 7 on Windows:

```powershell
.\tests\Test-DatabaseQueries.ps1
.\tests\Test-DatabaseWorkflow.ps1
.\tests\Test-DatabaseIntegration.ps1
```

[Query tests](tests/Test-DatabaseQueries.ps1) exercise the SQL update functions and preview job without launching the GUI or connecting to SQL Server. [Workflow tests](tests/Test-DatabaseWorkflow.ps1) run isolated background jobs with controlled test workers.

[Integration tests](tests/Test-DatabaseIntegration.ps1) require SQL Server Express LocalDB with `SqlLocalDB.exe` on `PATH`. They create and remove a uniquely named private LocalDB instance and test database, never use an existing SCOM database, and cover long names, quotes, Unicode, audit output, preview values, rollback and SQL error handling. The tables are representative fixtures, not a complete SCOM schema.

For native executable and installer builds, see [Release Packaging](build/README.md).

## More Information

The tool prompts you to accept the license agreement. Selecting **Do not ask me again** records acceptance in `C:\ProgramData\SCOM-DBMoveTool-AgreedToLicense.log`. See [LICENSE](LICENSE) for the license terms.

For questions or problem reports, [open a GitHub issue](https://github.com/blakedrumm/SCOM-Reconfigure-DB-Move-Tool/issues).

Attribution for the icon:
<a href="https://www.flaticon.com/free-icons/database" title="database icons">Database icons created by manshagraphics - Flaticon</a>
