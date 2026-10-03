# tools/build-windows.ps1 — build, gate, and optionally package the Windows
# (MSVC, x64) artifact.
#
# Copyright 2026 Fojle Rabbi (Rabib)
# SPDX-License-Identifier: Apache-2.0
#
# The Windows counterpart of tools/build-el8.sh: it drives the canonical
# phpize path (phpize.bat -> configure -> nmake, which runs config.w32 and the
# cargo shim build inside it), validates the PE artifact, and runs the same
# gates the ELF and Mach-O families run. Runs on a GitHub windows runner with
# the MSVC environment active (ilammy/msvc-dev-cmd provides it in CI) and Git
# Bash available for the POSIX gate scripts.
#
# Usage:
#   tools/build-windows.ps1 -PhpVersion 8.3
#   tools/build-windows.ps1 -PhpVersion 8.4 -Package -ReleaseTag v0.2.0
#
# PHP's Windows builds do not share one toolchain: 8.3 is VS16 (VS2019), and
# 8.4+ moved to VS17 (VS2022). PIE reads the compiler segment from the target
# PHP's phpinfo, so every resolved download and asset name follows this map.
# Building with a newer toolset than the target PHP is ABI-safe (the MSVC ABI
# has been stable since VS2015); the gate proves the pair actually loads.
[CmdletBinding()]
param(
	[ValidateSet('8.3', '8.4', '8.5')]
	[string]$PhpVersion = '8.3',
	[string]$ReleaseTag = '',
	[switch]$Package
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Build = Join-Path $Root 'build'
$VsTag = @{ '8.3' = 'vs16' }[$PhpVersion]
if (-not $VsTag) { $VsTag = 'vs17' }

function Assert-LastExit($Step) {
	if ($LASTEXITCODE -ne 0) { throw "$Step failed with exit code $LASTEXITCODE" }
}

# cl/link/dumpbin come from the active MSVC environment, not from this script.
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
	throw 'MSVC environment is not active: cl.exe not found on PATH (run vcvarsall/vsdevcmd first).'
}

$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
	throw 'cargo not found; install Rust >= 1.85 (resvg 0.48.x MSRV) via rustup.'
}

New-Item -ItemType Directory -Force -Path $Build | Out-Null
$Tools = Join-Path $Build "win-tools-$PhpVersion"
New-Item -ItemType Directory -Force -Path $Tools | Out-Null

# --- [1/6] fetch the pinned resvg source (the single fetch+verify path) -----
Write-Host '>> [1/6] fetch and verify the pinned resvg source'
bash "$Root/tools/fetch-resvg.sh"
Assert-LastExit 'fetch-resvg'

# --- [2/6] resolve and download the matching PHP runtime and dev pack ------
Write-Host ">> [2/6] resolve PHP $PhpVersion ($VsTag, x64, NTS) runtime and dev pack"
$index = (Invoke-WebRequest -UseBasicParsing 'https://downloads.php.net/~windows/releases/').Content

# The -latest- aliases on the CDN 404 for some packs, so resolve the newest
# concrete version from the directory listing itself.
function Resolve-Newest($pattern) {
	$names = [regex]::Matches($index, $pattern) | ForEach-Object { $_.Value } | Sort-Object -Unique
	if (-not $names) { throw "no PHP release matched $pattern" }
	$names | Sort-Object { [version]([regex]::Match($_, '8\.\d+\.\d+').Value) } | Select-Object -Last 1
}
$devPackZip = Resolve-Newest "php-devel-pack-$PhpVersion\.\d+-nts-Win32-$VsTag-x64\.zip"
$runtimeZip = Resolve-Newest "php-$PhpVersion\.\d+-nts-Win32-$VsTag-x64\.zip"
foreach ($name in @($devPackZip, $runtimeZip)) {
	$dest = Join-Path $Tools $name
	if (-not (Test-Path $dest)) {
		Write-Host "   downloading $name"
		# Current releases live at the top level; older patches are archived.
		try {
			Invoke-WebRequest -UseBasicParsing "https://downloads.php.net/~windows/releases/$name" -OutFile $dest
		} catch {
			Invoke-WebRequest -UseBasicParsing "https://downloads.php.net/~windows/releases/archives/$name" -OutFile $dest
		}
	}
	Expand-Archive -Path $dest -DestinationPath $Tools -Force
}
# Locate by content rather than by the archive's root directory name, which
# has changed spelling across PHP releases.
$devPackDir = (Get-ChildItem $Tools -Recurse -Filter 'phpize.bat' | Select-Object -First 1).DirectoryName
$runtimeDir = (Get-ChildItem $Tools -Recurse -Filter 'php.exe' | Select-Object -First 1).DirectoryName
if (-not $devPackDir) { throw 'phpize.bat not found in the dev pack' }
if (-not $runtimeDir) { throw 'php.exe not found in the runtime zip' }
$env:Path = "$runtimeDir;$env:Path"

