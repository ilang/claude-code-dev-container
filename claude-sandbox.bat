@echo off
setlocal EnableDelayedExpansion

REM claude-sandbox.bat — run Claude Code in a secure, persistent container (Windows)
REM
REM Usage:
REM   cd C:\path\to\your\project
REM   claude-sandbox                        # persistent container for current dir
REM   claude-sandbox my-subproject   # with subfolder
REM   claude-sandbox --temp                 # ephemeral container (deleted on exit)
REM   claude-sandbox --new                  # fresh persistent container
REM   claude-sandbox --list                 # show all containers
REM   claude-sandbox --stop                 # stop this project's container
REM   claude-sandbox --rm                   # remove this project's container
REM   claude-sandbox -h                     # show help

set IMAGE_NAME=claude-sandbox
set MODE=persistent
set ACTION=
set SUBFOLDER=
set NETWORK=default
set NO_INSTALL=

REM --- Parse arguments ---
REM NOTE: set "VAR=value" quoting is critical — without quotes, trailing spaces
REM before & are included in the value, breaking all comparisons downstream.
:parse_args
if "%~1"=="" goto :done_args
if "%~1"=="--new"  ( set "ACTION=new" & shift & goto :parse_args )
if "%~1"=="--temp" ( set "MODE=temp" & shift & goto :parse_args )
if "%~1"=="--open-network" ( set "NETWORK=open" & shift & goto :parse_args )
if "%~1"=="--locked"       ( set "NETWORK=locked" & shift & goto :parse_args )
if "%~1"=="--no-install"   ( set "NO_INSTALL=1" & shift & goto :parse_args )
if "%~1"=="--list"    ( set "ACTION=list" & shift & goto :parse_args )
if "%~1"=="--stop"    ( set "ACTION=stop" & shift & goto :parse_args )
if "%~1"=="--rm"      ( set "ACTION=rm" & shift & goto :parse_args )
if "%~1"=="--rm-all"  ( set "ACTION=rm-all" & shift & goto :parse_args )
if "%~1"=="-h"     ( set "ACTION=help" & shift & goto :parse_args )
if "%~1"=="--help" ( set "ACTION=help" & shift & goto :parse_args )
set "SUBFOLDER=%~1"
shift
goto :parse_args
:done_args

REM --- Derive container name from current directory ---
REM Uses last 3 path components + short hash for readability and uniqueness.
REM PowerShell handles the path splitting, sanitization, and MD5 hashing.
REM NOTE: This may produce different names than the bash version for the same path
REM (different path separators, hashing input). Containers created from bash (e.g., WSL)
REM and from .bat are not interchangeable. Use one or the other consistently.
for /f "tokens=*" %%n in ('powershell -NoProfile -Command "$p='%cd%'; $parts=$p.Split([IO.Path]::DirectorySeparatorChar); $tail=($parts[-3..-1] -join '-'); $san=('claude-sandbox-' + $tail.ToLower() -replace '[^a-z0-9]','-' -replace '-+','-' -replace '^-','' -replace '-$',''); $hash=[BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($p))).Replace('-','').Substring(0,8).ToLower(); ($san + '-' + $hash).TrimEnd('-')"') do set CONTAINER_NAME=%%n

REM --- Validate subfolder name (prevent shell injection) ---
if not "%SUBFOLDER%"=="" (
    echo %SUBFOLDER% | findstr /R "[^a-zA-Z0-9._/\\-]" >nul 2>nul && (
        echo Error: subfolder name contains invalid characters: %SUBFOLDER%
        echo Only letters, numbers, hyphens, underscores, dots, and slashes are allowed.
        exit /b 1
    )
)

