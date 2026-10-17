@echo off
rem 毎週木曜日 09:00 にIssueTrackerを自動実行するタスクを登録する
rem 管理者権限で実行する必要はありません（現在のユーザーで登録されます）

set TASK_NAME=IssueTracker_Weekly
set SCRIPT_PATH=%~dp0issue_tracker.ps1

echo タスクスケジューラに登録します...
echo タスク名: %TASK_NAME%
echo 実行タイミング: 毎週木曜日 09:00
echo スクリプト: %SCRIPT_PATH%
echo.

schtasks /create ^
  /tn "%TASK_NAME%" ^
  /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%SCRIPT_PATH%\" -Scheduled" ^
  /sc weekly ^
  /d THU ^
  /st 09:00 ^
  /f

if %ERRORLEVEL% equ 0 (
    echo.
    echo 登録完了しました。
    echo 確認: schtasks /query /tn "%TASK_NAME%" /fo list
) else (
    echo.
    echo 登録に失敗しました。
)

pause
