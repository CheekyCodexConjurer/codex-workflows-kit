@echo off
set "npm_config_min_release_age=0"
set "AGENT_MODEL=opencode-go/deepseek-v4-flash"
set "AGENT_EFFORT=max"
where npx.cmd >nul 2>&1
if errorlevel 1 (
    echo npx.cmd was not found on PATH. Install Node.js and reopen the terminal. 1>&2
    exit /b 1
)
call npx.cmd %*
exit /b %ERRORLEVEL%