# --- [3/6] assemble the extension build directory ---------------------------
Write-Host '>> [3/6] assemble the extension build directory'
$ExtDir = Join-Path $Build "resvg-ext-$PhpVersion-w32"
if (Test-Path $ExtDir) {
	# Junctions must be removed as reparse points before the recursive delete:
	# Remove-Item -Recurse would otherwise walk them into the real native/ and
	# vendor-src/ trees and destroy the shared cargo target directory.
	Get-ChildItem $ExtDir | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
		ForEach-Object { [IO.Directory]::Delete($_.FullName) }
	Remove-Item -Recurse -Force $ExtDir
}
New-Item -ItemType Directory -Force -Path $ExtDir | Out-Null
$extSources = @('config.w32', 'php_resvg.h', 'resvg.c', 'resvg_options.c',
	'resvg_exception.c', 'resvg_renderer.c', 'resvg_document.c',
	'resvg.stub.php', 'resvg_arginfo.h', 'resvg_internal.h')
foreach ($name in $extSources) {
	Copy-Item (Join-Path $Root $name) $ExtDir
}
# phpize builds in place, so the shim crate and the vendored source ride along
# as junctions; cargo writes its target under the real native/ directory.
foreach ($name in @('native', 'vendor-src')) {
	New-Item -ItemType Junction -Path (Join-Path $ExtDir $name) -Target (Join-Path $Root $name) | Out-Null
}

# --- [4/6] phpize -> configure -> nmake (the canonical path) ----------------
Write-Host ">> [4/6] phpize + configure + nmake (PHP $PhpVersion)"

# PHP's Windows build system (configure.js) requires bison >= 3.0, re2c and
# sed on PATH even for extension-only builds, where none of them is ever
# invoked — the shipped headers carry pre-generated parsers. The workflow
# provisions MSYS2 (msys2/setup-msys2) before calling this script; appending
# keeps MSYS tools behind the MSVC toolset for anything name-colliding.
$msysUsrBin = "$env:SystemDrive\msys64\usr\bin"
if (Test-Path "$msysUsrBin\bison.exe") {
	$env:Path = "$env:Path;$msysUsrBin"
} elseif (-not (Get-Command bison.exe -ErrorAction SilentlyContinue)) {
	throw 'bison.exe not found; PHP configure requires it (install MSYS2 or provide bison, re2c, and sed on PATH)'
}

