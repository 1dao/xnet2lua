@echo off
chcp 65001 > nul
title xnet-root-build (MSVC all-source)
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"

set "RED=[91m"
set "GREEN=[92m"
set "YELLOW=[93m"
set "RESET=[0m"

set "BUILD_MODE=release"
set "WITH_HTTP=1"
set "WITH_HTTPS=1"
set "WITH_IO_URING=0"
set "WITH_XDEBUG=0"
set "WITH_RPMALLOC=1"
set "LUA_BACKEND=minilua"
set "TARGET=all"
set "RUN_SCRIPT="

for %%A in (%*) do (
    set "ARG=%%~A"
    if /I "!ARG!"=="debug" set "BUILD_MODE=debug"
    if /I "!ARG!"=="release" set "BUILD_MODE=release"
    if /I "!ARG!"=="clean" set "TARGET=clean"
    if /I "!ARG!"=="nohttp" set "WITH_HTTP=0"
    if /I "!ARG!"=="nohttps" set "WITH_HTTPS=0"
    if /I "!ARG!"=="xdebug" set "WITH_XDEBUG=1"
    if /I "!ARG!"=="noxdebug" set "WITH_XDEBUG=0"
    if /I "!ARG!"=="norpmalloc" set "WITH_RPMALLOC=0"
    if /I "!ARG!"=="iouring" set "WITH_IO_URING=1"
    if /I "!ARG!"=="luajit" set "LUA_BACKEND=luajit"
    if /I "!ARG!"=="minilua" set "LUA_BACKEND=minilua"
    if /I "!ARG!"=="xnet" set "TARGET=xnet"
    if /I "!ARG!"=="xthread_test" set "TARGET=xthread_test"
    if /I "!ARG!"=="unit" set "TARGET=unit"
    if /I "!ARG!"=="unit-c" set "TARGET=unit-c"
    if /I "!ARG!"=="unit-lua" set "TARGET=unit-lua"
    if /I "!ARG!"=="test" set "TARGET=test"
    if /I "!ARG!"=="test-c" set "TARGET=test-c"
    if /I "!ARG!"=="test-lua-core" set "TARGET=test-lua-core"
    if /I "!ARG!"=="test-lua-external" set "TARGET=test-lua-external"
    if /I "!ARG!"=="test-lua-all" set "TARGET=test-lua-all"
    if /I "!ARG!"=="run-lua" set "TARGET=run-lua"
    if /I "!ARG:~0,7!"=="script=" set "RUN_SCRIPT=!ARG:~7!"
    if not defined RUN_SCRIPT (
        if /I "!ARG:~-4!"==".lua" set "RUN_SCRIPT=!ARG!"
    )
)

if /I "%TARGET%"=="run-lua" if not defined RUN_SCRIPT if defined SCRIPT set "RUN_SCRIPT=%SCRIPT%"

if /I "%TARGET%"=="run-lua" if not defined RUN_SCRIPT (
    echo %RED%[ERROR]%RESET% run-lua needs a script path.
    echo %YELLOW%[HINT]%RESET%  build.bat run-lua script=demo/xutils_main.lua
    echo %YELLOW%[HINT]%RESET%  build.bat run-lua demo/xutils_main.lua
    exit /b 1
)

if "%WITH_IO_URING%"=="1" (
    echo [WARN] WITH_IO_URING is ignored on Windows build.bat.
)

echo %GREEN%[INFO]%RESET% Root build with MSVC (all-source compile)...
echo %GREEN%[INFO]%RESET% target=%TARGET% mode=%BUILD_MODE% lua=%LUA_BACKEND% http=%WITH_HTTP% https=%WITH_HTTPS% xdebug=%WITH_XDEBUG% rpmalloc=%WITH_RPMALLOC%

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
        "C:\software\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat"
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
set "BIN_DIR=bin"
set "XNET_EXE=%BIN_DIR%\xnet.exe"
set "THREAD_EXE=%BIN_DIR%\xthread_test.exe"
set "UNIT_EXE=%BIN_DIR%\test_core.exe"

