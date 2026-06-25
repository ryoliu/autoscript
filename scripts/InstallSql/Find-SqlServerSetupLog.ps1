[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 200)]
    [int]$Newest = 20,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$KbNumber = 'KB5008996'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Add-ExistingPath {
    param(
        [Parameter()]
        [System.Collections.ArrayList]$Paths,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Container) {
        [void]$Paths.Add($Path)
    }
}

$searchRoots = New-Object System.Collections.ArrayList

foreach ($version in @('170', '160', '150', '140', '130', '120', '110')) {
    Add-ExistingPath -Paths $searchRoots -Path (Join-Path -Path ${env:ProgramFiles} -ChildPath "Microsoft SQL Server\$version\Setup Bootstrap\Log")
    Add-ExistingPath -Paths $searchRoots -Path (Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "Microsoft SQL Server\$version\Setup Bootstrap\Log")
}

Add-ExistingPath -Paths $searchRoots -Path $env:TEMP
Add-ExistingPath -Paths $searchRoots -Path 'C:\Windows\Temp'

$patterns = @(
    'Summary.txt',
    'Detail.txt',
    'Detail_ComponentUpdate.txt',
    '*.log',
    '*.txt'
)

$uniqueSearchRoots = $searchRoots | Select-Object -Unique

$logFiles = foreach ($root in $uniqueSearchRoots) {
    foreach ($pattern in $patterns) {
        Get-ChildItem -LiteralPath $root -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName -like '*SQL*' -or
                $_.FullName -like '*Setup Bootstrap*' -or
                $_.Name -like "*$KbNumber*" -or
                $_.Name -in @('Summary.txt', 'Detail.txt', 'Detail_ComponentUpdate.txt')
            }
    }
}

$results = $logFiles |
    Sort-Object FullName -Unique |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First $Newest FullName, LastWriteTime, Length

if ($null -eq $results) {
    Write-Warning 'No SQL Server setup log files were found in the common locations.'
    Write-Host 'Common locations to check manually:'
    Write-Host 'C:\Program Files\Microsoft SQL Server\150\Setup Bootstrap\Log'
    Write-Host 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log'
    Write-Host 'C:\Windows\Temp'
    Write-Host $env:TEMP
    return
}

$results

$latestSummary = $results |
    Where-Object { $_.FullName -like '*\Summary.txt' } |
    Select-Object -First 1

if ($null -ne $latestSummary) {
    Write-Host ''
    Write-Host 'Latest Summary.txt:'
    Write-Host $latestSummary.FullName
    Write-Host ''
    Write-Host 'Last 80 lines:'
    Get-Content -LiteralPath $latestSummary.FullName -Tail 80
}
