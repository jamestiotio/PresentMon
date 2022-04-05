:: Copyright (C) 2020-2021 Intel Corporation
:: SPDX-License-Identifier: MIT

@echo off
setlocal enabledelayedexpansion
for %%a in ("%~dp0..") do set pmdir=%%~fa
set only_x64_platform=0
set use_debug_config=1
set use_release_config=1
set do_build=1
set do_default_gtests=1
set errorcount=0
:args_begin
    if "%~1"=="" goto args_end
    if "%~1"=="x64" ( set only_x64_platform=1 ) else (
    if "%~1"=="debug" ( set use_release_config=0 ) else (
    if "%~1"=="release" ( set use_debug_config=0 ) else (
    if "%~1"=="nobuild" ( set do_build=0 ) else (
    if "%~1"=="nogtests" ( set do_default_gtests=0 ) else (
        echo usage: run_tests.cmd [options]
        echo options:
        echo     x64          Only test the x64 build
        echo     debug        Only test the debug build
        echo     release      Only test the release build
        echo     nobuild      Don't build any configurations
        echo     nogtests     Don't run default test suite
        exit /b 1
    )))))
    shift
    goto args_begin
:args_end


:: -----------------------------------------------------------------------------
echo [96mVersion lookup...[90m
set version=
if exist "%pmdir%\PresentMon.props" (
    for /f "tokens=2,3 delims=<>" %%a in ('type "%pmdir%\PresentMon.props" ^| findstr "<PresentMonVersion>"') do (
        if "%%a"=="PresentMonVersion" set version=%%b
    )
)
if "%version%"=="" (
    echo [31merror: version not found in PresentMon.props[0m
    set /a errorcount=%errorcount%+1
) else (
    echo [90m%version%[0m
)
:version_end

:: -----------------------------------------------------------------------------
set build_configs=
if %use_debug_config%   EQU 1 set build_configs=%build_configs% debug
if %use_release_config% EQU 1 set build_configs=%build_configs% release

set build_platforms=x64
set test_platforms=x64
if %only_x64_platform% EQU 0 (
    set build_platforms=%build_platforms% x86
    set build_platforms=%build_platforms% arm
    set build_platforms=%build_platforms% arm64

    set test_platforms=%test_platforms% x86
)

set prebuild_errorcount=%errorcount%

echo.
echo [96mBuilding...[90m
if %do_build% EQU 0 (
    echo [31mwarning: skipping build[0m
) else (
    for %%a in (%build_platforms%) do for %%b in (%build_configs%) do call :build %%a %%b "PresentMon.sln"
    for %%a in (%test_platforms%)  do for %%b in (%build_configs%) do call :build %%a %%b "Tools\etw_list\etw_list.sln"
)

if %errorcount% neq %prebuild_errorcount% (
    echo [31mFAIL: build failed, cannot continue[0m
    exit /b 1
)

:: -----------------------------------------------------------------------------
:: If version check failed, grab it from one of the output exe file names
if "%version%"=="" (
    for %%a in (%build_platforms%) do for %%b in (%build_configs%) do (
        for /f "tokens=*" %%c in ('dir /b "%pmdir%\build\%%b\*-*-%%a.exe" 2^>NUL') do (
            for /f "tokens=2 delims=-" %%d in ("%%c") do (
                set version=%%d
            )
        )
    )
)

:: -----------------------------------------------------------------------------
echo.
echo [96mChecking generated files...[0m
for %%a in (%build_platforms%) do for %%b in (%build_configs%) do call :check_exist "build\%%b\PresentMon-%version%-%%a.exe"
for %%a in (%build_platforms%) do for %%b in (%build_configs%) do call :check_exist "build\%%b\PresentMonTests-%version%-%%a.exe"
for %%a in (%test_platforms%)  do for %%b in (%build_configs%) do call :check_exist "build\%%b\etw_list-%version%-%%a.exe"
for %%a in (%build_platforms%) do for %%b in (%build_configs%) do call :check_dlls_delayloaded "build\%%b\PresentMon-%version%-%%a.exe" %%a
for %%a in (%test_platforms%)  do for %%b in (%build_configs%) do call :check_pm_version "build\%%b\PresentMon-%version%-%%a.exe"

:: -----------------------------------------------------------------------------
echo.
echo [96mTesting functionality...[0m

if %use_release_config% EQU 1 (
    set pmtest=build\Release\PresentMonTests-%version%-x64.exe
) else (
    set pmtest=build\Debug\PresentMonTests-%version%-x64.exe
)

if %do_default_gtests% EQU 1 (
    for %%a in (%test_platforms%) do for %%b in (%build_configs%) do (
        call :gtests --presentmon="%pmdir%\build\%%b\PresentMon-%version%-%%a.exe" --golddir="%pmdir%\Tests\Gold"
    )
)


:: -----------------------------------------------------------------------------
if %errorcount% neq 0 (
    echo [31mFAIL: %errorcount% errors[0m
    exit /b 1
)

echo [32mPASS[0m
exit /b 0

:: -----------------------------------------------------------------------------
:build
    echo [90m%1-%2[0m
    msbuild /nologo /verbosity:quiet /maxCpuCount /property:Platform=%1,Configuration=%2 "%pmdir%\%~3"
    if %errorlevel% neq 0 (
        echo [31merror: build failed[0m
        set /a errorcount=%errorcount%+1
    )
    exit /b 0

:: -----------------------------------------------------------------------------
:check_exist
    if exist "%pmdir%\%~1" (
        echo [90m%~1[0m
    ) else (
        echo [31merror: expected build output missing: %~1[0m
        set /a errorcount=%errorcount%+1
    )
    exit /b 0

:: -----------------------------------------------------------------------------
:check_dlls_delayloaded
    if not exist "%programfiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" (
        echo [31merror: missing dependency: vswhere.exe[0m
        set /a errorcount=%errorcount%+1
        exit /b 1
    )
    set vsdir=
    for /f "tokens=*" %%a in ('"%programfiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -legacy -latest -property installationPath') do (
        set vsdir=%%a
    )
    if not exist "%vsdir%\VC\Tools\MSVC\14.29.30133\bin\Hostx64\%2\dumpbin.exe" (
        echo [31merror: missing dependency: dumpbin.exe[0m
        set /a errorcount=%errorcount%+1
        exit /b 1
    )
    set checkdll=0
    for /f "tokens=1,5" %%a in ('"%vsdir%\VC\Tools\MSVC\14.29.30133\bin\Hostx64\%2\dumpbin.exe" /dependents %~1') do (
        if "%%a"=="Image" (
            if "%%b"=="dependencies:" (
                call set checkdll=1
            ) else (
                call set checkdll=0
            )
        )
        if "%%~xa"==".dll" (
            if !checkdll! EQU 1 (
                if not "%%a"=="KERNEL32.dll" (
                    echo [31merror: dll dependency is not delay-loaded: %%a[0m
                    set /a errorcount=%errorcount%+1
                )
            )
        )
    )
    exit /b 0

:: -----------------------------------------------------------------------------
:check_pm_version
    if not exist "%pmdir%\%~1" exit /b 0
    set appver=
    for /f "tokens=1,2" %%a in ('"%pmdir%\%~1" --version 2^>^&1') do if "%%a"=="PresentMon" set appver=%%b
    if "%appver%"=="development" set appver=dev
    echo [90m%~1 -^> "%appver%"[0m
    if "%version%"=="dev" exit /b 0
    if "%version%" neq "%appver%" (
        echo [31merror: unexpected version reported: %~1 -^> "%appver%"[0m
        set /a errorcount=%errorcount%+1
    )
    exit /b 0

:: -----------------------------------------------------------------------------
:gtests
    echo [90m"%pmdir%\%pmtest%" %*[0m
    "%pmdir%\%pmtest%" %*
    if not "%errorlevel%"=="0" set /a errorcount=%errorcount%+1
    exit /b 0
