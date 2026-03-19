param(
  [ValidateSet('markdown', 'json')]
  [string]$Format = 'markdown',
  [switch]$Strict,
  [int]$MinUsageToKeep = 2
)

$ErrorActionPreference = 'Stop'

$homeDir = [Environment]::GetFolderPath('UserProfile')
$agentsRoot = Join-Path $homeDir '.agents'
$sharedSkillsPath = Join-Path $agentsRoot 'skills'
$baseAuditScript = Join-Path $agentsRoot 'tools/skills-audit.ps1'

$clientDefs = @(
  [pscustomobject]@{
    name = 'claude'
    skillsPath = Join-Path $homeDir '.claude/skills'
    logs = @(
      [pscustomobject]@{ type = 'jsonl'; path = Join-Path $homeDir '.claude/history.jsonl'; textField = 'display' }
    )
  },
  [pscustomobject]@{
    name = 'cursor'
    skillsPath = Join-Path $homeDir '.cursor/skills'
    logs = @(
      [pscustomobject]@{ type = 'sqlite'; path = Join-Path $homeDir '.cursor/ai-tracking/ai-code-tracking.db'; textField = '' }
    )
  },
  [pscustomobject]@{
    name = 'gemini'
    skillsPath = Join-Path $homeDir '.gemini/skills'
    logs = @(
      [pscustomobject]@{ type = 'json-array-recursive'; path = Join-Path $homeDir '.gemini/tmp'; filter = 'logs.json'; textField = 'message' }
    )
  },
  [pscustomobject]@{
    name = 'codex'
    skillsPath = Join-Path $homeDir '.codex/skills'
    logs = @(
      [pscustomobject]@{ type = 'jsonl'; path = Join-Path $homeDir '.codex/history.jsonl'; textField = 'text' }
    )
  }
)

$findings = New-Object System.Collections.Generic.List[object]
$protectedSkills = @('global-skill-sync', 'skills-governance-audit', 'skill-saver')

function Add-Finding {
  param(
    [ValidateSet('blocking', 'warning', 'info')]
    [string]$Severity,
    [string]$Id,
    [string]$Message,
    [string[]]$Paths,
    [string]$Fix
  )
  $findings.Add([pscustomobject]@{
      severity = $Severity
      id = $Id
      message = $Message
      paths = @($Paths)
      fix = $Fix
    }) | Out-Null
}

function Get-SharedSkills {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return @() }
  $items = Get-ChildItem -Path $Path -Directory -Force -ErrorAction SilentlyContinue
  return @(
    $items |
      Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } |
      ForEach-Object { $_.Name } |
      Sort-Object
  )
}

function Read-JsonLinesText {
  param(
    [string]$Path,
    [string]$TextField
  )
  $texts = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path $Path)) { return @($texts) }
  Get-Content -Path $Path -ErrorAction SilentlyContinue | ForEach-Object {
    $line = $_
    if ([string]::IsNullOrWhiteSpace($line)) { return }
    try {
      $obj = $line | ConvertFrom-Json
      $v = $obj.$TextField
      if ($v -is [string] -and -not [string]::IsNullOrWhiteSpace($v)) {
        $texts.Add($v) | Out-Null
      }
    } catch {
      # ignore malformed lines
    }
  }
  return @($texts)
}

function Read-RecursiveJsonArrayText {
  param(
    [string]$RootPath,
    [string]$Filter,
    [string]$TextField
  )
  $texts = New-Object System.Collections.Generic.List[string]
  if (-not (Test-Path $RootPath)) { return @($texts) }
  $files = Get-ChildItem -Path $RootPath -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue
  foreach ($f in $files) {
    try {
      $arr = Get-Content -Raw -Path $f.FullName | ConvertFrom-Json
      foreach ($item in @($arr)) {
        $v = $item.$TextField
        if ($v -is [string] -and -not [string]::IsNullOrWhiteSpace($v)) {
          $texts.Add($v) | Out-Null
        }
      }
    } catch {
      # ignore malformed files
    }
  }
  return @($texts)
}