REM === Build host config mounts (only if files exist) ===
REM Settings, plugins, and statusline are NOT synced from the host — they may contain
REM platform-specific config (hooks, paths) that breaks in the Linux container.
REM These are managed independently inside the container via the claude-code-config volume.
set HOST_MOUNTS=
if exist "%USERPROFILE%\.claude\memory" set HOST_MOUNTS=!HOST_MOUNTS! -v "%USERPROFILE%\.claude\memory":/host-claude-config/memory:ro
if exist "%USERPROFILE%\.gitconfig" set HOST_MOUNTS=!HOST_MOUNTS! -v "%USERPROFILE%\.gitconfig":/home/node/.gitconfig:ro

REM TODO: SSH agent forwarding is not yet supported on Windows.
REM The bash version forwards the SSH agent socket so git push/pull over SSH works.
REM Windows uses named pipes (\\.\pipe\openssh-ssh-agent) instead of Unix sockets,
REM and Docker Desktop's support for this varies. For now, use HTTPS git remotes
REM on Windows, or run claude-sandbox from WSL where the bash version works.

REM === Detect host timezone ===
REM Try to get the IANA timezone name from .NET. Falls back to UTC if detection fails.
REM Modern Windows/.NET can return IANA names directly; older versions return Windows
REM names which won't work in Linux containers, so we fall back to UTC.
if "%TZ%"=="" (
    for /f "tokens=*" %%t in ('powershell -NoProfile -Command "try { $tz=[System.TimeZoneInfo]::Local; if ($tz.HasIanaId) { $tz.Id } else { 'UTC' } } catch { 'UTC' }"') do set TZ=%%t
)

REM === Create .allowed-domains if it doesn't exist ===
if not exist "%cd%\.allowed-domains" (
    if exist "%~dp0allowed-domains.default" (
        copy "%~dp0allowed-domains.default" "%cd%\.allowed-domains" >nul
        echo Created .allowed-domains with default whitelist (GitHub, npm, VS Code^).
        echo Edit %cd%\.allowed-domains to customize.
    )
)

REM === Network capabilities (only needed when firewall is active) ===
set CAP_ARGS=--cap-add=NET_ADMIN --cap-add=NET_RAW
if "%NETWORK%"=="open" set CAP_ARGS=

REM --- Dispatch ---
if "%ACTION%"=="help"    goto :show_help
if "%ACTION%"=="list"    goto :do_list
if "%ACTION%"=="stop"    goto :do_stop
if "%ACTION%"=="rm"      goto :do_rm
if "%ACTION%"=="rm-all"  goto :do_rm_all
REM (relogin action removed)
if "%ACTION%"=="new"     goto :do_new

if "%MODE%"=="temp" goto :run_temp
goto :run_persistent

REM === Management commands ===

:show_help
echo Usage: claude-sandbox [flags] [subfolder]
echo.
echo Run Claude Code in a secure container with a locked-down firewall.
echo Default: persistent container per project folder.
echo.
echo Flags:
echo   --new           Remove existing container and create a fresh one
echo   --temp          Ephemeral container (deleted on exit)
echo   --open-network  No firewall — full internet access
echo   --locked        Whitelist only — no runtime domain additions
echo   --no-install    Disable package installation (sudo install-package.sh)
echo   --list          Show all claude-sandbox containers
echo   --stop          Stop this project's container
echo   --rm            Remove this project's container
echo   --rm-all        Remove ALL claude-sandbox containers
echo   -h, --help      Show this help
echo.
echo Examples:
echo   claude-sandbox                        # start/reattach persistent container
echo   claude-sandbox my-subproject   # with subfolder (monorepo)
echo   claude-sandbox --temp                 # one-off session, deleted on exit
echo   claude-sandbox --new                  # fresh container for this project
echo   claude-sandbox --list                 # see all containers
exit /b 0

:do_list
echo Claude Sandbox containers:
echo.
docker ps -a --filter "label=claude-sandbox.project-path" --format "table {{.Names}}\t{{.Status}}\t{{.Label \"claude-sandbox.project-path\"}}"
exit /b 0

:do_stop
docker stop %CONTAINER_NAME% 2>nul && ( echo Stopped: %CONTAINER_NAME% ) || ( echo Container %CONTAINER_NAME% is not running. )
exit /b 0

