param(
  [string]$BundlePath = (Join-Path $PSScriptRoot 'agents-bundle'),
  [switch]$SyncAfter
)

$ErrorActionPreference = 'Stop'

function Test-RequiredPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PathValue,
    [Parameter(Mandatory = $true)]
    [string]$Label
  )
  if (-not (Test-Path $PathValue)) {
    throw "$Label not found: $PathValue"
  }
}

$homeDir = [Environment]::GetFolderPath('UserProfile')
$agentsRoot = Join-Path $homeDir '.agents'
$skillsRoot = Join-Path $agentsRoot 'skills'
$toolsRoot = Join-Path $agentsRoot 'tools'
$manifestPath = Join-Path $agentsRoot 'skills-manifest.json'
$lockPath = Join-Path $agentsRoot '.skill-lock.json'

$bundleSkills = Join-Path $BundlePath 'skills'
$bundleTools = Join-Path $BundlePath 'tools'

Test-RequiredPath -PathValue $BundlePath -Label 'Bundle path'
Test-RequiredPath -PathValue $bundleSkills -Label 'Bundle skills directory'

New-Item -ItemType Directory -Force -Path $skillsRoot | Out-Null
New-Item -ItemType Directory -Force -Path $toolsRoot | Out-Null

Copy-Item -Recurse -Force (Join-Path $bundleSkills '*') $skillsRoot
if (Test-Path $bundleTools) {
  Copy-Item -Force (Join-Path $bundleTools '*.ps1') $toolsRoot -ErrorAction SilentlyContinue
}

# Compatibility fix: some environments may still use lower-case skill.md.
$skillSaverSkillMd = Join-Path $skillsRoot 'skill-saver/skill.md'
$skillSaverUpper = Join-Path $skillsRoot 'skill-saver/SKILL.md'
if ((Test-Path $skillSaverSkillMd) -and -not (Test-Path $skillSaverUpper)) {
  Rename-Item -Path $skillSaverSkillMd -NewName 'SKILL.md'
}

if (Test-Path $manifestPath) {
  $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
} else {
  $manifest = [pscustomobject]@{
    version = 1
    updatedAt = ''
    skills = @()
  }
}

if (Test-Path $lockPath) {
  $lock = Get-Content -Raw $lockPath | ConvertFrom-Json
} else {
  $lock = [pscustomobject]@{
    version = 3
    skills = [pscustomobject]@{}
  }
}

$skillDirs = Get-ChildItem -Path $skillsRoot -Directory -Force -ErrorAction SilentlyContinue
$registered = New-Object System.Collections.Generic.List[string]
$nowUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

foreach ($dir in $skillDirs) {
  $skillName = $dir.Name
  $skillMd = Join-Path $dir.FullName 'SKILL.md'
  if (-not (Test-Path $skillMd)) {
    continue
  }

  $manifest.skills = @($manifest.skills | Where-Object { $_.name -ne $skillName })
  $manifest.skills += [pscustomobject]@{
    name = $skillName
    scope = 'shared'
    source = 'local:managed'
    owner = 'shared'
    status = 'active'
  }

  $entry = [pscustomobject]@{
    source = "local:$($dir.FullName)"
    sourceType = 'local'
    sourceUrl = ''
    skillPath = 'SKILL.md'
    skillFolderHash = ''
    installedAt = $nowUtc
    updatedAt = $nowUtc
  }
  $lock.skills | Add-Member -MemberType NoteProperty -Name $skillName -Value $entry -Force
  $registered.Add($skillName) | Out-Null
}

$manifest.updatedAt = (Get-Date).ToString('s')
$manifest.skills = @($manifest.skills | Sort-Object name)
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding UTF8
$lock | ConvertTo-Json -Depth 12 | Set-Content -Path $lockPath -Encoding UTF8

$syncScript = Join-Path $skillsRoot 'global-skill-sync/scripts/global-skill-sync.ps1'
if ($SyncAfter -and (Test-Path $syncScript)) {
  & powershell -ExecutionPolicy Bypass -File $syncScript
}

Write-Output "Bootstrap done: $agentsRoot"
Write-Output "Skills registered: $($registered.Count)"
if ($registered.Count -gt 0) {
  Write-Output "Skill names: $($registered -join ', ')"
}
if (-not $SyncAfter) {
  Write-Output 'Next step: run "同步技能".'
}
