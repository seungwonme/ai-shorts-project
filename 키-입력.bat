@echo off
rem Opens (and first creates, if missing) the .env file where you paste your API keys.
rem This file is saved as UTF-8 without BOM. chcp 65001 below makes the Korean text readable.
chcp 65001 >nul
setlocal
cd /d "%~dp0"
echo.
echo ==== 키 입력 (API 키를 붙여 넣는 파일을 엽니다) ====
echo.
if exist ".env" goto open_env
if not exist "env-template.txt" goto no_template
copy "env-template.txt" ".env" >nul
if errorlevel 1 goto copy_failed
echo .env 파일을 새로 만들었습니다.
goto open_env

:open_env
echo 메모장이 열리면 해당 줄의 = 바로 뒤에 키를 붙여 넣으세요.
echo (나레이션 목소리는 TYPECAST_API_KEY 줄이 기본이고, ELEVENLABS_API_KEY 줄은 백업이라 비워 둬도 됩니다.)
echo.
start /wait "" notepad.exe ".env"
echo.
echo ----------------------------------------------------------------
echo 키를 = 뒤에 붙여 넣고 저장(Ctrl+S) 한 뒤 메모장을 닫으셨다면 끝입니다.
echo 이 파일은 남에게 보내지 마세요. (메일, 카카오톡, 캡처, Codex 대화창 모두 안 됩니다.)
echo 폴더를 zip으로 보낼 때도 .env 파일은 빼 주세요.
echo ----------------------------------------------------------------
goto done

:no_template
echo env-template.txt 파일을 찾지 못했습니다. 이 파일을 실습 폴더 안에서 실행했는지 확인해 주세요.
goto done

:copy_failed
echo .env 파일을 만들지 못했습니다. 폴더에 쓸 수 있는 권한이 있는지 확인해 주세요.
goto done

:done
echo.
pause
exit /b 0
