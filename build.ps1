<#
.SYNOPSIS
    Assemble a CXRF program (kernel, spike, test or app) and optionally
    run it. Follows the x16_library build_ca65.ps1 harness contract:
    -Test greps CHROUT output for PASS/FAIL/SKIP/DONE lines.

.EXAMPLE
    .\build.ps1 -Source spikes\spike_a.asm -Run     # windowed
    .\build.ps1 -Source spikes\spike_a.asm -Capture # capture CHROUT output
    .\build.ps1 -Test                               # regression suite, headless
#>
param(
    [string]$Source = "test\runner.asm",
    [string]$Config = "prg.cfg",
    [switch]$Test,
    [switch]$Run,
    [switch]$Capture,      # run windowed with -warp, capture -echo output until DONE
    [switch]$Kernel,       # build the resident image against kernel/kernel.cfg
    [switch]$Apps,         # build AUTOBOOT.X16, the shell and the hellos
    [switch]$Image,        # ...and stage a bootable SD root in build\sdroot
    [switch]$Boot,         # ...and boot it, windowed, from the staged root
    [switch]$Cart,         # build the cartridge image (ROM banks 32-36); with -Boot, run it via -cartbin
    [string]$App = "",     # with -Cart: bake this .CXA into the cart (ROM bank 37) as a STANDALONE, no-SD appliance -- e.g. -Cart -App build\PAINT.CXA
    [int]$Scale = 1,
    [int]$TimeoutSec = 90
)

$ErrorActionPreference = "Stop"

function Fail([string]$message) {
    Write-Host $message -ForegroundColor Red
    exit 1
}

$root  = $PSScriptRoot
$emu   = Join-Path $root "emulator\x16emu.exe"
$rom   = Join-Path $root "emulator\rom.bin"
$lib   = Join-Path $root "x16lib"
$build = Join-Path $root "build"

$ca65 = Join-Path $root "cc65\ca65.exe"
$ld65 = Join-Path $root "cc65\ld65.exe"
foreach ($tool in @($ca65, $ld65, $emu, $rom)) {
    if (-not (Test-Path $tool)) { Fail "missing: $tool (see README.md)" }
}
if (-not (Test-Path $build)) { New-Item -ItemType Directory -Path $build | Out-Null }

# -Kernel builds the resident image: the header at $8000, the jump table
# at $8010 and the code at $8160, which are the addresses every app is
# built against. ld65 fails the link if the code overruns $95FF, so the
# budget enforces itself -- and mapreport.py prints how close it came.
# See docs/memory-map.md for the ledger.
if ($Kernel) {
    $Source = "kernel\kernel.asm"
    $Config = "kernel\kernel.cfg"
}

function Build-KernelImage {
    $o = Join-Path $build "CXKERNEL.o"
    $p = Join-Path $build "CXKERNEL.PRG"
    Write-Host "ca65  kernel\kernel.asm -> $p"
    & $ca65 --cpu 65C02 -I $lib -I $root -o $o (Join-Path $root "kernel\kernel.asm")
    if ($LASTEXITCODE -ne 0) { Fail "ca65 failed on the kernel" }
    # from the root: kernel.cfg's second output file, build\CXBANKS.BIN,
    # is a path relative to wherever ld65 stands
    Push-Location $root
    & $ld65 -C (Join-Path $root "kernel\kernel.cfg") -m (Join-Path $build "CXKERNEL.map") -o $p $o
    $ldExit = $LASTEXITCODE
    Pop-Location
    if ($ldExit -ne 0) { Fail "ld65 failed on the kernel (over budget?)" }
    Write-Host "      $((Get-Item $p).Length) bytes + $((Get-Item (Join-Path $build 'CXBANKS.BIN')).Length) + $((Get-Item (Join-Path $build 'CXBANKS2.BIN')).Length) banked"
    # the budget, read back from the map: what each region used, what is
    # left, and which wall is nearest (tools/mapreport.py)
    $pyc = Get-Command python -ErrorAction SilentlyContinue
    if ($pyc) {
        & $pyc.Source (Join-Path $root "tools\mapreport.py") (Join-Path $build "CXKERNEL.map")
        if ($LASTEXITCODE -ne 0) { Fail "mapreport: a memory region is over budget or a pin moved" }
    }
}

# The cartridge image: the same kernel, delivered in ROM instead of on SD.
# kernel/boot/cart.asm is the bank-32 boot stub; it .incbin's the just-built
# CXKERNEL.PRG, CXBANKS.BIN, CXBANKS2.BIN and the font by CWD-relative path,
# so this must run after Build-KernelImage and from the repo root. Output is
# a raw 80 KB image (ROM banks 32-36) that x16emu -cartbin loads at bank 32.
function Build-CartImage([string]$appCxa = "") {
    $o   = Join-Path $build "cart.o"
    $bin = Join-Path $build "cxrf_cart.bin"
    $cfg = Join-Path $root "kernel\boot\cart.cfg"
    $defs = @()
    if ($appCxa) {
        # Standalone: bake the app's CXA into ROM bank 37. The stub copies its
        # payload to $0801 and runs it -- no SD card in the loop. The image is
        # named after the app so it stands apart from the plain framework cart.
        if (-not (Test-Path $appCxa)) { Fail "cart -App: '$appCxa' not found" }
        $appbase = ([IO.Path]::GetFileNameWithoutExtension($appCxa)).ToLower()
        $bin = Join-Path $build "cxrf_cart_$appbase.bin"
        $cxa = Join-Path $build "CARTAPP.CXA"
        Copy-Item $appCxa $cxa -Force
        if ((Get-Item $cxa).Length -gt 0x4000) {
            Fail "cart -App: '$appCxa' is $((Get-Item $cxa).Length) bytes; the baked-in app must fit one 16 KB ROM bank"
        }
        $cfg = Join-Path $root "kernel\boot\cart_app.cfg"
        $defs = @('-D', 'CART_APP=1')
        Write-Host "ca65  kernel\boot\cart.asm (+ $([IO.Path]::GetFileName($appCxa)) baked into bank 37) -> $bin"
    } else {
        Write-Host "ca65  kernel\boot\cart.asm -> $bin"
    }
    Push-Location $root
    & $ca65 --cpu 65C02 @defs -I $lib -I $root -o $o (Join-Path $root "kernel\boot\cart.asm")
    $ex = $LASTEXITCODE
    if ($ex -eq 0) {
        & $ld65 -C $cfg -o $bin $o
        $ex = $LASTEXITCODE
    }
    Pop-Location
    if ($ex -ne 0) { Fail "cart image build failed" }
    $topbank = 31 + [int]((Get-Item $bin).Length / 0x4000)
    Write-Host "      $((Get-Item $bin).Length) bytes (cart ROM banks 32-$topbank)"
    return $bin
}

