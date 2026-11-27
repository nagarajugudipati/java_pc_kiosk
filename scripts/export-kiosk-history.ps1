param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z][a-z0-9-]+$')][string]$SourceProject,
    [Parameter(Mandatory = $true)][string]$OutputFile
)

$ErrorActionPreference = 'Stop'
$token = $env:KIOSK_HISTORY_READ_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'Set KIOSK_HISTORY_READ_TOKEN in this process from an authorized read-only Google identity.'
}

$endpoint = "https://firestore.googleapis.com/v1/projects/$SourceProject/databases/(default)/documents:runQuery"
$documents = [System.Collections.Generic.List[object]]::new()
foreach ($collection in @('usageLogs', 'pcActivityLogs')) {
    $body = @{
        structuredQuery = @{
            from = @(@{ collectionId = $collection; allDescendants = ($collection -eq 'usageLogs') })
        }
    } | ConvertTo-Json -Depth 5 -Compress
    $rows = Invoke-RestMethod -Method Post -Uri $endpoint -ContentType 'application/json' `
        -Headers @{ Authorization = "Bearer $token" } -Body $body
    foreach ($row in $rows) {
        if ($row.document.name -cmatch '/documents/(classrooms/[^/]+/usageLogs|pcActivityLogs)/[^/]+$') {
            $documents.Add($row.document)
        }
    }
}

$path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
$json = ConvertTo-Json -InputObject @($documents.ToArray()) -Depth 20
[IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
Write-Host "Exported $($documents.Count) source documents."
