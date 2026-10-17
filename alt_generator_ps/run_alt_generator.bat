@echo off
chcp 65001 > nul
setlocal

echo ============================================
echo  ALT SQL 自動生成ツール
echo ============================================
echo.

REM --- モード選択 ---
echo 実行モードを選んでください:
echo   1. バージョン指定モード (例: v1.1.5)
echo   2. PR番号モード          (例: 42)
echo.
set /p MODE_CHOICE="番号を入力してください (1 or 2): "

if "%MODE_CHOICE%"=="1" goto VERSION_MODE
if "%MODE_CHOICE%"=="2" goto PR_MODE
echo 無効な入力です。1 または 2 を入力してください。
pause
exit /b 1

REM --- バージョン指定モード ---
:VERSION_MODE
echo.
set /p VERSION="バージョンを入力してください (例: v1.1.5): "
if "%VERSION%"=="" (
    echo バージョンが入力されていません。
    pause
    exit /b 1
)
set COMMAND=version
set TARGET=%VERSION%
goto INPUT_REPO

REM --- PR番号モード ---
:PR_MODE
echo.
set /p PR_NUM="PR番号を入力してください (例: 42): "
if "%PR_NUM%"=="" (
    echo PR番号が入力されていません。
    pause
    exit /b 1
)
set COMMAND=pr
set TARGET=%PR_NUM%
goto INPUT_REPO

REM --- リポジトリパス入力 ---
:INPUT_REPO
echo.
set DEFAULT_REPO=C:\Users\ta9ns\kumamoto-henno-map
set /p REPO_PATH="リポジトリのパスを入力してください (Enter でデフォルト: %DEFAULT_REPO%): "
if "%REPO_PATH%"=="" set REPO_PATH=%DEFAULT_REPO%

echo.
echo ============================================
echo 実行内容:
echo   モード    : %COMMAND%
echo   対象      : %TARGET%
echo   リポジトリ: %REPO_PATH%
echo ============================================
echo.

REM --- PowerShell スクリプト実行 ---
set PS_SCRIPT=%~dp0alt_generator.ps1

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %COMMAND% %TARGET% -RepoPath "%REPO_PATH%"

echo.
if %ERRORLEVEL% equ 0 (
    echo 完了しました。
) else (
    echo エラーが発生しました。
)

echo.
pause
endlocal
