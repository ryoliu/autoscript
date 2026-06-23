---
name: powershell-jenkins
description: Use when managing Jenkins with PowerShell, including Jenkins REST API authentication, API tokens, crumb issuer CSRF handling, triggering normal or parameterized jobs, checking queue status, polling build status, and returning Jenkins build results from Windows automation.
---

# PowerShell Jenkins

## Workflow

1. Confirm the Jenkins base URL, job path, authentication method, and requested action.
2. Prefer username plus Jenkins API token over account passwords.
3. Use the Jenkins REST API from PowerShell with `Invoke-RestMethod` or `Invoke-WebRequest`.
4. Retrieve a crumb from `/crumbIssuer/api/json` when available, then include it on mutating requests.
5. For folder jobs, encode each path segment as `/job/<segment>`.
6. Return structured PowerShell objects containing queue URL, build URL, build number, building state, and result.

## Supported Scope

- Trigger a non-parameterized Jenkins job.
- Trigger a parameterized Jenkins job.
- Read queue status until a build is assigned.
- Poll build status until completion when requested.
- Test authentication with Jenkins API endpoints.

## Safety

- Do not print API tokens, passwords, or Basic Authorization headers.
- Do not create, delete, disable, stop, or reconfigure Jenkins jobs unless the user explicitly asks and confirms the high-risk action.
- Do not assume a production job should be triggered. If the target environment is ambiguous and the action is mutating, ask for confirmation.

## Validation

- Test authentication against `/api/json`.
- Verify crumb handling without failing when the crumb issuer is disabled or unavailable.
- Confirm a trigger response includes a queue `Location` header.
- When waiting, verify queue assignment and build result through `/api/json`.

## Local Script

Use `C:\AutoScript\scripts\Invoke-JenkinsJob.ps1` when the task is to trigger a Jenkins job or query queue/build status from PowerShell.
