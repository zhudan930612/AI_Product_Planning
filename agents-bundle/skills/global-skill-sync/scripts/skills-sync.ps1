param(
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$homeDir = [Environment]::GetFolderPath('UserProfile')
$agentsRoot = Join-Path $homeDir '.agents'
$agentsSkills = Join-Path $agentsRoot 'skills'
$manifestPath = Join-Path $agentsRoot 'skills-manifest.json'
$claudeSkills = Join-Path $homeDir '.claude/skills'
$cursorSkills = Join-Path $homeDir '.cursor/skills'
$geminiSkills = Join-Path $homeDir '.gemini/skills'
$codexSkills = Join-Path $homeDir '.codex/skills'

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

$clientDefs = @(
  @{ name = 'Claude'; path = $claudeSkills; extras = @() },
  @{ name = 'Cursor'; path = $cursorSkills; extras = @() },
  @{ name = 'Gemini'; path = $geminiSkills; extras = @() },
  @{ name = 'Codex'; path = $codexSkills; extras = @('.system') + $codexOnly }
)

$syncedClients = New-Object System.Collections.Generic.List[string]
$skippedClients = New-Object System.Collections.Generic.List[string]

foreach ($client in $clientDefs) {
  if (-not (Test-Path $client.path)) {
    $skippedClients.Add($client.name) | Out-Null
    Write-Output "[SKIP] Missing client skills directory: $($client.name) -> $($client.path)"
    continue
  }

  Sync-Client -ClientPath $client.path -SharedNames $shared -AllowedExtraNames $client.extras
  $syncedClients.Add($client.name) | Out-Null
}

Write-Output "Sync completed. shared=$($shared.Count), codex-only=$($codexOnly.Count), dryRun=$($DryRun.IsPresent), synced=$(@($syncedClients).Count), skipped=$(@($skippedClients).Count)"
Write-Output "Synced clients: $(if ($syncedClients.Count -gt 0) { $syncedClients -join ', ' } else { 'none' })"
Write-Output "Skipped clients (missing dir): $(if ($skippedClients.Count -gt 0) { $skippedClients -join ', ' } else { 'none' })"


