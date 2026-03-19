param(
  [switch]$Strict,
  [switch]$DryRun,
  [ValidateSet('markdown','json')]
  [string]$Format = 'markdown'
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$syncScript = Join-Path $scriptDir 'skills-sync.ps1'
$auditScript = Join-Path $scriptDir 'skills-audit.ps1'

$homeDir = [Environment]::GetFolderPath('UserProfile')
$sharedPath = Join-Path $homeDir '.agents/skills'
$claudePath = Join-Path $homeDir '.claude/skills'
$cursorPath = Join-Path $homeDir '.cursor/skills'
$geminiPath = Join-Path $homeDir '.gemini/skills'
$codexPath = Join-Path $homeDir '.codex/skills'

$clientDefs = @(
  [pscustomobject]@{ name = 'claude'; path = $claudePath },
  [pscustomobject]@{ name = 'cursor'; path = $cursorPath },
  [pscustomobject]@{ name = 'gemini'; path = $geminiPath },
  [pscustomobject]@{ name = 'codex'; path = $codexPath }
)

if (-not (Test-Path $syncScript)) { throw "Missing script: $syncScript" }
if (-not (Test-Path $auditScript)) { throw "Missing script: $auditScript" }
if (-not (Test-Path $sharedPath)) { throw "Missing shared path: $sharedPath" }

$syncedClients = New-Object System.Collections.Generic.List[string]
$skippedClients = New-Object System.Collections.Generic.List[string]
foreach ($client in $clientDefs) {
  if (Test-Path $client.path) {
    $syncedClients.Add($client.name) | Out-Null
  } else {
    $skippedClients.Add($client.name) | Out-Null
  }
}

try {
  if ($DryRun) {
    $syncOutput = & $syncScript -DryRun 2>&1
  } else {
    $syncOutput = & $syncScript 2>&1
  }
} catch {
  throw "Sync failed: $($_.Exception.Message)"
}

try {
  if ($Strict) {
    $auditRaw = & $auditScript -Format json -Strict 2>&1
  } else {
    $auditRaw = & $auditScript -Format json 2>&1
  }
} catch {
  throw "Audit failed: $($_.Exception.Message)"
}

try {
  $audit = ($auditRaw -join "`n") | ConvertFrom-Json
} catch {
  throw "Audit JSON parse failed: $($_.Exception.Message)"
}

function Get-Names([string]$path) {
  if (-not (Test-Path $path)) { return @() }
  return @((Get-ChildItem -Path $path -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) | Sort-Object)
}

$sharedNames = Get-Names $sharedPath
$claudeNames = Get-Names $claudePath
$cursorNames = Get-Names $cursorPath
$geminiNames = Get-Names $geminiPath
$codexNames = Get-Names $codexPath

$sharedSet = @{}
foreach ($n in $sharedNames) { $sharedSet[$n] = $true }

function Get-Dedicated([string[]]$names, [hashtable]$baseline) {
  $arr = New-Object System.Collections.Generic.List[string]
  foreach ($n in $names) {
    if (-not $baseline.ContainsKey($n)) { $arr.Add($n) | Out-Null }
  }
  return @($arr | Sort-Object)
}

$dedicated = [ordered]@{
  claude = Get-Dedicated $claudeNames $sharedSet
  cursor = Get-Dedicated $cursorNames $sharedSet
  gemini = Get-Dedicated $geminiNames $sharedSet
  codex = Get-Dedicated $codexNames $sharedSet
}

$counts = [ordered]@{
  shared = $sharedNames.Count
  claude = $claudeNames.Count
  cursor = $cursorNames.Count
  gemini = $geminiNames.Count
  codex = $codexNames.Count
}

function Cn([int[]]$codes) {
  return -join ($codes | ForEach-Object { [char]$_ })
}

$TXT_NONE = Cn @(26080)
$TXT_SYNC_STATUS = Cn @(21516,27493,29366,24577)
$TXT_SYNCED_CLIENTS = Cn @(24050,21516,27493,23458,25143,31471)
$TXT_SKIPPED_CLIENTS = Cn @(26410,25214,21040,30446,24405,24182,36339,36807)
$TXT_FOLDER_COUNTS = Cn @(30446,24405,25968,37327)
$TXT_DEDICATED_SKILLS = Cn @(19987,23646,25216,33021)
$TXT_AUDIT_SUMMARY = Cn @(23457,35745,25688,35201)
$TXT_TOTAL_ISSUES = Cn @(38382,39064,24635,25968)
$TXT_BLOCKING = Cn @(38459,26029)
$TXT_WARNING = Cn @(35686,21578)
$TXT_INFO = Cn @(25552,31034)
$TXT_SUGGEST_EXIT_CODE = Cn @(24314,35758,36864,20986,30721)
$TXT_CONCLUSION = Cn @(32467,35770)
$TXT_FINDINGS = Cn @(38382,39064,26126,32454)
$TXT_OK = Cn @(21516,27493,25104,21151,65288,38598,21512,19968,33268,65289)
$TXT_ISSUES = Cn @(23384,22312,38382,39064,65288,35831,26597,30475,38382,39064,26126,32454,65289)

$hasIssue = ($audit.Severity.blocking -gt 0 -or $audit.Severity.warning -gt 0)
$conclusion = if ($hasIssue) { $TXT_ISSUES } else { $TXT_OK }

$report = [ordered]@{
  checkedAt = $audit.Summary.checkedAt
  dryRun = $DryRun.IsPresent
  strict = $Strict.IsPresent
  syncStatus = [ordered]@{
    syncedClients = @($syncedClients)
    skippedClients = @($skippedClients)
  }
  folderCounts = $counts
  dedicatedSkills = $dedicated
  audit = [ordered]@{
    total = $audit.Summary.total
    blocking = $audit.Severity.blocking
    warning = $audit.Severity.warning
    info = $audit.Severity.info
    suggestedExitCode = $audit.SuggestedExitCode
  }
  findings = @($audit.Findings)
  conclusion = $conclusion
}

if ($Format -eq 'json') {
  $report | ConvertTo-Json -Depth 10
  exit 0
}

Write-Output "## $TXT_SYNC_STATUS"
Write-Output "- ${TXT_SYNCED_CLIENTS}: $(if ($syncedClients.Count -gt 0) { $syncedClients -join ', ' } else { $TXT_NONE })"
Write-Output "- ${TXT_SKIPPED_CLIENTS}: $(if ($skippedClients.Count -gt 0) { $skippedClients -join ', ' } else { $TXT_NONE })"
Write-Output ''

Write-Output "## $TXT_FOLDER_COUNTS"
Write-Output "- shared (~/.agents/skills): $($counts.shared)"
Write-Output "- claude (~/.claude/skills): $($counts.claude)"
Write-Output "- cursor (~/.cursor/skills): $($counts.cursor)"
Write-Output "- gemini (~/.gemini/skills): $($counts.gemini)"
Write-Output "- codex (~/.codex/skills): $($counts.codex)"
Write-Output ''

Write-Output "## $TXT_DEDICATED_SKILLS"
Write-Output ("- claude: " + ($(if($dedicated.claude.Count){$dedicated.claude -join ', '} else {$TXT_NONE})))
Write-Output ("- cursor: " + ($(if($dedicated.cursor.Count){$dedicated.cursor -join ', '} else {$TXT_NONE})))
Write-Output ("- gemini: " + ($(if($dedicated.gemini.Count){$dedicated.gemini -join ', '} else {$TXT_NONE})))
Write-Output ("- codex: " + ($(if($dedicated.codex.Count){$dedicated.codex -join ', '} else {$TXT_NONE})))
Write-Output ''

Write-Output "## $TXT_AUDIT_SUMMARY"
Write-Output "- ${TXT_TOTAL_ISSUES}: $($report.audit.total)"
Write-Output "- ${TXT_BLOCKING}: $($report.audit.blocking)"
Write-Output "- ${TXT_WARNING}: $($report.audit.warning)"
Write-Output "- ${TXT_INFO}: $($report.audit.info)"
Write-Output "- ${TXT_SUGGEST_EXIT_CODE}: $($report.audit.suggestedExitCode)"
Write-Output ''

Write-Output "## $TXT_CONCLUSION"
Write-Output "- $conclusion"

if ($hasIssue -and $report.findings.Count -gt 0) {
  Write-Output ''
  Write-Output "## $TXT_FINDINGS"
  $i = 1
  foreach ($f in $report.findings) {
    $sev = $f.severity.ToUpperInvariant()
    Write-Output "$i. [$sev] $($f.message)"
    $i++
  }
}

