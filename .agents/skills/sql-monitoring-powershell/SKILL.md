---
name: sql-monitoring-powershell
description: Create, modify, or review PowerShell files under scripts/SqlMonitoring using DBA-readable structure, straightforward PowerShell and dbatools, focused validation, and actionable SQL Server errors. Use only for PowerShell coding in this directory, not for unrelated PowerShell elsewhere in the repository.
---

# SQL Monitoring PowerShell

## Scope

Use this skill when the target `.ps1` or `.psm1` file is under
`C:\powershell\Script\autoscript\scripts\SqlMonitoring`.

The current user request and repository instructions take precedence. Keep edits
limited to the requested behavior and preserve compatible configuration,
credential, repository, and module conventions unless the request requires a
change.

## Guidance routing

For every coding or review task, read
[references/PowerShell-AI-Writing-Guide-DBA-Simple.md](references/PowerShell-AI-Writing-Guide-DBA-Simple.md)
completely and apply it.

Also read
[references/PowerShell-AI-Writing-Guidelines-Simple.md](references/PowerShell-AI-Writing-Guidelines-Simple.md)
completely when creating a script, making a substantial change, or working on
configuration, credentials, repository writes, system-database filtering,
controller scripts, compatibility, or response and acceptance requirements.
For a narrow edit, consult the expanded guide only when those details affect the
request.

## Workflow

1. Inspect the target script and the nearby config, credential, module, and
   caller paths that affect it.
2. Prefer a direct, top-to-bottom flow that a SQL Server DBA can maintain.
3. Use basic PowerShell and dbatools when they meet the requirement; add
   advanced structures only for a concrete need and explain that need.
4. Make the smallest focused change that satisfies the user request. Do not
   refactor unrelated code.
5. Validate PowerShell syntax and run relevant repository tests when available.
   Do not treat a request to edit code as permission to execute it against a
   live SQL Server.

When reporting completion, state what changed, what was validated, and any live
database behavior that was not exercised.
