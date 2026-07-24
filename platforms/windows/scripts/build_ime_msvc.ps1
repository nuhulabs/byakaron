# Manual MSVC build of ByakaronIME.dll (VS PlatformToolsets may be incomplete).
$ErrorActionPreference = "Stop"
Set-Location c:\Users\nurulhudaapon\Projects\byakaron\platforms\windows\Keyboard

$msvcRoot = "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\MSVC\14.51.36231"
if (-not (Test-Path -LiteralPath (Join-Path $msvcRoot "include\excpt.h"))) {
  $msvcRoot = "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231"
}
if (-not (Test-Path -LiteralPath (Join-Path $msvcRoot "bin\Hostx64\x64\cl.exe"))) {
  throw "MSVC cl.exe not found"
}
Write-Host "Using MSVC: $msvcRoot"
$sdkRoot = "C:\Program Files (x86)\Windows Kits\10"
$sdkVer = "10.0.26100.0"
$repo = "c:\Users\nurulhudaapon\Projects\byakaron"
$outDir = Join-Path (Get-Location) "bin\x64\Release"
$objDir = Join-Path (Get-Location) "obj\x64\Release"
New-Item -ItemType Directory -Force -Path $outDir, $objDir | Out-Null

$env:PATH = "$(Join-Path $msvcRoot 'bin\Hostx64\x64');$env:PATH"

$cl = Join-Path $msvcRoot "bin\Hostx64\x64\cl.exe"
$link = Join-Path $msvcRoot "bin\Hostx64\x64\link.exe"

$srcs = @("DllMain.cpp", "KeyHandler.cpp", "TextService.cpp", "Transliterator.cpp")
$objs = @()
foreach ($src in $srcs) {
  $obj = Join-Path $objDir ($src -replace '\.cpp$', '.obj')
  $objs += $obj
  Write-Host ">>> cl $src"
  & $cl /nologo /std:c++17 /EHsc /MD /O2 /W3 /DUNICODE /D_UNICODE /DWIN32 /D_WINDOWS /D_USRDLL `
    "/I$(Join-Path $msvcRoot 'include')" `
    "/I$(Join-Path $sdkRoot "Include\$sdkVer\ucrt")" `
    "/I$(Join-Path $sdkRoot "Include\$sdkVer\um")" `
    "/I$(Join-Path $sdkRoot "Include\$sdkVer\shared")" `
    "/I$(Join-Path $repo 'zig-out\include')" `
    /I. `
    /c $src "/Fo$obj"
  if ($LASTEXITCODE -ne 0) { throw "compile failed: $src" }
}

Write-Host ">>> link ByakaronIME.dll"
& $link /nologo /DLL "/OUT:$outDir\ByakaronIME.dll" `
  /DEF:ByakaronIME.def `
  "/LIBPATH:$(Join-Path $msvcRoot 'lib\x64')" `
  "/LIBPATH:$(Join-Path $sdkRoot "Lib\$sdkVer\ucrt\x64")" `
  "/LIBPATH:$(Join-Path $sdkRoot "Lib\$sdkVer\um\x64")" `
  "/LIBPATH:$(Join-Path $repo 'zig-out\lib')" `
  $objs `
  ole32.lib oleaut32.lib uuid.lib advapi32.lib user32.lib
if ($LASTEXITCODE -ne 0) { throw "link failed" }

Write-Host ">>> OK $outDir\ByakaronIME.dll"
Get-Item "$outDir\ByakaronIME.dll" | Format-List FullName, Length
