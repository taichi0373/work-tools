#Requires -Version 5.1
<#
.SYNOPSIS
    ALT SQL 自動生成ツール 対話型ランチャー
    run_alt_generator.bat からダブルクリックで起動する用
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$PSScriptPath = Join-Path $PSScriptRoot "alt_generator.ps1"

Write-Host "============================================"
Write-Host " ALT SQL 自動生成ツール"
Write-Host "============================================"
Write-Host ""

# --- モード選択 ---
Write-Host "実行モードを選んでください:"
Write-Host "  1. バージョン指定モード (例: v1.1.5)"
Write-Host "  2. PR番号モード          (例: 42)"
Write-Host ""
$modeChoice = Read-Host "番号を入力してください (1 or 2)"

if ($modeChoice -eq "1") {
    Write-Host ""
    $target = Read-Host "バージョンを入力してください (例: v1.1.5)"
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host "バージョンが入力されていません。" -ForegroundColor Red
        exit 1
    }
    $command = "version"
}
elseif ($modeChoice -eq "2") {
    Write-Host ""
    $target = Read-Host "PR番号を入力してください (例: 42)"
    if ([string]::IsNullOrWhiteSpace($target)) {
        Write-Host "PR番号が入力されていません。" -ForegroundColor Red
        exit 1
    }
    $command = "pr"
}
else {
    Write-Host "無効な入力です。1 または 2 を入力してください。" -ForegroundColor Red
    exit 1
}

# --- リポジトリパス入力 ---
Write-Host ""
$defaultRepo = "C:\Users\ta9ns\kumamoto-henno-map"
$repoInput = Read-Host "リポジトリのパスを入力してください (Enter でデフォルト: $defaultRepo)"
if ([string]::IsNullOrWhiteSpace($repoInput)) {
    $repoPath = $defaultRepo
}
else {
    $repoPath = $repoInput
}

# --- 実行確認 ---
Write-Host ""
Write-Host "============================================"
Write-Host "実行内容:"
Write-Host "  モード    : $command"
Write-Host "  対象      : $target"
Write-Host "  リポジトリ: $repoPath"
Write-Host "============================================"
Write-Host ""

# --- 実行 ---
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSScriptPath $command $target -RepoPath $repoPath
    Write-Host ""
    Write-Host "完了しました。" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "エラーが発生しました: $_" -ForegroundColor Red
    exit 1
}
