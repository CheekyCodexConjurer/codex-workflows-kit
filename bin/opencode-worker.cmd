@echo off
set "npm_config_min_release_age=0"
set "OPENCODE_PROVIDER_VALID=0"
if /I "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%"=="go" set "OPENCODE_PROVIDER_VALID=1"
if /I "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%"=="zen" set "OPENCODE_PROVIDER_VALID=1"
if "%OPENCODE_PROVIDER_VALID%"=="0" (
    if not "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%"=="" (
        echo Invalid CODEX_WORKFLOWS_OPENCODE_PROVIDER "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%": allowed values are go and zen. 1>&2
        exit /b 1
    )
    if "%AGENT_MODEL%"=="" set "AGENT_MODEL=opencode-go/deepseek-v4-flash"
)
if /I "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%"=="go" set "AGENT_MODEL=opencode-go/deepseek-v4-flash"
if /I "%CODEX_WORKFLOWS_OPENCODE_PROVIDER%"=="zen" set "AGENT_MODEL=zenmux/deepseek/deepseek-v4-flash"
set "AGENT_EFFORT=max"
set "CFG_AGENTS_DIR=%AGENTS_DIR%"
if "%CFG_AGENTS_DIR%"=="" if not "%CODEX_HOME%"=="" set "CFG_AGENTS_DIR=%CODEX_HOME%\opencode-agents"
if "%CFG_AGENTS_DIR%"=="" set "CFG_AGENTS_DIR=%USERPROFILE%\.codex\opencode-agents"
set "CFG_AGENTS_DIR=%CFG_AGENTS_DIR:\=\\%"
set "CFG_SKILLS_DIR=%USERPROFILE%\.agents\skills\workflows"
if not "%AGENTS_HOME%"=="" set "CFG_SKILLS_DIR=%AGENTS_HOME%\skills\workflows"
set "CFG_SKILLS_DIR=%CFG_SKILLS_DIR:\=\\%"
set OPENCODE_CONFIG_CONTENT={"permission":{"*":"allow","doom_loop":"allow","external_directory":{"%CFG_AGENTS_DIR%":"allow","%CFG_SKILLS_DIR%":"allow"},"question":"deny","plan_enter":"deny","plan_exit":"deny"}}
where npx.cmd >nul 2>&1
if errorlevel 1 (
    echo npx.cmd was not found on PATH. Install Node.js and reopen the terminal. 1>&2
    exit /b 1
)
call npx.cmd %*
exit /b %ERRORLEVEL%
