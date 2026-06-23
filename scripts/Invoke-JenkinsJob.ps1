[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$JenkinsUrl,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$JobPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$UserName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [securestring]$ApiToken,

    [Parameter()]
    [hashtable]$Parameters,

    [Parameter()]
    [switch]$Wait,

    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$PollSeconds = 5,

    [Parameter()]
    [ValidateRange(10, 86400)]
    [int]$TimeoutSeconds = 1800
)

$ErrorActionPreference = "Stop"

function ConvertTo-PlainText {
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$SecureValue
    )

    return (New-Object System.Net.NetworkCredential("", $SecureValue)).Password
}

function New-BasicAuthHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$User,

        [Parameter(Mandatory = $true)]
        [securestring]$Token
    )

    $plainToken = ConvertTo-PlainText -SecureValue $Token
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("${User}:$plainToken")
    $encoded = [Convert]::ToBase64String($bytes)
    return "Basic $encoded"
}

function Join-Url {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return ("{0}/{1}" -f $BaseUrl.TrimEnd("/"), $RelativePath.TrimStart("/"))
}

function Get-JenkinsJobUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $segments = $Path -split "[/\\]" | Where-Object { $_ -and $_.Trim() }
    if ($segments.Count -eq 0) {
        throw "JobPath must include at least one job name."
    }

    $encodedSegments = foreach ($segment in $segments) {
        "job/{0}" -f [System.Uri]::EscapeDataString($segment.Trim())
    }

    return Join-Url -BaseUrl $BaseUrl -RelativePath ($encodedSegments -join "/")
}

function Invoke-JenkinsJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    return Invoke-RestMethod -Uri $Uri -Method Get -Headers $Headers -ErrorAction Stop
}

function Get-JenkinsCrumbHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $crumbUrl = Join-Url -BaseUrl $BaseUrl -RelativePath "crumbIssuer/api/json"

    try {
        $crumb = Invoke-JenkinsJson -Uri $crumbUrl -Headers $Headers
        if ($crumb.crumbRequestField -and $crumb.crumb) {
            return @{ "$($crumb.crumbRequestField)" = "$($crumb.crumb)" }
        }
    } catch {
        $response = $_.Exception.Response
        if ($response -and [int]$response.StatusCode -in @(404, 403)) {
            return @{}
        }

        throw
    }

    return @{}
}

function Merge-Headers {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$First,

        [Parameter(Mandatory = $true)]
        [hashtable]$Second
    )

    $merged = @{}
    foreach ($key in $First.Keys) {
        $merged[$key] = $First[$key]
    }
    foreach ($key in $Second.Keys) {
        $merged[$key] = $Second[$key]
    }

    return $merged
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [int]$IntervalSeconds,

        [Parameter(Mandatory = $true)]
        [int]$MaxSeconds,

        [Parameter(Mandatory = $true)]
        [string]$TimeoutMessage
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($watch.Elapsed.TotalSeconds -lt $MaxSeconds) {
        $result = & $ScriptBlock
        if ($result) {
            return $result
        }

        Start-Sleep -Seconds $IntervalSeconds
    }

    throw $TimeoutMessage
}

$baseUrl = $JenkinsUrl.TrimEnd("/")
$authHeaders = @{
    Authorization = New-BasicAuthHeader -User $UserName -Token $ApiToken
}

Invoke-JenkinsJson -Uri (Join-Url -BaseUrl $baseUrl -RelativePath "api/json") -Headers $authHeaders | Out-Null

$crumbHeaders = Get-JenkinsCrumbHeader -BaseUrl $baseUrl -Headers $authHeaders
$headers = Merge-Headers -First $authHeaders -Second $crumbHeaders
$jobUrl = Get-JenkinsJobUrl -BaseUrl $baseUrl -Path $JobPath

if ($Parameters -and $Parameters.Count -gt 0) {
    $triggerUrl = Join-Url -BaseUrl $jobUrl -RelativePath "buildWithParameters"
    $triggerResponse = Invoke-WebRequest -Uri $triggerUrl -Method Post -Headers $headers -Body $Parameters -ContentType "application/x-www-form-urlencoded" -UseBasicParsing -ErrorAction Stop
} else {
    $triggerUrl = Join-Url -BaseUrl $jobUrl -RelativePath "build"
    $triggerResponse = Invoke-WebRequest -Uri $triggerUrl -Method Post -Headers $headers -UseBasicParsing -ErrorAction Stop
}

$queueUrl = [string]$triggerResponse.Headers.Location
if (-not $queueUrl) {
    throw "Jenkins did not return a queue Location header after triggering the job."
}

$result = [ordered]@{
    QueueUrl    = $queueUrl
    BuildUrl    = $null
    BuildNumber = $null
    Building    = $null
    Result      = $null
}

if ($Wait) {
    $queueApiUrl = Join-Url -BaseUrl $queueUrl -RelativePath "api/json"
    $queueItem = Wait-Until -IntervalSeconds $PollSeconds -MaxSeconds $TimeoutSeconds -TimeoutMessage "Timed out waiting for Jenkins queue item to receive a build number." -ScriptBlock {
        $item = Invoke-JenkinsJson -Uri $queueApiUrl -Headers $authHeaders

        if ($item.cancelled) {
            throw "Jenkins queue item was cancelled."
        }

        if ($item.executable -and $item.executable.number -and $item.executable.url) {
            return $item
        }

        return $null
    }

    $result.BuildUrl = [string]$queueItem.executable.url
    $result.BuildNumber = [int]$queueItem.executable.number

    $buildApiUrl = Join-Url -BaseUrl $result.BuildUrl -RelativePath "api/json"
    $buildInfo = Wait-Until -IntervalSeconds $PollSeconds -MaxSeconds $TimeoutSeconds -TimeoutMessage "Timed out waiting for Jenkins build to finish." -ScriptBlock {
        $build = Invoke-JenkinsJson -Uri $buildApiUrl -Headers $authHeaders

        if (-not $build.building) {
            return $build
        }

        return $null
    }

    $result.Building = [bool]$buildInfo.building
    $result.Result = [string]$buildInfo.result
}

[pscustomobject]$result
