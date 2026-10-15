@echo off
setlocal

if /I not "%~1"=="auth" goto forward
if /I not "%~2"=="token" goto forward

set "TOKEN_JSON="
for %%A in (%*) do (
  if /I "%%~A"=="https://ai.azure.com/.default" (
    set "TOKEN_JSON=%FOUNDRY_AZD_TOKEN_BRIDGE_AI_JSON%"
  )
  if /I "%%~A"=="https://management.azure.com/.default" (
    set "TOKEN_JSON=%FOUNDRY_AZD_TOKEN_BRIDGE_ARM_JSON%"
  )
)

if defined TOKEN_JSON (
  <nul set /p "=%TOKEN_JSON%"
  echo(
  exit /b 0
)

:forward
endlocal
if not defined FOUNDRY_AZD_TOKEN_BRIDGE_REAL_PATH (
  >&2 echo FOUNDRY_AZD_TOKEN_BRIDGE_REAL_PATH is not configured.
  exit /b 1
)

"%FOUNDRY_AZD_TOKEN_BRIDGE_REAL_PATH%" %*
exit /b %ERRORLEVEL%
