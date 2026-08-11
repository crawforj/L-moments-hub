#!/usr/bin/env pwsh
# =============================================================================
# run_ad_hoc_tranches.ps1  —  Unattended, resumable NID fleet runner (Windows)
#
# Loops `Rscript run_nid_tranche.R`, committing + pushing progress after every
# tranche, until a stop time or a STOP_TRANCHES sentinel file appears. This is
# the desktop/ad-hoc complement to the nightly cloud cron described in
# CLAUDE.md -- see docs/batch_runs_guide.md for the full write-up (safety
# checklist, how to watch it, how to stop it, how to recover from a bad run).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File run_ad_hoc_tranches.ps1
#   powershell -ExecutionPolicy Bypass -File run_ad_hoc_tranches.ps1 -TrancheSize 150 -StopAt "18:00"
#
# To stop early: close the window, or `New-Item STOP_TRANCHES` in this
# directory (checked after each tranche finishes and commits).
# =============================================================================
param(
  [int]$TrancheSize = 300,    # facilities per round; smaller = more frequent
                               # checkpoints, larger = less per-round overhead
  [string]$StopAt = "07:00",  # HH:mm, 24h clock. If that time has already
                               # passed today, stops at that time TOMORROW.
  [string]$Branch = "claude/desktop-nid-ad-hoc",
  [string]$RepoRoot = "C:\dev\L-moments-hub"
)

$ErrorActionPreference = "Continue"
$env:PATH += ";C:\Program Files\R\R-4.5.1\bin"
$env:LMC_TRANCHE = "$TrancheSize"
Set-Location $RepoRoot

$parsed = [datetime]::ParseExact($StopAt, "HH:mm", $null)
$stopAtToday = Get-Date -Hour $parsed.Hour -Minute $parsed.Minute -Second 0
$stopAt = if ($stopAtToday -gt (Get-Date)) { $stopAtToday } else { $stopAtToday.AddDays(1) }

Write-Host "=== L-moments-hub ad-hoc NID tranche runner ===" -ForegroundColor Cyan
Write-Host "Branch: $Branch | Tranche size: $TrancheSize | Auto-stop by: $stopAt`n"

$fallback = Select-String -Path "config\como.yml" -Pattern "use_local_fallback:\s*true" -Quiet
if ($fallback) {
  Write-Host "WARNING: config/como.yml has use_local_fallback: true -- a GHCN failure" -ForegroundColor Red
  Write-Host "will silently substitute SYNTHETIC data and still record 'ok'. Set it to" -ForegroundColor Red
  Write-Host "false before an unattended run whose results might be reviewed. See" -ForegroundColor Red
  Write-Host "docs/batch_runs_guide.md, 'Never run unattended with synthetic fallback on'.`n" -ForegroundColor Red
}

$round = 0
while ($true) {
  $round++
  $now = Get-Date
  if ($now -ge $stopAt) {
    Write-Host "`n[$now] Reached auto-stop time ($stopAt). Stopping cleanly." -ForegroundColor Yellow
    break
  }
  Write-Host "`n----- Round $round starting at $now -----" -ForegroundColor Cyan

  Rscript run_nid_tranche.R

  $doneCheck = Select-String -Path "data\nid_progress\progress.md" -Pattern "Facilities attempted" -ErrorAction SilentlyContinue
  Write-Host "`n$($doneCheck.Line)" -ForegroundColor Green

  git add data/nid_progress/ data/ghcn_prcp_cache/ 2>&1 | Out-Null
  $changed = git status --porcelain data/nid_progress/ data/ghcn_prcp_cache/
  if ($changed) {
    $msg = "NID ad-hoc tranche (round $round): $($doneCheck.Line)"
    git commit -q -m $msg 2>&1 | Out-Null
    git push -q origin $Branch 2>&1 | Out-Null
    Write-Host "Committed and pushed round $round to $Branch." -ForegroundColor Green
  } else {
    Write-Host "No progress-file changes to commit this round (manifest may be complete, or this round found nothing new)." -ForegroundColor Yellow
  }

  if (Select-String -Path "data\nid_progress\progress.md" -Pattern "All NID facilities complete" -Quiet -ErrorAction SilentlyContinue) {
    Write-Host "Full NID fleet complete. Stopping." -ForegroundColor Green
    break
  }
  if (Test-Path (Join-Path $RepoRoot "STOP_TRANCHES")) {
    Write-Host "STOP_TRANCHES file found. Stopping." -ForegroundColor Yellow
    Remove-Item (Join-Path $RepoRoot "STOP_TRANCHES") -Force
    break
  }
}

Write-Host "`n=== Ad-hoc tranche runner finished. Window will stay open -- press Enter to close. ===" -ForegroundColor Cyan
Read-Host