set "COMMON_SOURCES=xthread.c xpoll.c xsock.c xchannel.c xargs.c xtimer.c xdaemon.c xlog.c"
if "%WITH_RPMALLOC%"=="1" set "COMMON_SOURCES=%COMMON_SOURCES% 3rd\rpmalloc\rpmalloc.c"
set "XNET_SOURCES=xnet_main.c xlua\lua_xthread.c xlua\lua_xnet.c xlua\lua_xnet_tls.c xlua\lua_cmsgpack.c xlua\lua_xutils.c xlua\lua_xtimer.c 3rd\yyjson.c"
if "%WITH_XDEBUG%"=="1" set "XNET_SOURCES=%XNET_SOURCES% xlua\lua_xdebug.c"
set "THREAD_SOURCES=demo\xthread_test.c"
set "C_UNIT_SOURCES=tests\c\test_core.c xargs.c xtimer.c xpoll.c xlog.c"
set "LUAJIT_DIR=3rd\luajit\src"
set "LUAJIT_INC=3rd\luajit\src"

set "LUA_UNIT_SCRIPTS=tests/lua/http_codec_spec.lua"
set "LUA_TEST_CORE_SCRIPTS=demo/xutils_main.lua demo/xtimer_main.lua demo/xtimerx_test.lua demo/xlua_main.lua demo/xnet_main.lua demo/xrouter_test.lua demo/xhttp_router_test.lua demo/xhttp_main.lua"
set "LUA_TEST_EXTERNAL_SCRIPTS=demo/xhttps_main.lua demo/xredis_main.lua demo/xmysql_main.lua demo/xnats_main.lua"