# -Apps / -Image / -Boot orchestrate several builds; the single-PRG path
# below is for everything else (the default runner, a spike, -Kernel).
$single = -not ($Apps -or $Image -or $Boot)

if ($single) {
    $name = [IO.Path]::GetFileNameWithoutExtension($Source).ToUpper()
    if ($Kernel) { $name = "CXKERNEL" }
    $obj  = Join-Path $build "$name.o"
    $out  = Join-Path $build "$name.PRG"
    $map  = Join-Path $build "$name.map"

    Write-Host "ca65  $Source -> $out"
    & $ca65 --cpu 65C02 -I $lib -I $root -o $obj (Join-Path $root $Source)
    if ($LASTEXITCODE -ne 0) { Fail "ca65 assembly failed" }
    & $ld65 -C (Join-Path $root $Config) -m $map -o $out $obj
    if ($LASTEXITCODE -ne 0) { Fail "ld65 link failed" }

    $size = (Get-Item $out).Length
    Write-Host "      $size bytes"
    if ($Kernel) {
        $pyc = Get-Command python -ErrorAction SilentlyContinue
        if ($pyc) {
            & $pyc.Source (Join-Path $root "tools\mapreport.py") $map
            if ($LASTEXITCODE -ne 0) { Fail "mapreport: a memory region is over budget or a pin moved" }
        }
    }
}

# --- run the emulator and capture CHROUT output until a pattern --------
function Invoke-Emulator([string[]]$emuArgs, [int]$timeout, [string]$until, [string]$tag) {
    $stdin  = Join-Path $env:TEMP "cxrf-empty.in"
    $stdout = Join-Path $build "$tag-output.txt"
    [IO.File]::WriteAllText($stdin, "")
    if (Test-Path $stdout) { Remove-Item $stdout -Force }

    # -bitmap2 enables the VERA_2 second video plane (the MiSTer core's
    # SDRAM bitmap layer) so mode 4 (CX_MODE_BMPHI, 640x480 4/8bpp) works;
    # harmless for the other modes, so every invocation gets it by default.
    $emuArgs = @('-rom', $rom) + $emuArgs + @('-bitmap2', '-warp', '-echo')
    $proc = Start-Process -FilePath $emu -ArgumentList $emuArgs -NoNewWindow -PassThru `
                          -RedirectStandardInput $stdin -RedirectStandardOutput $stdout

    $deadline = (Get-Date).AddSeconds($timeout)
    $text = ""
    while ($true) {
        Start-Sleep -Milliseconds 200
        if (Test-Path $stdout) {
            $text = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) -replace "`r", ""
            if ($text -match $until) { break }
        }
        if ($proc.HasExited) { break }
        if ((Get-Date) -gt $deadline) {
            if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }
            Fail "emulator timed out after ${timeout}s -- nothing matched '$until'"
        }
    }
    # the process may win the race and exit between the check and the
    # kill; either way it is gone, which is all that was wanted
    if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }
    $proc.WaitForExit()
    # read once more after the exit: a guest that ends at BASIC (the
    # boot refusals) can take the emulator down between two polls, and
    # the loop's last read would miss whatever flushed at the end
    if (Test-Path $stdout) {
        $text = (Get-Content $stdout -Raw -ErrorAction SilentlyContinue) -replace "`r", ""
    }
    return $text
}

# --- the apps: assemble a PRG, wrap it as a CXAP ------------------------
function Build-Prg([string]$src, [string]$prgName, [string]$cfg = "prg.cfg") {
    $o = Join-Path $build "$prgName.o"
    $p = Join-Path $build "$prgName.PRG"
    Write-Host "ca65  $src -> $p"
    & $ca65 --cpu 65C02 -I $lib -I $root -o $o (Join-Path $root $src)
    if ($LASTEXITCODE -ne 0) { Fail "ca65 failed on $src" }
    & $ld65 -C (Join-Path $root $cfg) -o $p $o
    if ($LASTEXITCODE -ne 0) { Fail "ld65 failed on $src" }
    return $p
}