if (-not (Test-Path $sharedSkillsPath)) {
  Add-Finding -Severity 'blocking' -Id 'shared-skills-missing' -Message 'Shared skills directory is missing.' -Paths @($sharedSkillsPath) -Fix 'Restore ~/.agents/skills before running governance audit.'
}

$sharedSkills = Get-SharedSkills -Path $sharedSkillsPath
if ($sharedSkills.Count -eq 0) {
  Add-Finding -Severity 'blocking' -Id 'shared-skills-empty' -Message 'No shared skills found under ~/.agents/skills.' -Paths @($sharedSkillsPath) -Fix 'Add skills with SKILL.md into shared directory.'
}

$usage = @{}
$patterns = @{}
foreach ($skill in $sharedSkills) {
  $usage[$skill] = [ordered]@{
    total = 0
    byClient = [ordered]@{
      claude = 0
      cursor = 0
      gemini = 0
      codex = 0
    }
  }
  $escaped = [regex]::Escape($skill)
  $patterns[$skill] = "(?i)(?<![a-z0-9-])$escaped(?![a-z0-9-])"
}

$clientStats = [ordered]@{}
$sharedSet = @{}
foreach ($s in $sharedSkills) { $sharedSet[$s] = $true }

foreach ($client in $clientDefs) {
  $exists = Test-Path $client.skillsPath
  $names = @()
  if ($exists) {
    $names = @((Get-ChildItem -Path $client.skillsPath -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) | Sort-Object)
  }
  $dedicated = New-Object System.Collections.Generic.List[string]
  foreach ($n in $names) {
    if (-not $sharedSet.ContainsKey($n)) {
      $dedicated.Add($n) | Out-Null
    }
  }
  $clientStats[$client.name] = [ordered]@{
    exists = $exists
    count = $names.Count
    dedicated = @($dedicated | Sort-Object)
  }
}

$logSources = @()
$totalMessagesScanned = 0

foreach ($client in $clientDefs) {
  foreach ($log in $client.logs) {
    $sourceObj = [ordered]@{
      client = $client.name
      path = $log.path
      type = $log.type
      status = 'ok'
      messages = 0
      note = ''
    }

    $texts = @()
    if ($log.type -eq 'jsonl') {
      $texts = Read-JsonLinesText -Path $log.path -TextField $log.textField
      if (-not (Test-Path $log.path)) {
        $sourceObj.status = 'missing'
      }
    } elseif ($log.type -eq 'json-array-recursive') {
      $texts = Read-RecursiveJsonArrayText -RootPath $log.path -Filter $log.filter -TextField $log.textField
      if (-not (Test-Path $log.path)) {
        $sourceObj.status = 'missing'
      }
    } elseif ($log.type -eq 'sqlite') {
      if (Test-Path $log.path) {
        $sourceObj.status = 'unparsed'
        $sourceObj.note = 'SQLite log detected but parser is unavailable in current environment.'
        Add-Finding -Severity 'info' -Id 'usage-log-unparsed' -Message "Usage log not parsed for $($client.name): sqlite source is unavailable." -Paths @($log.path) -Fix 'Install sqlite parser support or export cursor log to JSON for usage counting.'
      } else {
        $sourceObj.status = 'missing'
      }
    }

    foreach ($text in $texts) {
      foreach ($skill in $sharedSkills) {
        if ([regex]::IsMatch($text, $patterns[$skill])) {
          $usage[$skill].total++
          $usage[$skill].byClient[$client.name]++
        }
      }
    }

    $sourceObj.messages = $texts.Count
    $totalMessagesScanned += $texts.Count
    $logSources += [pscustomobject]$sourceObj
  }
}

$baseAudit = $null
if (Test-Path $baseAuditScript) {
  try {
    $baseAuditRaw = & $baseAuditScript -Format json
    $baseAudit = $baseAuditRaw | ConvertFrom-Json
  } catch {
    Add-Finding -Severity 'warning' -Id 'base-audit-failed' -Message 'Failed to execute base governance audit script.' -Paths @($baseAuditScript) -Fix 'Check ~/.agents/tools/skills-audit.ps1 syntax and execution policy.'
  }
} else {
  Add-Finding -Severity 'warning' -Id 'base-audit-missing' -Message 'Base governance audit script is missing.' -Paths @($baseAuditScript) -Fix 'Restore ~/.agents/tools/skills-audit.ps1.'
}

