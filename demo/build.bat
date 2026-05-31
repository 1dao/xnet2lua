@echo off
chcp 65001 > nul
title xnet-demo-build (MSVC all-source)
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"

set "RED=[91m"
set "GREEN=[92m"
set "YELLOW=[93m"
set "RESET=[0m"

set "BUILD_MODE=release"
set "WITH_HTTP=1"
set "WITH_HTTPS=1"
set "WITH_RPMALLOC=1"
set "CLEAN_ONLY=0"
set "LUA_BACKEND=minilua"

for %%A in (%*) do (
    if /I "%%~A"=="debug" set "BUILD_MODE=debug"
    if /I "%%~A"=="release" set "BUILD_MODE=release"
    if /I "%%~A"=="clean" set "CLEAN_ONLY=1"
    if /I "%%~A"=="nohttps" set "WITH_HTTPS=0"
    if /I "%%~A"=="norpmalloc" set "WITH_RPMALLOC=0"
    if /I "%%~A"=="luajit" set "LUA_BACKEND=luajit"
    if /I "%%~A"=="minilua" set "LUA_BACKEND=minilua"
)

echo %GREEN%[INFO]%RESET% Building demo with MSVC (all-source compile)...
echo %GREEN%[INFO]%RESET% Mode=%BUILD_MODE% HTTPS=%WITH_HTTPS% rpmalloc=%WITH_RPMALLOC% Lua=%LUA_BACKEND%

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo %RED%[ERROR]%RESET% vswhere.exe not found. Install Visual Studio 2017+ or the VS Build Tools.
    exit /b 1
)