function Build-Apps {
    $py = (Get-Command python -ErrorAction Stop).Source
    $mkcxap = Join-Path $root "tools\mkcxap.py"

    $boot = Build-Prg "kernel\boot\auto.asm" "AUTOBOOT"
    Copy-Item $boot (Join-Path $build "AUTOBOOT.X16") -Force

    foreach ($app in @(
        @{ src = "apps\filer\filer.asm";        prg = "SHELL";    name = "Desktop" },
        @{ src = "apps\hello_asm\hello.asm";    prg = "HELLO1";   name = "Hello (asm)" },
        @{ src = "test\menutest\menutest.asm";  prg = "MENUTEST"; name = "Menu test" },
        @{ src = "apps\gallery\gallery.asm";     prg = "GALLERY";  name = "Widget gallery" },
        @{ src = "apps\hittest\hittest.asm";     prg = "HITTEST";  name = "Hit regions" },
        @{ src = "apps\cpanel\cpanel.asm";       prg = "CPANEL";   name = "Control panel" },
        @{ src = "apps\tui\tui.asm";             prg = "TUI";      name = "Toolkit (text)" },
        @{ src = "apps\tuigeo\tuigeo.asm";       prg = "TUIGEO";   name = "Text sizes" },
        @{ src = "test\geosmoke\geosmoke.asm";   prg = "GEOSMOKE"; name = "Geo smoke" },
        @{ src = "apps\m1ui\m1ui.asm";           prg = "M1UI";     name = "Toolkit (8bpp)" },
        @{ src = "apps\gameloop\gameloop.asm";    prg = "GAMELOOP"; name = "Game + dialog" }
    )) {
        $p = Build-Prg $app.src $app.prg
        & $py $mkcxap $p (Join-Path $build "$($app.prg).CXA") --name $app.name
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on $($app.prg)" }
    }

    # the notes desk accessory: a bare PRG at $A000, no CXAP wrapper --
    # the DA manager loads it raw into bank 9
    $da = Build-Prg "apps\da_notes\notes.asm" "NOTES" "da.cfg"
    Copy-Item $da (Join-Path $build "NOTES.CXD") -Force

    # CXRF Word: X16 Edit (vendored) + the CXRF host wrapper. Two ca65
    # objects and its own cfg (the ZP rides the app window, the ceiling
    # is $8000); the lzsa help binaries ship pre-compressed beside the
    # sources, so no lzsa tool is needed to build.
    $wordDir = Join-Path $root "apps\word"
    Write-Host "ca65  apps\word\word.asm + main.asm -> build\WORD.PRG"
    & $ca65 --cpu 65C02 -D target_mem=1 -I $wordDir --bin-include-dir $wordDir -o (Join-Path $build "word_main.o") (Join-Path $wordDir "main.asm")
    if ($LASTEXITCODE -ne 0) { Fail "ca65 failed on word\main.asm" }
    & $ca65 --cpu 65C02 -I $root -o (Join-Path $build "word_stub.o") (Join-Path $wordDir "word.asm")
    if ($LASTEXITCODE -ne 0) { Fail "ca65 failed on word\word.asm" }
    & $ld65 -C (Join-Path $wordDir "word.cfg") -o (Join-Path $build "WORD.PRG") (Join-Path $build "word_stub.o") (Join-Path $build "word_main.o")
    if ($LASTEXITCODE -ne 0) { Fail "ld65 failed on WORD" }
    & $py $mkcxap (Join-Path $build "WORD.PRG") (Join-Path $build "WORD.CXA") --name "CXRF Word"
    if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on WORD" }

    # hello_c wants llvm-mos; a machine without it still builds the rest
    $mosbin = $null
    $candidates = @()
    if ($env:LLVM_MOS_HOME) { $candidates += (Join-Path $env:LLVM_MOS_HOME "bin") }
    $candidates += "C:\quartus\projects\x16_clib\llvm-mos\bin", "C:\llvm-mos\bin"
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c "mos-cx16-clang.bat")) { $mosbin = $c; break }
    }
    if ($mosbin) {
        # -mreserve-zp=90 keeps clang's whole-program pass out of $26-$7F,
        # all of which belongs to the kernel or to the app ZP convention;
        # the sdk header's cx_run() handles the $22-$25 collision with the
        # compiler's own soft stack pointer.
        #
        # The C soft stack: the cx16 target's link script pins __stack at
        # $9F00 growing DOWN -- through the kernel's graphics port at
        # $9600-$9EFF -- and a --defsym cannot override its plain
        # assignment. The sdk header plants a constructor that moves the
        # stack pointer to $8000 before main, so an app's frames live in
        # the $0801-$7FFF it actually owns (the text demo's fifth cx_say
        # printed a clobbered pointer's garbage; that was a mode switch
        # copying an engine image over a stack frame at $96xx).
        foreach ($capp in @(
            @{ src = "apps\hello_c\hello.c"; prg = "HELLO2"; name = "Hello (C)" },
            @{ src = "apps\calc\calc.c";     prg = "CALC";   name = "Calculator" },
            @{ src = "apps\cdemo\cdemo.c";   prg = "CDEMO";  name = "C Demo" },
            @{ src = "apps\paint\paint.c";   prg = "PAINT";  name = "Paint" },
            @{ src = "apps\beep\beep.c";     prg = "BEEP";   name = "Beep" },
            @{ src = "apps\sprite\sprite.c"; prg = "SPRITE"; name = "Sprite" },
            @{ src = "apps\gfx8\gfx8.c";     prg = "GFX8";   name = "256 colours" },
            @{ src = "apps\gfx8hi\gfx8hi.c"; prg = "GFX8HI"; name = "640x480 8bpp" },
            @{ src = "apps\gfx4\gfx4.c";     prg = "GFX4";   name = "320x240 4bpp" },
            @{ src = "apps\gfx2\gfx2.c";     prg = "GFX2";   name = "320x240 2bpp" },
            @{ src = "apps\gfx4hi\gfx4hi.c"; prg = "GFX4HI"; name = "640x480 4bpp" },
            @{ src = "apps\tiles\tiles.c";   prg = "TILES";  name = "Tiles" },
            @{ src = "apps\tiles8\tiles8.c"; prg = "TILES8"; name = "8bpp tiles" },
            @{ src = "apps\tiletext\tiletext.c"; prg = "TILETEXT"; name = "Tile text" },
            @{ src = "apps\tiledlg\tiledlg.c";   prg = "TILEDLG";  name = "Tile dialog" },
            @{ src = "apps\text\text.c";     prg = "TEXT";   name = "Text mode" },
            @{ src = "apps\sheet\sheet.c";   prg = "SHEET";  name = "CXRF Sheet" }
        )) {
            $prg = Join-Path $build "$($capp.prg).PRG"
            Write-Host "llvm  $($capp.src) -> $prg"
            & (Join-Path $mosbin "mos-cx16-clang.bat") -Os -mreserve-zp=90 -I $root -o $prg (Join-Path $root $capp.src)
            if ($LASTEXITCODE -ne 0) { Fail "mos-cx16-clang failed on $($capp.src)" }
            & $py $mkcxap $prg (Join-Path $build "$($capp.prg).CXA") --name $capp.name
            if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on $($capp.prg)" }
        }
    } else {
        Write-Host "llvm-mos not found: skipping the C apps" -ForegroundColor Yellow
    }

    # --- the multi-toolchain SDK smokes ---------------------------------
    # Each proves a GENERATED SDK variant drives the kernel end to end. The
    # binaries live in the sibling x16_library / x16_clib; a machine without
    # one skips that smoke, exactly like llvm-mos above. mkcxap wraps any
    # $0801 PRG, so the .CXA/boot stages are toolchain-agnostic.
    $xlib = "C:\quartus\projects\x16_library"

    $t64 = "$xlib\64tass\64tass.exe"; $src64 = "$xlib\src_64tass"
    if ((Test-Path $t64) -and (Test-Path $src64)) {
        $prg = Join-Path $build "SMOKE64.PRG"
        Write-Host "64tass apps\smoke_64tass\smoke.asm -> $prg"
        & $t64 -C -a --cbm-prg -I $root -I $src64 -o $prg (Join-Path $root "apps\smoke_64tass\smoke.asm")
        if ($LASTEXITCODE -ne 0) { Fail "64tass failed on the smoke app (asmsdk/64tass)" }
        & $py $mkcxap $prg (Join-Path $build "SMOKE64.CXA") --name "Smoke (64tass)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKE64" }
    } else { Write-Host "64tass not found: skipping the 64tass smoke" -ForegroundColor Yellow }

    $acme = "$xlib\acme\acme.exe"; $srcAcme = "$xlib\src_acme"
    if ((Test-Path $acme) -and (Test-Path $srcAcme)) {
        $prg = Join-Path $build "SMOKEACME.PRG"
        Write-Host "acme  apps\smoke_acme\smoke.asm -> $prg"
        & $acme -I $root -I $srcAcme -f cbm -o $prg (Join-Path $root "apps\smoke_acme\smoke.asm")
        if ($LASTEXITCODE -ne 0) { Fail "acme failed on the smoke app (asmsdk/acme)" }
        & $py $mkcxap $prg (Join-Path $build "SMOKEACME.CXA") --name "Smoke (acme)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKEACME" }
    } else { Write-Host "acme not found: skipping the acme smoke" -ForegroundColor Yellow }

    $dasm = "$xlib\dasm\dasm.exe"; $srcDasm = "$xlib\src_dasm"
    if ((Test-Path $dasm) -and (Test-Path $srcDasm)) {
        $prg = Join-Path $build "SMOKEDASM.PRG"
        Write-Host "dasm  apps\smoke_dasm\smoke.asm -> $prg"
        # dasm -f1 prepends the PRG load address; flags take no space
        & $dasm (Join-Path $root "apps\smoke_dasm\smoke.asm") "-I$root" "-I$srcDasm" -f1 "-o$prg"
        if ($LASTEXITCODE -ne 0) { Fail "dasm failed on the smoke app (asmsdk/dasm)" }
        & $py $mkcxap $prg (Join-Path $build "SMOKEDASM.CXA") --name "Smoke (dasm)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKEDASM" }
    } else { Write-Host "dasm not found: skipping the dasm smoke" -ForegroundColor Yellow }

    $mads = "$xlib\mads\mads.exe"; $srcMads = "$xlib\src_mads"
    if ((Test-Path $mads) -and (Test-Path $srcMads)) {
        $raw = Join-Path $build "SMOKEMADS.raw"
        $prg = Join-Path $build "SMOKEMADS.PRG"
        Write-Host "mads  apps\smoke_mads\smoke.asm -> $prg"
        # MADS has no linker (opt h-); prepend the CBM load address ourselves
        & $mads (Join-Path $root "apps\smoke_mads\smoke.asm") -c "-i:$root" "-i:$srcMads" "-o:$raw"
        if ($LASTEXITCODE -ne 0) { Fail "mads failed on the smoke app (asmsdk/mads)" }
        $rb = [IO.File]::ReadAllBytes($raw)
        $pb = New-Object byte[] ($rb.Length + 2)
        $pb[0] = 0x01; $pb[1] = 0x08
        [Array]::Copy($rb, 0, $pb, 2, $rb.Length)
        [IO.File]::WriteAllBytes($prg, $pb)
        & $py $mkcxap $prg (Join-Path $build "SMOKEMADS.CXA") --name "Smoke (mads)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKEMADS" }
    } else { Write-Host "mads not found: skipping the mads smoke" -ForegroundColor Yellow }

    $vasm = "$xlib\vasm\vasm6502_oldstyle.exe"; $srcVasm = "$xlib\src_vasm"
    if ((Test-Path $vasm) -and (Test-Path $srcVasm)) {
        $prg = Join-Path $build "SMOKEVASM.PRG"
        Write-Host "vasm  apps\smoke_vasm\smoke.asm -> $prg"
        & $vasm -c02 -Fbin -cbm-prg -I $root -I $srcVasm -o $prg (Join-Path $root "apps\smoke_vasm\smoke.asm")
        if ($LASTEXITCODE -ne 0) { Fail "vasm failed on the smoke app (asmsdk/vasm)" }
        & $py $mkcxap $prg (Join-Path $build "SMOKEVASM.CXA") --name "Smoke (vasm)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKEVASM" }
    } else { Write-Host "vasm not found: skipping the vasm smoke" -ForegroundColor Yellow }

    $kickJar = "$xlib\kickass\KickAss.jar"; $srcKick = "$xlib\src_kick"
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java -and (Test-Path $kickJar) -and (Test-Path $srcKick)) {
        $prg = Join-Path $build "SMOKEKICK.PRG"
        Write-Host "kick  apps\smoke_kick\smoke.asm -> $prg"
        & $java.Source -jar $kickJar (Join-Path $root "apps\smoke_kick\smoke.asm") -libdir $root -libdir $srcKick -o $prg | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "KickAssembler failed on the smoke app (asmsdk/kick)" }
        & $py $mkcxap $prg (Join-Path $build "SMOKEKICK.CXA") --name "Smoke (kick)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKEKICK" }
    } else { Write-Host "KickAssembler/Java not found: skipping the kick smoke" -ForegroundColor Yellow }

    $cl65 = "C:\quartus\projects\x16_clib\ca65\bin\cl65.exe"
    if (-not (Test-Path $cl65)) { $cl65 = "C:\quartus\projects\x16_CDebugger\cc65-sdk\bin\cl65.exe" }
    if (Test-Path $cl65) {
        $prg = Join-Path $build "SMOKEC.PRG"
        Write-Host "cc65  apps\smoke_c\smoke.c -> $prg"
        # one portable C source + the generated cc65 crossing (cxrun.s)
        & $cl65 -t cx16 -O -I $root -o $prg (Join-Path $root "apps\smoke_c\smoke.c") (Join-Path $root "sdk\include_cc65\cxrun.s")
        if ($LASTEXITCODE -ne 0) { Fail "cl65 failed on the smoke app (cc65 csdk)" }
        & $py $mkcxap $prg (Join-Path $build "SMOKEC.CXA") --name "Smoke (cc65)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKEC" }
    } else {
        Write-Host "cc65 (cl65) not found: skipping the cc65 smoke" -ForegroundColor Yellow
    }

    # oscar64: the one portable smoke.c, crossing INLINED in the header
    $o64 = "C:\quartus\projects\x16_clib\oscar64\bin\oscar64.exe"
    if (Test-Path $o64) {
        $prg = Join-Path $build "SMOKEO64.PRG"
        Write-Host "oscar64 apps\smoke_c\smoke.c -> $prg"
        & $o64 -tm=x16 -n -dCX_OSCAR64 "-i=$root" "-o=$prg" (Join-Path $root "apps\smoke_c\smoke.c") 2>&1 |
            Where-Object { $_ -match 'error|Error' } | ForEach-Object { Write-Host "      $_" }
        if ($LASTEXITCODE -ne 0) { Fail "oscar64 failed on the smoke app (oscar64 csdk)" }
        & $py $mkcxap $prg (Join-Path $build "SMOKEO64.CXA") --name "Smoke (oscar64)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKEO64" }
    } else {
        Write-Host "oscar64 not found: skipping the oscar64 smoke" -ForegroundColor Yellow
    }

    # KickC: a Java jar with its own include/lib/fragment/target trees
    $kickcHome = "C:\quartus\projects\x16_clib\kickc"
    $kickcJar = @(Get-ChildItem (Join-Path $kickcHome "jar") -Filter "kickc-*.jar" -ErrorAction SilentlyContinue)
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java -and $kickcJar.Count -gt 0) {
        $jar = $kickcJar[0].FullName
        Write-Host "kickc apps\smoke_c\smoke.c -> $build\SMOKEKICKC.PRG"
        & $java.Source -jar $jar `
            -I (Join-Path $kickcHome "include") -L (Join-Path $kickcHome "lib") `
            -F (Join-Path $kickcHome "fragment") -P (Join-Path $kickcHome "target") `
            -p cx16 -a -DCX_KICKC -I $root -odir $build (Join-Path $root "apps\smoke_c\smoke.c") 2>&1 |
            Where-Object { $_ -match 'rror' } | ForEach-Object { Write-Host "      $_" }
        if ($LASTEXITCODE -ne 0) { Fail "kickc failed on the smoke app (kickc csdk)" }
        Copy-Item (Join-Path $build "smoke.prg") (Join-Path $build "SMOKEKICKC.PRG") -Force
        & $py $mkcxap (Join-Path $build "SMOKEKICKC.PRG") (Join-Path $build "SMOKEKICKC.CXA") --name "Smoke (kickc)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKEKICKC" }
    } else {
        Write-Host "KickC/Java not found: skipping the kickc smoke" -ForegroundColor Yellow
    }

    # vbcc: the +x16 target compiles smoke.c and assembles/links the vasm
    # crossing (cxrun.s). vc.exe shells out to vbcc6502/vasm/vlink by bare
    # name, so VBCC (its config dir) must be set and its bin on PATH.
    $vbccHome = "C:\quartus\projects\x16_clib\vbcc6502\vbcc6502_win\vbcc"
    if (Test-Path (Join-Path $vbccHome "bin\vc.exe")) {
        $prg = Join-Path $build "SMOKEVBCC.PRG"
        Write-Host "vbcc  apps\smoke_c\smoke.c -> $prg"
        $savedVBCC = $env:VBCC; $savedPATH = $env:PATH
        $env:VBCC = $vbccHome
        $env:PATH = (Join-Path $vbccHome "bin") + ";" + $env:PATH
        & (Join-Path $vbccHome "bin\vc.exe") +x16 "-I$root" `
            (Join-Path $root "apps\smoke_c\smoke.c") (Join-Path $root "sdk\include_vbcc\cxrun.s") -o $prg 2>&1 |
            Where-Object { $_ -match 'rror' } | ForEach-Object { Write-Host "      $_" }
        $ok = ($LASTEXITCODE -eq 0)
        $env:VBCC = $savedVBCC; $env:PATH = $savedPATH
        if (-not $ok) { Fail "vbcc failed on the smoke app (vbcc csdk)" }
        & $py $mkcxap $prg (Join-Path $build "SMOKEVBCC.CXA") --name "Smoke (vbcc)"
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap failed on SMOKEVBCC" }
    } else {
        Write-Host "vbcc not found: skipping the vbcc smoke" -ForegroundColor Yellow
    }

    # Prog8: prog8c.jar needs Java 11+ (prefer the newest Adoptium JDK, not the
    # PATH java which may be 1.8) and shells out to its own 64tass.exe, so the
    # prog8-sdk dir must be on PATH. The binding is sdk\include_prog8 (-srcdirs).
    $p8sdk = $null
    foreach ($d in @("C:\quartus\projects\X16_Prog8Debugger\prog8-sdk",
                     "C:\quartus\projects\x16_CDebugger\prog8-sdk",
                     "C:\quartus\projects\C64_Prog8Debugger\prog8-sdk")) {
        if (Test-Path (Join-Path $d "prog8c.jar")) { $p8sdk = $d; break }
    }
    $p8java = $null
    $adoptium = "C:\Program Files\Eclipse Adoptium"
    if (Test-Path $adoptium) {
        $jdk = Get-ChildItem $adoptium -Directory -Filter "jdk-*" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
        if ($jdk) { $p8java = Join-Path $jdk.FullName "bin\java.exe" }
    }
    if ((-not $p8java) -or (-not (Test-Path $p8java))) {
        $j = Get-Command java -ErrorAction SilentlyContinue
        if ($j) { $p8java = $j.Source }
    }
    if ($p8sdk -and $p8java -and (Test-Path $p8java)) {
        # both the smoke and the fuller calc example ride the same binding
        # smoke uses only the raw `cx` binding; calc + uidemo also use the
        # friendly p8sdk layer (p8sdk\cxui.p8), so both source dirs are searched.
        $p8apps = @(
            @{ src = "apps\smoke_prog8\smoke.p8";   prg = "smoke.prg";  cxa = "SMOKEP8.CXA"; name = "Smoke (prog8)" },
            @{ src = "apps\calc\calc.p8";           prg = "calc.prg";   cxa = "CALC8.CXA";   name = "Calc (prog8)"  },
            @{ src = "apps\uidemo_prog8\uidemo.p8"; prg = "uidemo.prg"; cxa = "UIDEMO.CXA";  name = "UI demo (prog8)" }
        )
        $savedPATH = $env:PATH
        $env:PATH = $p8sdk + ";" + $env:PATH
        foreach ($app in $p8apps) {
            Write-Host "prog8 $($app.src) -> $build\$($app.cxa)"
            & $p8java -jar (Join-Path $p8sdk "prog8c.jar") -target cx16 `
                -srcdirs (Join-Path $root "sdk\include_prog8") -srcdirs (Join-Path $root "p8sdk") `
                -out $build (Join-Path $root $app.src) 2>&1 |
                Where-Object { $_ -match 'rror' } | ForEach-Object { Write-Host "      $_" }
            if ($LASTEXITCODE -ne 0) { $env:PATH = $savedPATH; Fail "prog8c failed on $($app.src)" }
            # mkcxap straight from prog8c's <name>.prg output (a rename to the
            # CXA basename would collide with it case-insensitively on Windows)
            & $py $mkcxap (Join-Path $build $app.prg) (Join-Path $build $app.cxa) --name $app.name
            if ($LASTEXITCODE -ne 0) { $env:PATH = $savedPATH; Fail "mkcxap failed on $($app.cxa)" }
        }
        $env:PATH = $savedPATH
    } else {
        Write-Host "Prog8/Java not found: skipping the prog8 apps" -ForegroundColor Yellow
    }
}