if ($baseAudit -and $baseAudit.Findings) {
  foreach ($f in @($baseAudit.Findings)) {
    Add-Finding -Severity $f.severity -Id $f.id -Message $f.message -Paths @($f.paths) -Fix $f.fix
  }
}

$usageRows = @(
  $sharedSkills | ForEach-Object {
    [pscustomobject]@{
      name = $_
      total = [int]$usage[$_].total
      claude = [int]$usage[$_].byClient.claude
      cursor = [int]$usage[$_].byClient.cursor
      gemini = [int]$usage[$_].byClient.gemini
      codex = [int]$usage[$_].byClient.codex
    }
  } | Sort-Object total, name -Descending
)

$removalCandidates = @(
  $usageRows |
    Where-Object { $_.total -eq 0 -and ($protectedSkills -notcontains $_.name) } |
    ForEach-Object { $_.name } |
    Sort-Object
)

$lowUsageCandidates = @(
  $usageRows |
    Where-Object { $_.total -gt 0 -and $_.total -lt $MinUsageToKeep -and ($protectedSkills -notcontains $_.name) } |
    ForEach-Object { $_.name } |
    Sort-Object
)

if ($removalCandidates.Count -gt 0) {
  Add-Finding -Severity 'warning' -Id 'usage-zero-candidates' -Message "Found $($removalCandidates.Count) zero-usage skill candidates for pruning." -Paths @($sharedSkillsPath) -Fix 'Review Suggested Removals and remove unneeded skills from shared source.'
}
if ($lowUsageCandidates.Count -gt 0) {
  Add-Finding -Severity 'info' -Id 'usage-low-candidates' -Message "Found $($lowUsageCandidates.Count) low-usage skills below threshold $MinUsageToKeep." -Paths @($sharedSkillsPath) -Fix 'Review low-usage list and merge or deprecate overlaps.'
}

$blockingCount = @($findings | Where-Object { $_.severity -eq 'blocking' }).Count
$warningCount = @($findings | Where-Object { $_.severity -eq 'warning' }).Count
$infoCount = @($findings | Where-Object { $_.severity -eq 'info' }).Count
$findingsArray = @($findings.ToArray())
$suggestedExitCode = 0
if ($blockingCount -gt 0 -or ($Strict.IsPresent -and $warningCount -gt 0)) {
  $suggestedExitCode = 1
}

$summary = [pscustomobject]@{
  checkedAt = (Get-Date).ToString('s')
  sharedSkills = $sharedSkills.Count
  clientsFound = @($clientStats.Keys | Where-Object { $clientStats[$_].exists }).Count
  clientsMissing = @($clientStats.Keys | Where-Object { -not $clientStats[$_].exists }).Count
  totalMessagesScanned = $totalMessagesScanned
  findings = [pscustomobject]@{
    total = $findings.Count
    blocking = $blockingCount
    warning = $warningCount
    info = $infoCount
  }
  strict = $Strict.IsPresent
}