:do_rm
docker rm -f %CONTAINER_NAME% 2>nul && ( echo Removed: %CONTAINER_NAME% ) || ( echo Container %CONTAINER_NAME% does not exist. )
exit /b 0

:do_rm_all
echo Removing all claude-sandbox containers...
for /f "tokens=*" %%c in ('docker ps -a --filter "label=claude-sandbox.project-path" --format "{{.Names}}"') do (
    docker rm -f %%c >nul
    echo Removed: %%c
)
exit /b 0

:do_new
docker rm -f %CONTAINER_NAME% 2>nul
echo Removed old container. Creating fresh...
goto :run_persistent

REM === Temp mode ===

:run_temp
docker run -it --rm ^
  %CAP_ARGS% ^
  -v "%cd%":/workspace ^
  -v claude-code-config:/home/node/.claude ^
  -v claude-code-json:/home/node/.claude-json ^
  -v claude-code-history:/commandhistory ^
  %HOST_MOUNTS% ^
  -e CLAUDE_MODE=temp ^
  -e CLAUDE_NETWORK=%NETWORK% ^
  -e CLAUDE_NO_INSTALL=%NO_INSTALL% ^
  -e CLAUDE_SUBFOLDER=%SUBFOLDER% ^
  -e TZ=%TZ% ^
  --label "claude-sandbox.mode=temp" ^
  --label "claude-sandbox.project-path=%cd%" ^
  %IMAGE_NAME%
exit /b

REM === Persistent mode ===

:run_persistent
REM Check container state
set STATE=missing
for /f "tokens=*" %%s in ('docker inspect --format "{{.State.Status}}" %CONTAINER_NAME% 2^>nul') do set STATE=%%s

if "%STATE%"=="running" goto :attach
if "%STATE%"=="exited"  goto :restart
if "%STATE%"=="created" goto :restart
if "%STATE%"=="dead"    goto :restart
goto :create

:attach
echo Attaching to running container: %CONTAINER_NAME%
goto :exec_claude

:restart
echo Restarting container: %CONTAINER_NAME%
docker start %CONTAINER_NAME% >nul
call :wait_ready
goto :exec_claude

:create
echo Creating container: %CONTAINER_NAME%
docker run -d ^
  --name %CONTAINER_NAME% ^
  --hostname %CONTAINER_NAME% ^
  %CAP_ARGS% ^
  -v "%cd%":/workspace ^
  -v claude-code-config:/home/node/.claude ^
  -v claude-code-json:/home/node/.claude-json ^
  -v claude-code-history:/commandhistory ^
  %HOST_MOUNTS% ^
  -e CLAUDE_MODE=persistent ^
  -e CLAUDE_NETWORK=%NETWORK% ^
  -e CLAUDE_NO_INSTALL=%NO_INSTALL% ^
  -e TZ=%TZ% ^
  --label "claude-sandbox.mode=persistent" ^
  --label "claude-sandbox.project-path=%cd%" ^
  %IMAGE_NAME% >nul
call :wait_ready
goto :exec_claude

:exec_claude
if "%SUBFOLDER%"=="" (
    docker exec -it %CONTAINER_NAME% /bin/zsh -c "cd '/workspace' && exec claude --dangerously-skip-permissions"
) else (
    docker exec -it %CONTAINER_NAME% /bin/zsh -c "cd '/workspace/%SUBFOLDER%' && exec claude --dangerously-skip-permissions"
)
exit /b

:wait_ready
echo Setting up container (firewall, DNS resolution)...
set WAIT_ELAPSED=0
:wait_loop
if %WAIT_ELAPSED% GEQ 120 (
    echo ERROR: Container setup timed out after 120 seconds.
    echo Check logs: docker logs %CONTAINER_NAME%
    exit /b 1
)
docker exec %CONTAINER_NAME% test -f /tmp/.claude-sandbox-ready 2>nul && exit /b 0
timeout /t 1 /nobreak >nul
set /a WAIT_ELAPSED+=1
goto :wait_loop