set "VS_VCVARS="
for /f "usebackq tokens=*" %%P in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find VC\Auxiliary\Build\vcvarsall.bat`) do (
    set "VS_VCVARS=%%P"
)

if not defined VS_VCVARS (
    echo %RED%[ERROR]%RESET% Visual Studio with VC x86/x64 tools not found via vswhere.
    exit /b 1
)

if /I not "%VSCMD_ARG_TGT_ARCH%"=="x64" (
    echo %GREEN%[INFO]%RESET% Loading MSVC x64 environment...
    call "%VS_VCVARS%" x64
    if errorlevel 1 (
        echo %RED%[ERROR]%RESET% Failed to initialize MSVC environment.
        exit /b 1
    )
)

set "OBJDIR=.obj-msvc"
set "XNET_EXE=xnet.exe"
set "THREAD_EXE=xthread_test.exe"

set "COMMON_SOURCES=..\xthread.c ..\xpoll.c ..\xsock.c ..\xchannel.c ..\xargs.c ..\xtimer.c ..\xdaemon.c ..\xlog.c"
if "%WITH_RPMALLOC%"=="1" set "COMMON_SOURCES=%COMMON_SOURCES% ..\3rd\rpmalloc\rpmalloc.c"
set "XNET_SOURCES=..\xlua\xnet_main.c ..\xlua\lua_xthread.c ..\xlua\lua_xnet.c ..\xlua\lua_xnet_tls.c ..\xlua\lua_cmsgpack.c ..\xlua\lua_xutils.c ..\xlua\lua_xtimer.c ..\3rd\yyjson.c"
set "THREAD_SOURCES=xthread_test.c"
set "LUAJIT_DIR=..\3rd\luajit\src"
set "LUAJIT_INC=..\3rd\luajit\src"

REM rpmalloc toggle:
REM  WITH_RPMALLOC=1 → xmacro.h routes malloc/free to rp*, rpmalloc.c is linked.
REM    ENABLE_OVERRIDE=0 keeps rpmalloc.c from including malloc.c (which would
REM    hijack libc CRT symbols — not what we want; also breaks MinGW emutls).
REM  WITH_RPMALLOC=0 → xmacro.h passes through to libc, rpmalloc.c not linked,
REM    rpmalloc_* lifecycle calls stub to no-ops.
set "DEFS=/DWIN32_LEAN_AND_MEAN /DWINVER=0x0601 /D_WIN32_WINNT=0x0601 /D_CRT_SECURE_NO_WARNINGS /DXNET_WITH_HTTP=%WITH_HTTP% /DXNET_WITH_HTTPS=%WITH_HTTPS%"
if "%WITH_RPMALLOC%"=="1" (
    set "DEFS=%DEFS% /DENABLE_OVERRIDE=0 /DXMACRO_USE_RPMALLOC=1"
) else (
    set "DEFS=%DEFS% /DXMACRO_USE_RPMALLOC=0"
)
set "INCS=/I.."
if "%WITH_HTTPS%"=="1" (
    set "INCS=%INCS% /I..\3rd\mbedtls3\include"
)
if /I "%LUA_BACKEND%"=="luajit" (
    set "DEFS=%DEFS% /DXLUA_USE_LUAJIT=1"
    set "INCS=%INCS% /I%LUAJIT_INC%"
) else (
    set "DEFS=%DEFS% /DLUA_EMBEDDED"
)

set "XNET_LUA_LIB="
if /I "%LUA_BACKEND%"=="luajit" (
    if exist "%LUAJIT_DIR%\lua51.lib" set "XNET_LUA_LIB=%LUAJIT_DIR%\lua51.lib"
    if not defined XNET_LUA_LIB if exist "%LUAJIT_DIR%\luajit.lib" set "XNET_LUA_LIB=%LUAJIT_DIR%\luajit.lib"
    if not defined XNET_LUA_LIB if exist "%LUAJIT_DIR%\libluajit.lib" set "XNET_LUA_LIB=%LUAJIT_DIR%\libluajit.lib"

    if not defined XNET_LUA_LIB (
        if exist "%LUAJIT_DIR%\msvcbuild.bat" (
            echo %GREEN%[INFO]%RESET% LuaJIT .lib not found, running msvcbuild.bat static...
            pushd "%LUAJIT_DIR%"
            call msvcbuild.bat static
            if errorlevel 1 (
                popd
                echo %RED%[ERROR]%RESET% Failed to build LuaJIT static library.
                exit /b 1
            )
            popd
            if exist "%LUAJIT_DIR%\lua51.lib" set "XNET_LUA_LIB=%LUAJIT_DIR%\lua51.lib"
        )
    )

    if not defined XNET_LUA_LIB (
        echo %RED%[ERROR]%RESET% LuaJIT static lib not found.
        echo %YELLOW%[HINT]%RESET% Expected one of:
        echo   %LUAJIT_DIR%\lua51.lib
        echo   %LUAJIT_DIR%\luajit.lib
        echo   %LUAJIT_DIR%\libluajit.lib
        exit /b 1
    )
    echo %GREEN%[INFO]%RESET% LuaJIT lib: !XNET_LUA_LIB!
)

set "BASE_CFLAGS=/nologo /TC /W3 /utf-8 /std:c11 /experimental:c11atomics /wd4005 /wd4100 /wd4206 /wd4244 /wd4267 /wd4334 /wd4706 /wd4996 %DEFS% %INCS%"
if /I "%BUILD_MODE%"=="debug" (
    set "CFLAGS=%BASE_CFLAGS% /Od /Zi /MDd /DDEBUG"
    set "LDFLAGS=/DEBUG"
) else (
    set "CFLAGS=%BASE_CFLAGS% /O2 /MD /DNDEBUG"
    set "LDFLAGS="
)

set "COMMON_OBJECTS="
for %%F in (%COMMON_SOURCES%) do (
    set "COMMON_OBJECTS=!COMMON_OBJECTS! %OBJDIR%\%%~nF.obj"
)

set "XNET_OBJECTS="
for %%F in (%XNET_SOURCES%) do (
    set "XNET_OBJECTS=!XNET_OBJECTS! %OBJDIR%\%%~nF.obj"
)

set "THREAD_OBJECTS="
for %%F in (%THREAD_SOURCES%) do (
    set "THREAD_OBJECTS=!THREAD_OBJECTS! %OBJDIR%\%%~nF.obj"
)

set "MBEDTLS_OBJECTS="
if "%WITH_HTTPS%"=="1" (
    for %%F in ("..\3rd\mbedtls3\library\*.c") do (
        set "MBEDTLS_OBJECTS=!MBEDTLS_OBJECTS! %OBJDIR%\mbedtls\%%~nF.obj"
    )
)

if "%CLEAN_ONLY%"=="1" (
    if exist "%OBJDIR%" (
        echo %GREEN%[INFO]%RESET% Cleaning %OBJDIR%...
        rmdir /S /Q "%OBJDIR%"
    )
    if exist "%XNET_EXE%" del /Q "%XNET_EXE%"
    if exist "%THREAD_EXE%" del /Q "%THREAD_EXE%"
    echo %GREEN%[INFO]%RESET% Clean complete.
    exit /b 0
)

if exist "%OBJDIR%" rmdir /S /Q "%OBJDIR%"
mkdir "%OBJDIR%"
if "%WITH_HTTPS%"=="1" mkdir "%OBJDIR%\mbedtls"

echo %GREEN%[INFO]%RESET% Compiling common sources...
for %%F in (%COMMON_SOURCES%) do (
    echo %GREEN%[INFO]%RESET% cl %%F
    cl %CFLAGS% /c "%%~F" /Fo"%OBJDIR%\%%~nF.obj"
    if errorlevel 1 (
        echo %RED%[ERROR]%RESET% Failed to compile %%F
        exit /b 1
    )
)

echo %GREEN%[INFO]%RESET% Compiling xnet sources...
for %%F in (%XNET_SOURCES%) do (
    echo %GREEN%[INFO]%RESET% cl %%F
    cl %CFLAGS% /c "%%~F" /Fo"%OBJDIR%\%%~nF.obj"
    if errorlevel 1 (
        echo %RED%[ERROR]%RESET% Failed to compile %%F
        exit /b 1
    )
)

echo %GREEN%[INFO]%RESET% Compiling xthread_test sources...
for %%F in (%THREAD_SOURCES%) do (
    echo %GREEN%[INFO]%RESET% cl %%F
    cl %CFLAGS% /c "%%~F" /Fo"%OBJDIR%\%%~nF.obj"
    if errorlevel 1 (
        echo %RED%[ERROR]%RESET% Failed to compile %%F
        exit /b 1
    )
)

if "%WITH_HTTPS%"=="1" (
    echo %GREEN%[INFO]%RESET% Compiling mbedTLS sources...
    for %%F in ("..\3rd\mbedtls3\library\*.c") do (
        echo %GREEN%[INFO]%RESET% cl %%~nxF
        cl %CFLAGS% /c "%%~F" /Fo"%OBJDIR%\mbedtls\%%~nF.obj"
        if errorlevel 1 (
            echo %RED%[ERROR]%RESET% Failed to compile %%F
            exit /b 1
        )
    )
)

set "THREAD_LIBS=ws2_32.lib"
set "XNET_LIBS=ws2_32.lib"
if "%WITH_RPMALLOC%"=="1" (
    set "THREAD_LIBS=%THREAD_LIBS% Advapi32.lib"
    set "XNET_LIBS=%XNET_LIBS% Advapi32.lib"
)
if "%WITH_HTTPS%"=="1" (
    set "XNET_LIBS=%XNET_LIBS% bcrypt.lib"
)
if defined XNET_LUA_LIB (
    set "XNET_LIBS=%XNET_LIBS% %XNET_LUA_LIB%"
)

set "THREAD_RPMALLOC_OBJ="
if "%WITH_RPMALLOC%"=="1" set "THREAD_RPMALLOC_OBJ=%OBJDIR%\rpmalloc.obj"

echo %GREEN%[INFO]%RESET% Linking %THREAD_EXE%...
link /nologo %LDFLAGS% /OUT:%THREAD_EXE% %THREAD_OBJECTS% %OBJDIR%\xthread.obj %OBJDIR%\xpoll.obj %OBJDIR%\xsock.obj %OBJDIR%\xdaemon.obj %OBJDIR%\xlog.obj %THREAD_RPMALLOC_OBJ% %THREAD_LIBS%
if errorlevel 1 (
    echo %RED%[ERROR]%RESET% Link failed for %THREAD_EXE%
    exit /b 1
)

echo %GREEN%[INFO]%RESET% Linking %XNET_EXE%...
link /nologo %LDFLAGS% /OUT:%XNET_EXE% %COMMON_OBJECTS% %XNET_OBJECTS% %MBEDTLS_OBJECTS% %XNET_LIBS%
if errorlevel 1 (
    echo %RED%[ERROR]%RESET% Link failed for %XNET_EXE%
    exit /b 1
)

echo %GREEN%[INFO]%RESET% Build complete.
echo %GREEN%[INFO]%RESET% Outputs:
echo   %CD%\%THREAD_EXE%
echo   %CD%\%XNET_EXE%
exit /b 0