$suggestedFixes = @($findings | Where-Object { -not [string]::IsNullOrWhiteSpace($_.fix) } | Select-Object -ExpandProperty fix -Unique)
$syncReminder = (@(
  22914,23545,25216,33021,26377,22686,21024,25913,31561,25805,20316,65292,35831,36755,20837,8220,
  21516,27493,25216,33021,8221,26469,35843,29992,25191,34892,8220,20840,23616,25216,33021,21516,
  27493,25216,33021,8221,20197,21516,27493,21040,25152,26377,23458,25143,31471,24182,23436,25104,
  19968,33268,24615,26657,39564,12290
) | ForEach-Object { [char]$_ }) -join ''
$jsonResult = @{}
$jsonResult['Summary'] = $summary
$jsonResult['ClientSkillCounts'] = $clientStats
$jsonResult['UsageLogSources'] = @($logSources)
$jsonResult['SkillUsage'] = @($usageRows)
$jsonResult['SuggestedRemovals'] = @{
  zeroUsage = @($removalCandidates)
  lowUsage = @($lowUsageCandidates)
  protectedSkills = @($protectedSkills)
  minUsageThreshold = $MinUsageToKeep
}
$jsonResult['Findings'] = $findingsArray
$jsonResult['Severity'] = @{
  blocking = $blockingCount
  warning = $warningCount
  info = $infoCount
}
$jsonResult['SuggestedFixes'] = @($suggestedFixes)
$jsonResult['SuggestedExitCode'] = $suggestedExitCode
$jsonResult['Reminder'] = $syncReminder

if ($Format -eq 'json') {
  $jsonResult | ConvertTo-Json -Depth 10
  exit 0
}

Write-Output '## Summary'
Write-Output "- CheckedAt: $($summary.checkedAt)"
Write-Output "- Shared skills: $($summary.sharedSkills)"
Write-Output "- Clients: found=$($summary.clientsFound), missing=$($summary.clientsMissing)"
Write-Output "- Messages scanned for usage: $($summary.totalMessagesScanned)"
Write-Output "- Findings: total=$($summary.findings.total), blocking=$blockingCount, warning=$warningCount, info=$infoCount"
Write-Output "- Strict: $($summary.strict)"
Write-Output ''

Write-Output '## Client Skill Counts'
foreach ($name in $clientStats.Keys) {
  $c = $clientStats[$name]
  $ded = if ($c.dedicated.Count -gt 0) { $c.dedicated -join ', ' } else { 'none' }
  Write-Output "- ${name}: exists=$($c.exists), count=$($c.count), dedicated=$ded"
}
Write-Output ''

Write-Output '## Usage Log Sources'
foreach ($src in $logSources) {
  $note = if ([string]::IsNullOrWhiteSpace($src.note)) { '' } else { ", note=$($src.note)" }
  Write-Output "- $($src.client): type=$($src.type), status=$($src.status), messages=$($src.messages), path=$($src.path)$note"
}
Write-Output ''

Write-Output '## Skill Usage Counts'
foreach ($row in $usageRows) {
  Write-Output "- $($row.name): total=$($row.total), claude=$($row.claude), cursor=$($row.cursor), gemini=$($row.gemini), codex=$($row.codex)"
}
Write-Output ''

Write-Output '## Suggested Removals'
if ($removalCandidates.Count -eq 0) {
  Write-Output '- zeroUsage: none'
} else {
  Write-Output "- zeroUsage: $($removalCandidates -join ', ')"
}
if ($lowUsageCandidates.Count -eq 0) {
  Write-Output '- lowUsage: none'
} else {
  Write-Output "- lowUsage(<$MinUsageToKeep): $($lowUsageCandidates -join ', ')"
}
Write-Output "- protected: $($protectedSkills -join ', ')"
Write-Output ''

Write-Output '## Findings'
if ($findings.Count -eq 0) {
  Write-Output '- No issues.'
} else {
  $idx = 1
  foreach ($f in $findings) {
    $sev = $f.severity.ToUpperInvariant()
    $pathsText = if ($f.paths.Count -gt 0) { ' | paths: ' + ($f.paths -join '; ') } else { '' }
    Write-Output "$idx. [$sev] $($f.message)$pathsText"
    $idx++
  }
}
Write-Output ''

Write-Output '## Severity'
Write-Output "- Blocking: $blockingCount"
Write-Output "- Warning: $warningCount"
Write-Output "- Info: $infoCount"
Write-Output ''

Write-Output '## Suggested Fixes'
$fixes = @($suggestedFixes)
if ($fixes.Count -eq 0) {
  Write-Output '- None.'
} else {
  foreach ($fx in $fixes) {
    Write-Output "- $fx"
  }
}
Write-Output ''
Write-Output "Suggested exit code: $suggestedExitCode"
Write-Output $syncReminder
