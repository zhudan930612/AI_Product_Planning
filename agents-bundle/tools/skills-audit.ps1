param(
  [ValidateSet('markdown', 'json')]
  [string]$Format = 'markdown',
  [switch]$Strict
)

$ErrorActionPreference = 'Stop'

$agentsRoot = 'C:/Users/zhudan/.agents'
$agentsSkills = Join-Path $agentsRoot 'skills'
$manifestPath = Join-Path $agentsRoot 'skills-manifest.json'
$lockPath = Join-Path $agentsRoot '.skill-lock.json'
$claudeSkills = 'C:/Users/zhudan/.claude/skills'
$cursorSkills = 'C:/Users/zhudan/.cursor/skills'
$geminiSkills = 'C:/Users/zhudan/.gemini/skills'
$codexSkills = 'C:/Users/zhudan/.codex/skills'

$findings = New-Object System.Collections.Generic.List[object]

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

function Normalize-Path {
  param([string]$PathValue)
  if ([string]::IsNullOrWhiteSpace($PathValue)) { return '' }
  try {
    return [IO.Path]::GetFullPath($PathValue).TrimEnd('\')
  } catch {
    return $PathValue.TrimEnd('\')
  }
}

function Has-SkillMd {
  param([string]$SkillDir)
  return (Test-Path (Join-Path $SkillDir 'SKILL.md'))
}

$manifest = $null
$lock = $null

if (-not (Test-Path $manifestPath)) {
  Add-Finding -Severity 'blocking' -Id 'manifest-missing' -Message 'Missing skills-manifest.json.' -Paths @($manifestPath) -Fix 'Create and maintain the shared manifest file.'
} else {
  $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
}

if (Test-Path $lockPath) {
  $lock = Get-Content -Raw $lockPath | ConvertFrom-Json
} else {
  Add-Finding -Severity 'warning' -Id 'lock-missing' -Message 'Missing .skill-lock.json.' -Paths @($lockPath) -Fix 'Restore the lock file and include it in the update workflow.'
}

$shared = @()
$codexOnly = @()
$manifestNames = @()

if ($manifest) {
  $shared = @($manifest.skills | Where-Object { $_.scope -eq 'shared' -and $_.status -ne 'deprecated' } | ForEach-Object { $_.name })
  $codexOnly = @($manifest.skills | Where-Object { $_.scope -eq 'codex-only' -and $_.status -ne 'deprecated' } | ForEach-Object { $_.name })
  $manifestNames = @($manifest.skills | ForEach-Object { $_.name })

  foreach ($name in $shared) {
    $p = Join-Path $agentsSkills $name
    if (-not (Test-Path $p)) {
      Add-Finding -Severity 'blocking' -Id 'shared-missing' -Message "Shared skill missing: $name" -Paths @($p) -Fix 'Restore this skill under ~/.agents/skills.'
      continue
    }
    if (-not (Has-SkillMd $p)) {
      Add-Finding -Severity 'blocking' -Id 'shared-no-skillmd' -Message "Shared skill missing SKILL.md: $name" -Paths @($p) -Fix 'Add SKILL.md in the skill directory.'
    }
  }

  $agentsExisting = @((Get-ChildItem -Path $agentsSkills -Directory -Force -ErrorAction SilentlyContinue) | ForEach-Object { $_.Name })
  foreach ($name in $agentsExisting) {
    if ($manifestNames -notcontains $name) {
      Add-Finding -Severity 'warning' -Id 'manifest-missing-entry' -Message "Skill exists in shared root but not manifest: $name" -Paths @(Join-Path $agentsSkills $name) -Fix 'Add it to skills-manifest.json or remove it.'
    }
  }
}

function Audit-ClientLinks {
  param(
    [string]$ClientName,
    [string]$ClientPath,
    [string[]]$ExpectedShared,
    [string]$SharedRoot,
    [string[]]$AllowedExtraNames = @()
  )

  foreach ($name in $ExpectedShared) {
    $linkPath = Join-Path $ClientPath $name
    if (-not (Test-Path $linkPath)) {
      Add-Finding -Severity 'blocking' -Id 'client-link-missing' -Message "$ClientName missing shared link: $name" -Paths @($linkPath) -Fix "Run skills-sync.ps1 to rebuild $ClientName links."
      continue
    }

    $item = Get-Item -Force $linkPath
    if ($item.LinkType -ne 'Junction') {
      Add-Finding -Severity 'blocking' -Id 'client-not-junction' -Message "$ClientName entry is not a Junction: $name" -Paths @($linkPath) -Fix 'Replace it with a Junction to shared root.'
      continue
    }

    $target = ($item.Target | Select-Object -First 1)
    if (-not $target -or -not (Test-Path $target)) {
      Add-Finding -Severity 'blocking' -Id 'client-broken-junction' -Message "$ClientName has a broken Junction: $name" -Paths @($linkPath) -Fix 'Fix target path and rerun skills-sync.ps1.'
      continue
    }

    $expected = Join-Path $SharedRoot $name
    if ((Normalize-Path $target) -ine (Normalize-Path $expected)) {
      Add-Finding -Severity 'blocking' -Id 'client-wrong-target' -Message "$ClientName points to wrong target: $name" -Paths @($linkPath, $target, $expected) -Fix 'Recreate the Junction to shared root.'
    }

    if (-not (Has-SkillMd $linkPath)) {
      Add-Finding -Severity 'blocking' -Id 'client-no-skillmd' -Message "$ClientName skill missing SKILL.md: $name" -Paths @($linkPath) -Fix 'Fix SKILL.md in the shared source skill.'
    }
  }

  $existing = Get-ChildItem -Path $ClientPath -Directory -Force -ErrorAction SilentlyContinue
  foreach ($item in $existing) {
    if (($ExpectedShared -notcontains $item.Name) -and ($AllowedExtraNames -notcontains $item.Name)) {
      Add-Finding -Severity 'warning' -Id 'client-extra-skill' -Message "$ClientName has unmanaged skill: $($item.Name)" -Paths @($item.FullName) -Fix 'Add it to manifest or remove it.'
    }
  }
}

if ($manifest) {
  Audit-ClientLinks -ClientName 'Claude' -ClientPath $claudeSkills -ExpectedShared $shared -SharedRoot $agentsSkills
  Audit-ClientLinks -ClientName 'Cursor' -ClientPath $cursorSkills -ExpectedShared $shared -SharedRoot $agentsSkills
  Audit-ClientLinks -ClientName 'Gemini' -ClientPath $geminiSkills -ExpectedShared $shared -SharedRoot $agentsSkills
  Audit-ClientLinks -ClientName 'Codex' -ClientPath $codexSkills -ExpectedShared $shared -SharedRoot $agentsSkills -AllowedExtraNames (@('.system') + $codexOnly)
}

# Detect duplicate names mapped to multiple physical sources
$roots = @($agentsSkills, $claudeSkills, $cursorSkills, $geminiSkills, $codexSkills)
$records = New-Object System.Collections.Generic.List[object]
foreach ($root in $roots) {
  if (-not (Test-Path $root)) { continue }
  $items = Get-ChildItem -Path $root -Directory -Force -ErrorAction SilentlyContinue
  foreach ($item in $items) {
    $source = $item.FullName
    if ($item.LinkType -eq 'Junction') {
      $target = ($item.Target | Select-Object -First 1)
      if ($target) { $source = $target }
    }
    $records.Add([pscustomobject]@{
        name = $item.Name
        source = (Normalize-Path $source)
        path = $item.FullName
      }) | Out-Null
  }
}

$groups = $records | Group-Object name
foreach ($g in $groups) {
  $distinctSources = @($g.Group | Select-Object -ExpandProperty source -Unique)
  if ($distinctSources.Count -gt 1) {
    $paths = @($g.Group | Select-Object -ExpandProperty path)
    Add-Finding -Severity 'blocking' -Id 'duplicate-multi-source' -Message "Skill has multiple physical sources: $($g.Name)" -Paths $paths -Fix 'Keep one source and use Junctions for all client views.'
  }
}

if ($manifest) {
  foreach ($name in $codexOnly) {
    $leak = Join-Path $agentsSkills $name
    if (Test-Path $leak) {
      Add-Finding -Severity 'blocking' -Id 'codex-only-leak' -Message "codex-only leaked into shared root: $name" -Paths @($leak) -Fix 'Move this skill out of shared root.'
    }
  }

  $allowCodex = @('.system') + $codexOnly + $shared
  $codexItems = Get-ChildItem -Path $codexSkills -Directory -Force -ErrorAction SilentlyContinue
  foreach ($item in $codexItems) {
    if ($allowCodex -notcontains $item.Name) {
      Add-Finding -Severity 'blocking' -Id 'codex-extra' -Message "Codex has unmanaged skill: $($item.Name)" -Paths @($item.FullName) -Fix 'Remove this directory from ~/.codex/skills or add it to manifest.'
    }
  }

  foreach ($name in $codexOnly) {
    $p = Join-Path $codexSkills $name
    if (-not (Test-Path $p)) {
      Add-Finding -Severity 'warning' -Id 'codex-only-missing' -Message "codex-only skill missing: $name" -Paths @($p) -Fix 'Restore it under ~/.codex/skills or adjust manifest scope.'
      continue
    }
    if (-not (Has-SkillMd $p)) {
      Add-Finding -Severity 'blocking' -Id 'codex-only-no-skillmd' -Message "codex-only skill missing SKILL.md: $name" -Paths @($p) -Fix 'Add SKILL.md in this codex-only skill.'
    }
  }
}

if ($manifest -and $lock) {
  $lockNames = @($lock.skills.PSObject.Properties.Name)
  foreach ($name in $shared) {
    $entry = $manifest.skills | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($entry -and ($entry.source -like 'lock:*') -and ($lockNames -notcontains $name)) {
      Add-Finding -Severity 'warning' -Id 'manifest-lock-drift' -Message "Manifest expects lock source but lock entry is missing: $name" -Paths @($manifestPath, $lockPath) -Fix 'Add lock entry or change source field in manifest.'
    }
  }
  foreach ($name in $lockNames) {
    if ($manifestNames -notcontains $name) {
      Add-Finding -Severity 'warning' -Id 'lock-unmanaged' -Message "Lock contains unmanaged skill: $name" -Paths @($lockPath) -Fix 'Add to manifest or remove stale lock entry.'
    }
  }
}

$blockingCount = @($findings | Where-Object { $_.severity -eq 'blocking' }).Count
$warningCount = @($findings | Where-Object { $_.severity -eq 'warning' }).Count
$infoCount = @($findings | Where-Object { $_.severity -eq 'info' }).Count

$suggestedFixes = @($findings | Where-Object { -not [string]::IsNullOrWhiteSpace($_.fix) } | Select-Object -ExpandProperty fix -Unique)
$suggestedExitCode = 0
if ($blockingCount -gt 0 -or ($Strict.IsPresent -and $warningCount -gt 0)) {
  $suggestedExitCode = 1
}

$summary = [pscustomobject]@{
  checkedAt = (Get-Date).ToString('s')
  blocking = $blockingCount
  warning = $warningCount
  info = $infoCount
  total = $findings.Count
  strict = $Strict.IsPresent
}

if ($Format -eq 'json') {
  $summaryObj = New-Object PSObject
  $summaryObj | Add-Member -NotePropertyName checkedAt -NotePropertyValue $summary.checkedAt
  $summaryObj | Add-Member -NotePropertyName blocking -NotePropertyValue $blockingCount
  $summaryObj | Add-Member -NotePropertyName warning -NotePropertyValue $warningCount
  $summaryObj | Add-Member -NotePropertyName info -NotePropertyValue $infoCount
  $summaryObj | Add-Member -NotePropertyName total -NotePropertyValue $summary.total
  $summaryObj | Add-Member -NotePropertyName strict -NotePropertyValue $summary.strict

  $severityObj = New-Object PSObject
  $severityObj | Add-Member -NotePropertyName blocking -NotePropertyValue $blockingCount
  $severityObj | Add-Member -NotePropertyName warning -NotePropertyValue $warningCount
  $severityObj | Add-Member -NotePropertyName info -NotePropertyValue $infoCount

  $findingsArr = @()
  foreach ($f in $findings) {
    $fo = New-Object PSObject
    $fo | Add-Member -NotePropertyName severity -NotePropertyValue $f.severity
    $fo | Add-Member -NotePropertyName id -NotePropertyValue $f.id
    $fo | Add-Member -NotePropertyName message -NotePropertyValue $f.message
    $fo | Add-Member -NotePropertyName paths -NotePropertyValue @($f.paths)
    $fo | Add-Member -NotePropertyName fix -NotePropertyValue $f.fix
    $findingsArr += $fo
  }

  $outputObj = New-Object PSObject
  $outputObj | Add-Member -NotePropertyName Summary -NotePropertyValue $summaryObj
  $outputObj | Add-Member -NotePropertyName Findings -NotePropertyValue $findingsArr
  $outputObj | Add-Member -NotePropertyName Severity -NotePropertyValue $severityObj
  $outputObj | Add-Member -NotePropertyName SuggestedFixes -NotePropertyValue @($suggestedFixes)
  $outputObj | Add-Member -NotePropertyName SuggestedExitCode -NotePropertyValue $suggestedExitCode

  $outputObj | ConvertTo-Json -Depth 8
  exit 0
}

Write-Output '## Summary'
Write-Output "- CheckedAt: $($summary.checkedAt)"
Write-Output "- Findings: total=$($summary.total), blocking=$blockingCount, warning=$warningCount, info=$infoCount"
Write-Output "- Strict: $($summary.strict)"
Write-Output ''
Write-Output '## Findings'
if ($findings.Count -eq 0) {
  Write-Output '- No issues.'
} else {
  $idx = 1
  foreach ($f in $findings) {
    $sevLabel = if ($f.severity -eq 'blocking') { 'BLOCKING' } elseif ($f.severity -eq 'warning') { 'WARNING' } else { 'INFO' }
    $pathsText = if ($f.paths.Count -gt 0) { ' | paths: ' + ($f.paths -join '; ') } else { '' }
    Write-Output "$idx. [$sevLabel] $($f.message)$pathsText"
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
if ($suggestedFixes.Count -eq 0) {
  Write-Output '- None.'
} else {
  foreach ($fix in $suggestedFixes) {
    Write-Output "- $fix"
  }
}
Write-Output ''
Write-Output "Suggested exit code: $suggestedExitCode"