# --- stage everything a bootable disk needs -----------------------------
function Stage-SdRoot {
    $sdroot = Join-Path $build "sdroot"
    if (Test-Path $sdroot) { Remove-Item $sdroot -Recurse -Force }
    New-Item -ItemType Directory -Path $sdroot | Out-Null
    Copy-Item (Join-Path $build "AUTOBOOT.X16")  $sdroot
    Copy-Item (Join-Path $build "CXKERNEL.PRG")  $sdroot
    Copy-Item (Join-Path $build "CXBANKS.BIN")   $sdroot
    Copy-Item (Join-Path $build "CXBANKS2.BIN")  $sdroot
    Copy-Item (Join-Path $root  "fonts\pxl8.cxf") (Join-Path $sdroot "PXL8.CXF")
    Copy-Item (Join-Path $root  "fonts\pxl6.cxf") (Join-Path $sdroot "PXL6.CXF")
    Copy-Item (Join-Path $build "SHELL.CXA")     $sdroot
    Copy-Item (Join-Path $build "HELLO1.CXA")    $sdroot
    Copy-Item (Join-Path $build "GALLERY.CXA")   $sdroot
    Copy-Item (Join-Path $build "HITTEST.CXA")   $sdroot
    Copy-Item (Join-Path $build "CPANEL.CXA")    $sdroot
    Copy-Item (Join-Path $build "TUI.CXA")       $sdroot
    Copy-Item (Join-Path $build "TUIGEO.CXA")    $sdroot
    Copy-Item (Join-Path $build "M1UI.CXA")      $sdroot
    Copy-Item (Join-Path $build "GAMELOOP.CXA")  $sdroot
    if (Test-Path (Join-Path $build "HELLO2.CXA")) {
        Copy-Item (Join-Path $build "HELLO2.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "CALC.CXA")) {
        Copy-Item (Join-Path $build "CALC.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "SHEET.CXA")) {
        Copy-Item (Join-Path $build "SHEET.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "WORD.CXA")) {
        Copy-Item (Join-Path $build "WORD.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "CALC8.CXA")) {   # the Prog8 calc, alongside the C one
        Copy-Item (Join-Path $build "CALC8.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "UIDEMO.CXA")) {  # the p8sdk widget showcase
        Copy-Item (Join-Path $build "UIDEMO.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "CDEMO.CXA")) {
        Copy-Item (Join-Path $build "CDEMO.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "PAINT.CXA")) {
        Copy-Item (Join-Path $build "PAINT.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "BEEP.CXA")) {
        Copy-Item (Join-Path $build "BEEP.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "SPRITE.CXA")) {
        Copy-Item (Join-Path $build "SPRITE.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "GFX8.CXA")) {
        Copy-Item (Join-Path $build "GFX8.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "GFX8HI.CXA")) {    # the 640x480 8bpp VERA_2 demo
        Copy-Item (Join-Path $build "GFX8HI.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "GFX4.CXA")) {      # the 320x240 4bpp demo
        Copy-Item (Join-Path $build "GFX4.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "GFX2.CXA")) {      # the 320x240 2bpp demo
        Copy-Item (Join-Path $build "GFX2.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "GFX4HI.CXA")) {    # the 640x480 4bpp VERA_2 demo
        Copy-Item (Join-Path $build "GFX4HI.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "TILES.CXA")) {
        Copy-Item (Join-Path $build "TILES.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "TILES8.CXA")) {    # the 8bpp tile + stream + flip demo
        Copy-Item (Join-Path $build "TILES8.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "TILEDLG.CXA")) {   # the mode-2 panel-on-tiles demo
        Copy-Item (Join-Path $build "TILEDLG.CXA") $sdroot
    }
    if (Test-Path (Join-Path $build "TEXT.CXA")) {
        Copy-Item (Join-Path $build "TEXT.CXA") $sdroot
    }
    Copy-Item (Join-Path $build "NOTES.CXD")     $sdroot
    return $sdroot
}

if ($Test) {
    # The ABI first: sdk/ and the jump table are generated from
    # abi/cxrf.abi, and a suite that passed against a stale sdk/ would
    # be testing something no app is built with. --check writes nothing
    # and fails if anything would change.
    $py = Get-Command python -ErrorAction SilentlyContinue
    if ($py) {
        & $py.Source (Join-Path $root "abi\gen_bindings.py") --check
        if ($LASTEXITCODE -ne 0) { Fail "abi: sdk/ is out of date" }
        & $py.Source (Join-Path $root "abi\gen_bindings.py") --selftest | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "abi: gen_bindings.py selftest failed" }
        & $py.Source (Join-Path $root "tools\fontconv.py") --selftest | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "fontconv: selftest failed" }
        & $py.Source (Join-Path $root "tools\mkcxap.py") --selftest | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "mkcxap: selftest failed" }
        & $py.Source (Join-Path $root "tools\mapreport.py") --selftest | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "mapreport: selftest failed" }
        Write-Host "abi + fontconv + mkcxap + mapreport: host checks pass"

        # The asmsdk fidelity gate: the spec (abi/asmsdk.py) generates the
        # friendly cxm_* layer for every assembler. ca65's stays hand-written
        # as the reference, and this proves the spec reproduces it EXACTLY --
        # the coverage stub invokes every macro; assembled with the hand file
        # and with the spec's ca65 rendering, the two binaries must be equal
        # (byte-identical expansion, as the project has always meant it).
        $gendir = Join-Path $build "asmsdk_gen\asmsdk\ca65"
        New-Item -ItemType Directory -Force -Path $gendir | Out-Null
        & $py.Source (Join-Path $root "abi\asmsdk.py") ca65 |
            Set-Content -Encoding ascii (Join-Path $gendir "cxrf.inc")
        if ($LASTEXITCODE -ne 0) { Fail "asmsdk: ca65 generation failed" }
        $cover = Join-Path $root "test\asmsdk_cover.asm"
        & $ca65 --cpu 65C02 -I $lib -I $root -o (Join-Path $build "cover_hand.o") $cover
        if ($LASTEXITCODE -ne 0) { Fail "asmsdk gate: the cover stub failed to assemble (hand ca65)" }
        & $ld65 -C (Join-Path $root "prg.cfg") -o (Join-Path $build "cover_hand.PRG") (Join-Path $build "cover_hand.o")
        & $ca65 --cpu 65C02 -I $lib -I (Join-Path $build "asmsdk_gen") -I $root -o (Join-Path $build "cover_gen.o") $cover
        if ($LASTEXITCODE -ne 0) { Fail "asmsdk gate: the cover stub failed to assemble (generated ca65)" }
        & $ld65 -C (Join-Path $root "prg.cfg") -o (Join-Path $build "cover_gen.PRG") (Join-Path $build "cover_gen.o")
        $hh = (Get-FileHash (Join-Path $build "cover_hand.PRG")).Hash
        $gh = (Get-FileHash (Join-Path $build "cover_gen.PRG")).Hash
        if ($hh -ne $gh) { Fail "asmsdk gate: the spec's ca65 layer does NOT expand identically to the hand file" }
        Write-Host "asmsdk fidelity: spec's ca65 == hand file (every macro, byte-identical)" -ForegroundColor Green
    } else {
        Write-Host "python not found: skipping the host checks" -ForegroundColor Yellow
    }

    Write-Host "x16emu (headless testbench)"

    $fsroot = Join-Path $root "test\fsroot"
    if (-not (Test-Path $fsroot)) { New-Item -ItemType Directory -Path $fsroot | Out-Null }
    Get-ChildItem $fsroot -File | Remove-Item -Force

    # The loader tests open these through real DOS. BADAPP wears the
    # wrong magic; NEWAPP is a well-formed CXAP that demands ABI $7FFF.
    $badapp = [byte[]]([Text.Encoding]::ASCII.GetBytes("XXAP") + @(0) * 28 + @(0x01, 0x08, 0xEA))
    [IO.File]::WriteAllBytes((Join-Path $fsroot "BADAPP.CXA"), $badapp)
    $newapp = [byte[]]([Text.Encoding]::ASCII.GetBytes("CXAP") + @(0xFF, 0x7F, 0x01, 0x08) + @(0) * 24 + @(0x01, 0x08, 0xEA))
    [IO.File]::WriteAllBytes((Join-Path $fsroot "NEWAPP.CXA"), $newapp)

    $text = Invoke-Emulator @('-prg', $out, '-run', '-fsroot', $fsroot, '-testbench') $TimeoutSec '(?m)^DONE' $name

    $passes = ([regex]::Matches($text, '(?m)^PASS ([A-Z0-9_]+)')).Count
    $fails  = [regex]::Matches($text, '(?m)^FAIL ([A-Z0-9_]+)')
    $skips  = [regex]::Matches($text, '(?m)^SKIP ([A-Z0-9_]+)')
    $done   = [regex]::Match($text, '(?m)^DONE ([0-9A-F]{2})/([0-9A-F]{2})')

    foreach ($f in $fails) { Write-Host ("  FAIL {0}" -f $f.Groups[1].Value) -ForegroundColor Red }
    foreach ($s in $skips) { Write-Host ("  SKIP {0}" -f $s.Groups[1].Value) -ForegroundColor Yellow }

    if (-not $done.Success) { Fail "test run produced no DONE line" }

    $reportedPass  = [Convert]::ToInt32($done.Groups[1].Value, 16)
    $reportedTotal = [Convert]::ToInt32($done.Groups[2].Value, 16)

    if ($reportedTotal -eq 0) { Fail "no tests ran" }
    if ($passes -ne $reportedPass) {
        Fail "output is inconsistent: $passes PASS lines but DONE says $reportedPass"
    }
    if ($fails.Count -gt 0 -or $reportedPass -ne $reportedTotal) {
        Fail "$($reportedTotal - $reportedPass) of $reportedTotal tests failed"
    }

    $summary = "      $reportedPass/$reportedTotal tests passed"
    if ($skips.Count -gt 0) { $summary += ", $($skips.Count) skipped (not runnable headless)" }
    Write-Host $summary -ForegroundColor Green

    # ---- the boot smoke: the whole chain, end to end -------------------
    # A staged SD root boots for real: AUTOBOOT.X16 loads the kernel and
    # the font, cx_init comes up, and AUTORUN.CXA -- the COMMITTED canary
    # binary, built from the sdk of the day the ABI shipped -- runs
    # against the kernel built ten lines ago. That is the ABI freeze
    # test. The canary leaves through cx_exit, which reloads the shell,
    # so one boot proves stage-0, the loader's success path, the frozen
    # ABI, and the exit path, in order, or times out red.
    Write-Host "x16emu (boot smoke: stage-0 -> kernel -> canary -> shell)"
    Build-KernelImage
    Build-Apps
    $sdroot = Stage-SdRoot
    $canary = Join-Path $root "test\canary\CANARY.CXA"
    if (-not (Test-Path $canary)) { Fail "test\canary\CANARY.CXA is missing -- the ABI freeze test needs the committed binary" }
    Copy-Item $canary (Join-Path $sdroot "AUTORUN.CXA")

    $text = Invoke-Emulator @('-fsroot', $sdroot) $TimeoutSec '(?m)^CXRF SHELL' "boot"
    if ($text -notmatch '(?m)^CANARY OK') {
        if ($text -match '(?m)^CANARY FAILED') { Fail "boot smoke: the frozen canary FAILED against this kernel -- the ABI moved" }
        Fail "boot smoke: the canary never reported"
    }
    Write-Host "      boot: kernel up, frozen canary OK, shell up" -ForegroundColor Green

    # The hellos close their own loop -- three seconds with no key and
    # they leave through cx_exit -- so each can play AUTORUN and be
    # proven headless: boot, run, exit, and the shell comes back.
    $hellos = @(
        @{ cxa = "HELLO1.CXA";   up = "HELLO ASM UP" },
        @{ cxa = "MENUTEST.CXA"; up = "MENUTEST OK" }
    )
    if (Test-Path (Join-Path $build "HELLO2.CXA")) {
        $hellos += @{ cxa = "HELLO2.CXA"; up = "HELLO C UP" }
    }
    # the multi-toolchain SDK smokes: each boots, drives the kernel through
    # its GENERATED SDK variant, and prints its OK marker AFTER surviving a
    # spread of calls -- that marker (not the shell banner) is the success
    # signal, because a C app can leave the text cursor mid-line so the
    # shell's "CXRF SHELL" is not at column 0 for the ^-anchored wait.
    foreach ($sm in @(
        @{ cxa = "SMOKE64.CXA";   mk = "SMOKE 64TASS OK" },
        @{ cxa = "SMOKEACME.CXA"; mk = "SMOKE ACME OK" },
        @{ cxa = "SMOKEDASM.CXA"; mk = "SMOKE DASM OK" },
        @{ cxa = "SMOKEMADS.CXA"; mk = "SMOKE MADS OK" },
        @{ cxa = "SMOKEVASM.CXA"; mk = "SMOKE VASM OK" },
        @{ cxa = "SMOKEKICK.CXA"; mk = "SMOKE KICK OK" },
        @{ cxa = "SMOKEC.CXA";    mk = "SMOKE C OK" },
        @{ cxa = "SMOKEO64.CXA";  mk = "SMOKE C OK" },
        @{ cxa = "SMOKEKICKC.CXA"; mk = "SMOKE C OK" },
        @{ cxa = "SMOKEVBCC.CXA"; mk = "SMOKE C OK" },
        @{ cxa = "SMOKEP8.CXA";   mk = "SMOKE PROG8 OK" },
        @{ cxa = "CALC8.CXA";     mk = "CALC P8 OK" },
        @{ cxa = "UIDEMO.CXA";    mk = "UIDEMO OK" },
        @{ cxa = "TILETEXT.CXA";  mk = "TILETEXT OK" },
        @{ cxa = "TILES8.CXA";    mk = "TILES8 OK" },
        @{ cxa = "GFX8HI.CXA";    mk = "GFX8HI OK" },
        @{ cxa = "GFX4.CXA";      mk = "GFX4 OK" },
        @{ cxa = "GFX2.CXA";      mk = "GFX2 OK" },
        @{ cxa = "GFX4HI.CXA";    mk = "GFX4HI OK" },
        @{ cxa = "GEOSMOKE.CXA";  mk = "GEOSMOKE OK" },
        @{ cxa = "SHEET.CXA";     mk = "SHEET UP" },
        @{ cxa = "WORD.CXA";      mk = "WORD UP" }
    )) {
        if (Test-Path (Join-Path $build $sm.cxa)) {
            $hellos += @{ cxa = $sm.cxa; up = $sm.mk; wait = $sm.mk }
        }
    }
    foreach ($h in $hellos) {
        Copy-Item (Join-Path $build $h.cxa) (Join-Path $sdroot "AUTORUN.CXA") -Force
        $wait = if ($h.wait) { $h.wait } else { '(?m)^CXRF SHELL' }
        $text = Invoke-Emulator @('-fsroot', $sdroot) $TimeoutSec $wait "boot-$($h.cxa)"
        # not ^-anchored: -echo renders a control byte ahead of the text
        # as \X0F, so the marker is not at column 0
        if ($text -notmatch [regex]::Escape($h.up)) { Fail "boot smoke: $($h.cxa) never came up" }
        Write-Host "      boot: $($h.cxa) up" -ForegroundColor Green
    }

    # The SD-image path: fold the staged root into one FAT32 image and
    # boot it through -sdcard, the way a real card boots (the ROM's
    # CMDR-DOS reads AUTOBOOT.X16 off the FAT). No AUTORUN, so it lands
    # straight in the desktop and "CXRF SHELL" alone proves the image.
    Remove-Item (Join-Path $sdroot "AUTORUN.CXA") -Force -ErrorAction SilentlyContinue
    $img = Join-Path $build "cxrf_smoke.img"
    $files = Get-ChildItem $sdroot -File | ForEach-Object { $_.FullName }
    & python (Join-Path $root "tools\mksd.py") $img @files | Out-Null
    if ($LASTEXITCODE) { Fail "boot smoke: mksd.py failed to build the image" }
    $text = Invoke-Emulator @('-sdcard', $img) $TimeoutSec '(?m)^CXRF SHELL' "boot-sdcard"
    if ($text -notmatch '(?m)^CXRF SHELL') { Fail "boot smoke: the SD image never reached the desktop" }
    Remove-Item $img -Force -ErrorAction SilentlyContinue
    Write-Host "      boot: FAT32 image via -sdcard, desktop up" -ForegroundColor Green

    # The cartridge path: the KERNAL finds "CX16" in ROM bank 32 and starts
    # our stub, which copies the same kernel into RAM from ROM. The desktop
    # coming up over -cartbin proves the auto-boot signature, the cross-bank
    # copy, and cx_init from a bare (pre-BASIC) machine -- with the kernel in
    # ROM, apps still off the staged SD root.
    Write-Host "x16emu (boot smoke: cartridge -> kernel -> shell)"
    $cartbin = Build-CartImage
    $text = Invoke-Emulator @('-cartbin', $cartbin, '-fsroot', $sdroot) $TimeoutSec '(?m)^CXRF SHELL' "boot-cart"
    if ($text -notmatch '(?m)^CXRF SHELL') { Fail "boot smoke: the cartridge never reached the desktop" }
    Write-Host "      boot: cartridge via -cartbin, desktop up" -ForegroundColor Green

    # ---- the skew sentinels: a wrong SD set must refuse, loudly --------
    # Four kernel files ship together (AUTOBOOT, CXKERNEL, CXBANKS,
    # CXBANKS2); a hand-copied card can carry yesterday's copy of one.
    # Stage-0 compares the build word across all of them (banksig.asm),
    # and these two boots pin the refusal: one with the file missing,
    # one with a signature that loads fine but does not match.
    Write-Host "x16emu (boot smoke: missing/stale CXBANKS2 refuses)"
    Remove-Item (Join-Path $sdroot "CXBANKS2.BIN") -Force
    $text = Invoke-Emulator @('-fsroot', $sdroot) $TimeoutSec 'NO CXBANKS2' "boot-nobanks2"
    if ($text -notmatch 'NO CXBANKS2') { Fail "negative smoke: the missing-CXBANKS2 refusal never printed" }
    Write-Host "      boot: missing CXBANKS2.BIN refused" -ForegroundColor Green

    $bytes = [IO.File]::ReadAllBytes((Join-Path $build "CXBANKS2.BIN"))
    $bytes[4] = $bytes[4] -bxor 0xFF   # bank 16's CX_KBUILD low byte
    [IO.File]::WriteAllBytes((Join-Path $sdroot "CXBANKS2.BIN"), $bytes)
    $text = Invoke-Emulator @('-fsroot', $sdroot) $TimeoutSec 'STALE OR SHORT' "boot-skew"
    if ($text -notmatch 'STALE OR SHORT') { Fail "negative smoke: the stale-CXBANKS2 refusal never printed" }
    Copy-Item (Join-Path $build "CXBANKS2.BIN") (Join-Path $sdroot "CXBANKS2.BIN") -Force
    Write-Host "      boot: stale CXBANKS2.BIN refused" -ForegroundColor Green
    exit 0
}

if ($Apps -or $Image -or $Boot -or $Cart) {
    Build-KernelImage
    Build-Apps
    $sdroot = Stage-SdRoot
    Write-Host "sdroot: $sdroot"
    Get-ChildItem $sdroot | ForEach-Object { Write-Host ("      {0,-14} {1,6} bytes" -f $_.Name, $_.Length) }
    if ($Image) {
        # ...and fold the same files into one bootable FAT32 image, so a
        # real SD card (or -sdcard) boots identically to -fsroot.
        $img = Join-Path $build "cxrf_sd.img"
        $files = Get-ChildItem $sdroot -File | ForEach-Object { $_.FullName }
        & python (Join-Path $root "tools\mksd.py") $img @files
        if ($LASTEXITCODE) { throw "mksd.py failed" }
        Write-Host "image: $img"
    }
    $cartbin = $null
    if ($Cart) {
        # The same kernel in a cartridge (ROM banks 32-36). Without -App the
        # cart's "CX16" auto-boot brings up the framework and runs AUTORUN.CXA
        # (or the desktop) from the card. With -App the chosen app is baked
        # into ROM bank 37 too, so the cartridge boots it with no SD at all.
        $cartbin = Build-CartImage $App
        Write-Host "cart: $cartbin"
    }
    if ($Boot) {
        # -capture: x16emu does not feed the host mouse to the guest
        # without it, so the pointer would sit frozen. Interactive only;
        # the headless smoke never needs it.
        # -bitmap2 enables the VERA_2 second plane (mode 4: GFX4HI/GFX8HI);
        # without it those apps enable VERA2_CTRL to no effect and, with the
        # VERA layers turned off by their engine, the screen goes white. The
        # headless smoke path (Invoke-Emulator) already passes it; the
        # interactive boot must too, or launching a mode-4 app white-pages.
        if ($Cart) {
            Write-Host "x16emu (booting the cartridge via -cartbin; -capture for the mouse)"
            & $emu -rom $rom -cartbin $cartbin -fsroot $sdroot -scale $Scale -bitmap2 -capture
        } else {
            Write-Host "x16emu (booting the staged root; -capture for the mouse)"
            & $emu -rom $rom -fsroot $sdroot -scale $Scale -bitmap2 -capture
        }
    }
    exit 0
}

if ($Capture) {
    Write-Host "x16emu (windowed, capturing until DONE)"
    $text = Invoke-Emulator @('-prg', $out, '-run') $TimeoutSec '(?m)^DONE' $name
    Write-Host $text
    exit 0
}

if ($Run) {
    Write-Host "x16emu $out"
    & $emu -rom $rom -prg $out -run -scale $Scale -bitmap2
}
