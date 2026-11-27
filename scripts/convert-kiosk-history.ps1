param(
    [Parameter(Mandatory = $true)][string]$InputFile,
    [Parameter(Mandatory = $true)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$documents = Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json
$usage = [System.Collections.Generic.List[object]]::new()
$activity = [System.Collections.Generic.List[object]]::new()
$sha = [System.Security.Cryptography.SHA256]::Create()
$utf8 = [System.Text.UTF8Encoding]::new($false)

function RequiredString($Fields, [string]$Name, [int]$Max) {
    $value = $Fields.$Name.stringValue
    if ([string]::IsNullOrWhiteSpace($value) -or $value.Length -gt $Max) {
        throw "Missing or invalid historical field: $Name"
    }
    return $value
}

try {
    foreach ($document in $documents) {
        if ($null -eq $document) { continue }
        $sourceName = $document.name
        $digest = $sha.ComputeHash($utf8.GetBytes($sourceName))
        $id = [guid]::new([byte[]]$digest[0..15]).ToString()
        $fields = $document.fields
        $timestamp = 0L
        if (-not [long]::TryParse($fields.timestamp.integerValue, [ref]$timestamp) -or $timestamp -lt 0) {
            throw 'Historical timestamp must be a nonnegative epoch millisecond integer.'
        }
        $app = RequiredString $fields 'appName' 255
        $process = RequiredString $fields 'processName' 255
        if ($sourceName -cmatch '^projects/[^/]+/databases/[^/]+/documents/classrooms/([^/]+)/usageLogs/[^/]+$') {
            $classCode = $Matches[1]
            if ([string]::IsNullOrWhiteSpace($classCode) -or $classCode.Length -gt 255) {
                throw 'Invalid historical class code.'
            }
            $usage.Add([pscustomobject]@{
                id = $id
                class_code = $classCode
                app_name = $app
                process_name = $process
                student_log = RequiredString $fields 'studentLog' 512
                student_name = RequiredString $fields 'studentName' 255
                timestamp = $timestamp
            })
        } elseif ($sourceName -cmatch '^projects/[^/]+/databases/[^/]+/documents/pcActivityLogs/[^/]+$') {
            $action = RequiredString $fields 'action' 7
            if ($action -cnotin @('OPENED', 'BLOCKED')) { throw 'Invalid historical activity action.' }
            $activity.Add([pscustomobject]@{
                id = $id
                pc_name = RequiredString $fields 'pcName' 255
                app_name = $app
                process_name = $process
                action = $action
                timestamp = $timestamp
            })
        } else {
            throw 'Unexpected historical document collection.'
        }
    }
} finally {
    $sha.Dispose()
}

$directory = (New-Item -ItemType Directory -Path $OutputDirectory -Force).FullName
[IO.File]::WriteAllLines((Join-Path $directory 'usage_logs.csv'), [string[]]@(
    'id,class_code,app_name,process_name,student_log,student_name,timestamp'
    $usage | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1
), $utf8)
[IO.File]::WriteAllLines((Join-Path $directory 'pc_activity_logs.csv'), [string[]]@(
    'id,pc_name,app_name,process_name,action,timestamp'
    $activity | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1
), $utf8)
Write-Host "Prepared $($usage.Count) usage rows and $($activity.Count) PC activity rows."
