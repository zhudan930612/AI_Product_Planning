param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$agentsRoot = 'C:/Users/zhudan/.agents'
$agentsSkills = Join-Path $agentsRoot 'skills'
$manifestPath = Join-Path $agentsRoot 'skills-manifest.json'
$claudeSkills = 'C:/Users/zhudan/.claude/skills'
$cursorSkills = 'C:/Users/zhudan/.cursor/skills'
$geminiSkills = 'C:/Users/zhudan/.gemini/skills'
$codexSkills = 'C:/Users/zhudan/.codex/skills'

function Invoke-Change {
  param(
    [string]$Message,
    [scriptblock]$Action
  )
  if ($DryRun) {
    Write-Output "[DRYRUN] $Message"
  } else {
    & $Action
    Write-Output "[APPLY] $Message"
  }
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

function Ensure-DirLink {
  param(
    [string]$LinkPath,
    [string]$TargetPath
  )

  if (-not (Test-Path $TargetPath)) {
    Write-Warning "Target missing, skip link: $TargetPath"
    return
  }

  $existingItem = Get-Item -Force $LinkPath -ErrorAction SilentlyContinue
  if ($existingItem) {
    $ok = $false
    if ($existingItem.LinkType -eq 'Junction') {
      $target = ($existingItem.Target | Select-Object -First 1)
      if ($target) {
        $ok = (Normalize-Path $target) -ieq (Normalize-Path $TargetPath)
      }
    }
    if ($ok) {
      return
    }
    Invoke-Change "Remove existing $LinkPath" { Remove-Item -Recurse -Force $LinkPath }
  }

  Invoke-Change "Create junction $LinkPath -> $TargetPath" {
    New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
  }
}

function Sync-Client {
  param(
    [string]$ClientPath,
    [string[]]$SharedNames,
    [string[]]$AllowedExtraNames = @()
  )

  if (-not (Test-Path $ClientPath)) {
    Invoke-Change "Create client directory $ClientPath" { New-Item -ItemType Directory -Force -Path $ClientPath | Out-Null }
  }

  $existing = Get-ChildItem -Path $ClientPath -Directory -Force -ErrorAction SilentlyContinue
  foreach ($item in $existing) {
    if (($SharedNames -notcontains $item.Name) -and ($AllowedExtraNames -notcontains $item.Name)) {
      Invoke-Change "Remove extra client skill $($item.FullName)" { Remove-Item -Recurse -Force $item.FullName }
    }
  }

  foreach ($name in $SharedNames) {
    $target = Join-Path $agentsSkills $name
    $link = Join-Path $ClientPath $name
    Ensure-DirLink -LinkPath $link -TargetPath $target
  }
}

if (-not (Test-Path $manifestPath)) {
  throw "Manifest not found: $manifestPath"
}

$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
$shared = @($manifest.skills | Where-Object { $_.scope -eq 'shared' -and $_.status -ne 'deprecated' } | ForEach-Object { $_.name })
$codexOnly = @($manifest.skills | Where-Object { $_.scope -eq 'codex-only' -and $_.status -ne 'deprecated' } | ForEach-Object { $_.name })

Sync-Client -ClientPath $claudeSkills -SharedNames $shared
Sync-Client -ClientPath $cursorSkills -SharedNames $shared
Sync-Client -ClientPath $geminiSkills -SharedNames $shared
Sync-Client -ClientPath $codexSkills -SharedNames $shared -AllowedExtraNames (@('.system') + $codexOnly)

Write-Output "Sync completed. shared=$($shared.Count), codex-only=$($codexOnly.Count), dryRun=$($DryRun.IsPresent)"