$buildLog = Join-Path $Build "w32-$PhpVersion.log"
Push-Location $ExtDir
try {
	& (Join-Path $devPackDir 'phpize.bat') > $buildLog
	if ($LASTEXITCODE -ne 0) { Get-Content $buildLog -Tail 40; throw 'phpize failed' }

	& (Join-Path $ExtDir 'configure.bat') '--enable-resvg' >> $buildLog
	if ($LASTEXITCODE -ne 0) { Get-Content $buildLog -Tail 40; throw 'configure failed' }

	& cmd /c "nmake >> `"$buildLog`" 2>&1"
	if ($LASTEXITCODE -ne 0) { Get-Content $buildLog -Tail 60; throw 'nmake failed' }
} finally {
	Pop-Location
}
$dll = Get-ChildItem -Path $ExtDir -Recurse -Filter 'php_resvg.dll' | Select-Object -First 1
if (-not $dll) { Get-Content $buildLog -Tail 60; throw 'nmake reported success but php_resvg.dll was not produced' }
$Out = Join-Path $Build "resvg-php$PhpVersion.dll"
Copy-Item $dll.FullName $Out -Force
Write-Host "   built: $Out ($([math]::Round((Get-Item $Out).Length / 1MB, 1)) MB)"

# --- [5/6] PE artifact gates -------------------------------------------------
Write-Host '>> [5/6] validate exports, dependencies, and hardening'
$exportText = & dumpbin /EXPORTS $Out | Out-String
Assert-LastExit 'dumpbin /EXPORTS'
# dumpbin data lines are "ordinal hint RVA name" — all three columns precede
# the export name, which is the capture group.
$exported = ($exportText | Select-String '(?m)^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\S+)' -AllMatches).Matches |
	ForEach-Object { $_.Groups[1].Value }
Write-Host "   dynamic exports: $($exported -join ' ')"
$extra = @($exported | Where-Object { $_ -ne 'get_module' })
if ($extra.Count -ne 0) {
	throw "export table must be exactly {get_module}, found: $($extra -join ', ')"
}

$dependentText = & dumpbin /DEPENDENTS $Out | Out-String
$dependents = ($dependentText | Select-String '(?m)^\s+(\S+\.dll)' -AllMatches).Matches |
	ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() } | Sort-Object -Unique
Write-Host "   linked libraries: $($dependents -join ' ')"
# Deny-by-default allowlist of system libraries. The api-ms-win-* entries are
# Microsoft's api-set forwarders for the UCRT and core synchronization — the
# layout the VS18 toolchain actually links — with the classic UCRT names kept
# for older toolchains.
$allowed = @('advapi32.dll', 'api-ms-win-core-synch-l1-2-0.dll',
	'api-ms-win-crt-heap-l1-1-0.dll', 'api-ms-win-crt-math-l1-1-0.dll',
	'api-ms-win-crt-runtime-l1-1-0.dll', 'api-ms-win-crt-string-l1-1-0.dll',
	'bcrypt.dll', 'bcryptprimitives.dll', 'kernel32.dll', 'msvcrt.dll',
	'ntdll.dll', 'php8.dll', 'ucrtbase.dll', 'userenv.dll',
	'vcruntime140.dll', 'vcruntime140_1.dll', 'ws2_32.dll')
$unexpected = @($dependents | Where-Object { $allowed -notcontains $_ })
if ($unexpected.Count -ne 0) { throw "unexpected dynamic dependencies: $($unexpected -join ', ')" }

# The load configuration carries ASLR and DEP as "… Yes" flags.
$headerText = & dumpbin /HEADERS $Out | Out-String
if ($headerText -notmatch 'Dynamic base\s+Yes') { throw 'DYNAMICBASE (ASLR) is absent' }
if ($headerText -notmatch 'NX compatible\s+Yes') { throw 'NXCOMPAT (DEP) is absent' }
Write-Host '   PE OK (single export, pinned dependencies, ASLR + DEP)'

# --- [6/6] the fidelity gate and the local battery --------------------------
Write-Host '>> [6/6] fidelity gate, PHPT, examples'
$env:PHP_VERSION = $PhpVersion
bash "$Root/tools/test-fidelity.sh" $Out
Assert-LastExit 'fidelity gate'
php "$Root/tools/test-phpt.php" $Out
Assert-LastExit 'test-phpt'
bash "$Root/tools/test-examples.sh" $Out
Assert-LastExit 'examples'

# --- optional: package the PIE-canonical assets ------------------------------
if (-not $Package) {
	Write-Host '>> packaging skipped (pass -Package)'
	exit 0
}

Write-Host '>> packaging PIE assets'
$version = (Select-String -Path (Join-Path $Root 'php_resvg.h') -Pattern '#define PHP_RESVG_VERSION "(.*?)"').Matches[0].Groups[1].Value
if (-not $version) { throw 'PHP_RESVG_VERSION not found in php_resvg.h' }

# PIE resolves Windows assets as
# php_{name}-{version}-{php}-{nts|ts}-{compiler}-{arch}.zip and then looks for
# the identically-named .dll inside. The archive carries only the DLL, and the
# version appears in both spellings PIE may resolve (release and tag).
$dist = Join-Path $Build 'dist'
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$spellings = @($version)
if ($ReleaseTag) { $spellings += $ReleaseTag }
foreach ($spelling in $spellings) {
	$zipName = "php_resvg-$spelling-$PhpVersion-nts-$VsTag-x86_64.zip".ToLowerInvariant()
	$dllName = [IO.Path]::ChangeExtension($zipName, '.dll')
	$stage = Join-Path $Build "stage-$PhpVersion"
	if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
	New-Item -ItemType Directory -Force -Path $stage | Out-Null
	Copy-Item $Out (Join-Path $stage $dllName)
	Compress-Archive -Path (Join-Path $stage $dllName) -DestinationPath (Join-Path $dist $zipName)
	Remove-Item -Recurse -Force $stage
	Write-Host "   packaged PIE asset: $zipName"
}

$bareName = "resvg-php$PhpVersion-windows-x86_64.dll"
Copy-Item $Out (Join-Path $dist $bareName)
Write-Host "   emitted bare asset: $bareName"

$apiLine = Select-String -Path (Join-Path $devPackDir 'include\Zend\zend_modules.h') `
	-Pattern '#define ZEND_MODULE_API_NO (\d+)'
$gitRev = 'unknown'
if (Get-Command git -ErrorAction SilentlyContinue) {
	$gitRev = git -C $Root rev-parse HEAD 2>$null
	if (-not $gitRev) { $gitRev = 'unknown' }
}
$provenance = "resvg-php$PhpVersion-windows-x86_64.provenance"
@(
	"version=$version",
	"php=$PhpVersion",
	"php_api=$($apiLine.Matches[0].Groups[1].Value)",
	'arch=x86_64',
	'os=windows',
	"compiler=$VsTag",
	"commit=$gitRev",
	"sha256=$((Get-FileHash -Algorithm SHA256 $Out).Hash.ToLowerInvariant())"
) | Set-Content (Join-Path $dist $provenance)
Write-Host ">> release assets written to $dist"