set "DEFS=/DWIN32_LEAN_AND_MEAN /DWINVER=0x0601 /D_WIN32_WINNT=0x0601 /D_CRT_SECURE_NO_WARNINGS /DXNET_WITH_HTTP=%WITH_HTTP% /DXNET_WITH_HTTPS=%WITH_HTTPS% /DXNET_WITH_XDEBUG=%WITH_XDEBUG%"
if "%WITH_RPMALLOC%"=="1" (
    set "DEFS=%DEFS% /DENABLE_OVERRIDE=0 /DXMACRO_USE_RPMALLOC=1"
) else (
    set "DEFS=%DEFS% /DXMACRO_USE_RPMALLOC=0"
)
set "INCS=/I."
if "%WITH_HTTPS%"=="1" (
    set "INCS=%INCS% /I3rd\mbedtls3\include"
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

set "UNIT_OBJECTS="
for %%F in (%C_UNIT_SOURCES%) do (
    set "UNIT_OBJECTS=!UNIT_OBJECTS! %OBJDIR%\unit_%%~nF.obj"
)

set "MBEDTLS_OBJECTS="
if "%WITH_HTTPS%"=="1" (
    for %%F in ("3rd\mbedtls3\library\*.c") do (
        set "MBEDTLS_OBJECTS=!MBEDTLS_OBJECTS! %OBJDIR%\mbedtls\%%~nF.obj"
    )
)

if /I "%TARGET%"=="clean" (
    if exist "%OBJDIR%" (
        echo %GREEN%[INFO]%RESET% Cleaning %OBJDIR%...
        rmdir /S /Q "%OBJDIR%"
    )
    if exist "%XNET_EXE%" del /Q "%XNET_EXE%"
    if exist "%THREAD_EXE%" del /Q "%THREAD_EXE%"
    if exist "%UNIT_EXE%" del /Q "%UNIT_EXE%"
    echo %GREEN%[INFO]%RESET% Clean complete.
    exit /b 0
)

set "NEED_BUILD_XNET=0"
set "NEED_BUILD_THREAD=0"
set "NEED_BUILD_UNIT=0"
set "RUN_UNIT_C=0"
set "RUN_UNIT_LUA=0"
set "RUN_TEST_C=0"
set "RUN_TEST_LUA_CORE=0"
set "RUN_TEST_LUA_EXTERNAL=0"
set "RUN_SINGLE_LUA=0"

if /I "%TARGET%"=="all" (
    set "NEED_BUILD_XNET=1"
    set "NEED_BUILD_THREAD=1"
)
if /I "%TARGET%"=="xnet" set "NEED_BUILD_XNET=1"
if /I "%TARGET%"=="xthread_test" set "NEED_BUILD_THREAD=1"
if /I "%TARGET%"=="test" (
    set "NEED_BUILD_XNET=1"
    set "NEED_BUILD_THREAD=1"
    set "NEED_BUILD_UNIT=1"
    set "RUN_UNIT_C=1"
    set "RUN_UNIT_LUA=1"
    set "RUN_TEST_C=1"
    set "RUN_TEST_LUA_CORE=1"
)
if /I "%TARGET%"=="unit" (
    set "NEED_BUILD_XNET=1"
    set "NEED_BUILD_UNIT=1"
    set "RUN_UNIT_C=1"
    set "RUN_UNIT_LUA=1"
)
if /I "%TARGET%"=="unit-c" (
    set "NEED_BUILD_UNIT=1"
    set "RUN_UNIT_C=1"
)
if /I "%TARGET%"=="unit-lua" (
    set "NEED_BUILD_XNET=1"
    set "RUN_UNIT_LUA=1"
)
if /I "%TARGET%"=="test-c" (
    set "NEED_BUILD_THREAD=1"
    set "RUN_TEST_C=1"
)
if /I "%TARGET%"=="test-lua-core" (
    set "NEED_BUILD_XNET=1"
    set "RUN_TEST_LUA_CORE=1"
)
if /I "%TARGET%"=="test-lua-external" (
    set "NEED_BUILD_XNET=1"
    set "RUN_TEST_LUA_EXTERNAL=1"
)
if /I "%TARGET%"=="test-lua-all" (
    set "NEED_BUILD_XNET=1"
    set "RUN_TEST_LUA_CORE=1"
    set "RUN_TEST_LUA_EXTERNAL=1"
)
if /I "%TARGET%"=="run-lua" (
    set "NEED_BUILD_XNET=1"
    set "RUN_SINGLE_LUA=1"
)

if exist "%OBJDIR%" rmdir /S /Q "%OBJDIR%"
mkdir "%OBJDIR%"
if "%WITH_HTTPS%"=="1" mkdir "%OBJDIR%\mbedtls"
if not exist "%BIN_DIR%" mkdir "%BIN_DIR%"

if "%NEED_BUILD_XNET%"=="1" (
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

    if "%WITH_HTTPS%"=="1" (
        echo %GREEN%[INFO]%RESET% Compiling mbedTLS sources...
        for %%F in ("3rd\mbedtls3\library\*.c") do (
            echo %GREEN%[INFO]%RESET% cl %%~nxF
            cl %CFLAGS% /c "%%~F" /Fo"%OBJDIR%\mbedtls\%%~nF.obj"
            if errorlevel 1 (
                echo %RED%[ERROR]%RESET% Failed to compile %%F
                exit /b 1
            )
        )
    )

    set "XNET_LIBS=ws2_32.lib"
    if "%WITH_RPMALLOC%"=="1" set "XNET_LIBS=!XNET_LIBS! Advapi32.lib"
    if "%WITH_HTTPS%"=="1" set "XNET_LIBS=!XNET_LIBS! bcrypt.lib"
    if defined XNET_LUA_LIB set "XNET_LIBS=!XNET_LIBS! !XNET_LUA_LIB!"

    echo %GREEN%[INFO]%RESET% Linking %XNET_EXE%...
    link /nologo %LDFLAGS% /OUT:%XNET_EXE% %COMMON_OBJECTS% %XNET_OBJECTS% %MBEDTLS_OBJECTS% !XNET_LIBS!
    if errorlevel 1 (
        echo %RED%[ERROR]%RESET% Link failed for %XNET_EXE%
        exit /b 1
    )
)

if "%NEED_BUILD_THREAD%"=="1" (
    if "%NEED_BUILD_XNET%"=="0" (
        echo %GREEN%[INFO]%RESET% Compiling thread test dependencies...
        for %%F in (xthread.c xpoll.c xsock.c xdaemon.c xlog.c) do (
            echo %GREEN%[INFO]%RESET% cl %%F
            cl %CFLAGS% /c "%%~F" /Fo"%OBJDIR%\%%~nF.obj"
            if errorlevel 1 (
                echo %RED%[ERROR]%RESET% Failed to compile %%F
                exit /b 1
            )
        )
        if "%WITH_RPMALLOC%"=="1" (
            echo %GREEN%[INFO]%RESET% cl 3rd\rpmalloc\rpmalloc.c
            cl %CFLAGS% /c "3rd\rpmalloc\rpmalloc.c" /Fo"%OBJDIR%\rpmalloc.obj"
            if errorlevel 1 (
                echo %RED%[ERROR]%RESET% Failed to compile 3rd\rpmalloc\rpmalloc.c
                exit /b 1
            )
        )
    )

    echo %GREEN%[INFO]%RESET% Compiling xthread_test source...
    for %%F in (%THREAD_SOURCES%) do (
        echo %GREEN%[INFO]%RESET% cl %%F
        cl %CFLAGS% /c "%%~F" /Fo"%OBJDIR%\%%~nF.obj"
        if errorlevel 1 (
            echo %RED%[ERROR]%RESET% Failed to compile %%F
            exit /b 1
        )
    )

    echo %GREEN%[INFO]%RESET% Linking %THREAD_EXE%...
    set "THREAD_RPMALLOC_OBJ="
    if "%WITH_RPMALLOC%"=="1" set "THREAD_RPMALLOC_OBJ=%OBJDIR%\rpmalloc.obj"
    set "THREAD_LIBS=ws2_32.lib"
    if "%WITH_RPMALLOC%"=="1" set "THREAD_LIBS=!THREAD_LIBS! Advapi32.lib"
    link /nologo %LDFLAGS% /OUT:%THREAD_EXE% %THREAD_OBJECTS% %OBJDIR%\xthread.obj %OBJDIR%\xpoll.obj %OBJDIR%\xsock.obj %OBJDIR%\xdaemon.obj %OBJDIR%\xlog.obj !THREAD_RPMALLOC_OBJ! !THREAD_LIBS!
    if errorlevel 1 (
        echo %RED%[ERROR]%RESET% Link failed for %THREAD_EXE%
        exit /b 1
    )
)

if "%NEED_BUILD_UNIT%"=="1" (
    set "UNIT_DEFS=/DWIN32_LEAN_AND_MEAN /DWINVER=0x0601 /D_WIN32_WINNT=0x0601 /D_CRT_SECURE_NO_WARNINGS /DXMACRO_USE_RPMALLOC=0"
    set "UNIT_CFLAGS=/nologo /TC /W3 /utf-8 /std:c11 /experimental:c11atomics /wd4005 /wd4100 /wd4206 /wd4244 /wd4267 /wd4334 /wd4706 /wd4996 !UNIT_DEFS! /I."
    if /I "%BUILD_MODE%"=="debug" (
        set "UNIT_CFLAGS=!UNIT_CFLAGS! /Od /Zi /MDd /DDEBUG"
    ) else (
        set "UNIT_CFLAGS=!UNIT_CFLAGS! /O2 /MD /DNDEBUG"
    )

    echo %GREEN%[INFO]%RESET% Compiling C unit sources...
    for %%F in (%C_UNIT_SOURCES%) do (
        echo %GREEN%[INFO]%RESET% cl %%F
        cl !UNIT_CFLAGS! /c "%%~F" /Fo"%OBJDIR%\unit_%%~nF.obj"
        if errorlevel 1 (
            echo %RED%[ERROR]%RESET% Failed to compile %%F
            exit /b 1
        )
    )

    echo %GREEN%[INFO]%RESET% Linking %UNIT_EXE%...
    link /nologo %LDFLAGS% /OUT:%UNIT_EXE% %UNIT_OBJECTS% ws2_32.lib
    if errorlevel 1 (
        echo %RED%[ERROR]%RESET% Link failed for %UNIT_EXE%
        exit /b 1
    )
)

if "%RUN_UNIT_C%"=="1" (
    echo %GREEN%[INFO]%RESET% Running C unit tests: %UNIT_EXE%
    "%UNIT_EXE%"
    if errorlevel 1 (
        echo %RED%[ERROR]%RESET% C unit tests failed.
        exit /b 1
    )
)

if "%RUN_UNIT_LUA%"=="1" (
    call :run_lua_suite unit
    if errorlevel 1 exit /b 1
)

if "%RUN_TEST_C%"=="1" (
    echo %GREEN%[INFO]%RESET% Running C regression: %THREAD_EXE%
    "%THREAD_EXE%"
    if errorlevel 1 (
        echo %RED%[ERROR]%RESET% C regression failed.
        exit /b 1
    )
)

if "%RUN_TEST_LUA_CORE%"=="1" (
    call :run_lua_suite core
    if errorlevel 1 exit /b 1
)

if "%RUN_TEST_LUA_EXTERNAL%"=="1" (
    call :run_lua_suite external
    if errorlevel 1 exit /b 1
)

if "%RUN_SINGLE_LUA%"=="1" (
    call :run_lua_script "%RUN_SCRIPT%"
    if errorlevel 1 exit /b 1
)

echo %GREEN%[INFO]%RESET% Build complete.
if exist "%XNET_EXE%" echo %GREEN%[INFO]%RESET% output: %CD%\%XNET_EXE%
if exist "%THREAD_EXE%" echo %GREEN%[INFO]%RESET% output: %CD%\%THREAD_EXE%
if exist "%UNIT_EXE%" echo %GREEN%[INFO]%RESET% output: %CD%\%UNIT_EXE%
exit /b 0

:run_lua_suite
set "SUITE=%~1"
if /I "%SUITE%"=="unit" (
    set "SUITE_SCRIPTS=%LUA_UNIT_SCRIPTS%"
) else if /I "%SUITE%"=="core" (
    set "SUITE_SCRIPTS=%LUA_TEST_CORE_SCRIPTS%"
) else (
    set "SUITE_SCRIPTS=%LUA_TEST_EXTERNAL_SCRIPTS%"
)

for %%S in (!SUITE_SCRIPTS!) do (
    if /I "%WITH_HTTPS%"=="0" if /I "%%~S"=="demo/xhttps_main.lua" (
        echo %GREEN%[INFO]%RESET% Skip %%~S because WITH_HTTPS=0
    ) else (
        call :run_lua_script "%%~S"
        if errorlevel 1 exit /b 1
    )
)
exit /b 0

:run_lua_script
set "SCRIPT_PATH=%~1"
set "SCRIPT_ARG=%SCRIPT_PATH:\=/%"
echo %GREEN%[INFO]%RESET% ==> %SCRIPT_ARG%

if /I "%WITH_HTTP%"=="0" if /I "%SCRIPT_ARG%"=="demo/xhttp_main.lua" (
    echo %GREEN%[INFO]%RESET% Skip %SCRIPT_ARG% because WITH_HTTP=0
    exit /b 0
)

"%XNET_EXE%" "%SCRIPT_ARG%"
if errorlevel 1 (
    echo %RED%[ERROR]%RESET% Lua script failed: %SCRIPT_ARG%
    exit /b 1
)
exit /b 0
