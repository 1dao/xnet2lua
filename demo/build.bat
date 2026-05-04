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
set "CLEAN_ONLY=0"

for %%A in (%*) do (
    if /I "%%~A"=="debug" set "BUILD_MODE=debug"
    if /I "%%~A"=="release" set "BUILD_MODE=release"
    if /I "%%~A"=="clean" set "CLEAN_ONLY=1"
    if /I "%%~A"=="nohttps" set "WITH_HTTPS=0"
)

echo %GREEN%[INFO]%RESET% Building demo with MSVC (all-source compile)...
echo %GREEN%[INFO]%RESET% Mode=%BUILD_MODE% HTTPS=%WITH_HTTPS%

set "VS_VCVARS="
if exist "%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" (
    for /f "usebackq tokens=*" %%P in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find VC\Auxiliary\Build\vcvarsall.bat`) do (
        set "VS_VCVARS=%%P"
    )
)

if not defined VS_VCVARS (
    for %%P in (
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat"
        "C:\Program Files\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "C:\Program Files\Microsoft Visual Studio\2017\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "C:\Program Files (x86)\Microsoft Visual Studio\2017\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "C:\software\MicrosoftVisual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "C:\software\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat"
        "D:\software\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "D:\software\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat"
        "D:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "D:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvarsall.bat"
        "D:\Program Files\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "D:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "D:\Program Files\Microsoft Visual Studio\2017\Community\VC\Auxiliary\Build\vcvarsall.bat"
        "D:\Program Files (x86)\Microsoft Visual Studio\2017\Community\VC\Auxiliary\Build\vcvarsall.bat"
    ) do (
        if exist %%P (
            set "VS_VCVARS=%%P"
            goto :found_vcvars
        )
    )
)

:found_vcvars
if not defined VS_VCVARS (
    echo %RED%[ERROR]%RESET% Visual Studio vcvarsall.bat not found.
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

set "COMMON_SOURCES=..\xthread.c ..\xpoll.c ..\xsock.c ..\xchannel.c ..\xargs.c"
set "XNET_SOURCES=xnet_main.c ..\xlua\lua_xthread.c ..\xlua\lua_xnet.c ..\xlua\lua_xnet_tls.c ..\xlua\lua_cmsgpack.c ..\xlua\lua_xutils.c ..\xlua\lua_xtimer.c ..\3rd\yyjson.c"
set "THREAD_SOURCES=xthread_test.c"

set "DEFS=/DWIN32_LEAN_AND_MEAN /DWINVER=0x0601 /D_WIN32_WINNT=0x0601 /D_CRT_SECURE_NO_WARNINGS /DLUA_EMBEDDED /DXNET_WITH_HTTP=%WITH_HTTP% /DXNET_WITH_HTTPS=%WITH_HTTPS%"
set "INCS=/I.."
if "%WITH_HTTPS%"=="1" (
    set "INCS=%INCS% /I..\3rd\mbedtls3\include"
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
if "%WITH_HTTPS%"=="1" (
    set "XNET_LIBS=%XNET_LIBS% bcrypt.lib"
)

echo %GREEN%[INFO]%RESET% Linking %THREAD_EXE%...
link /nologo %LDFLAGS% /OUT:%THREAD_EXE% %THREAD_OBJECTS% %OBJDIR%\xthread.obj %OBJDIR%\xpoll.obj %OBJDIR%\xsock.obj %THREAD_LIBS%
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
