# KAIST 공식 쇼츠 틀(references/TEMPLATE.md)을 FFmpeg로 그리는 렌더러 (PowerShell 5.1 / 7 겸용)
#
#   powershell -ExecutionPolicy Bypass -File render.ps1 -Spec 결과\날짜-이름\spec.json
#
# 필요한 것: FFmpeg(drawtext 포함 빌드, winget Gyan.FFmpeg.Essentials), 이 스킬의 assets 폴더(글꼴, 로고, 화살표).
# 파이썬은 쓰지 않는다. spec.json 형식은 SKILL.md와 examples/ 를 본다.
#
# 이 파일은 UTF-8 (BOM 포함)으로 저장한다. PowerShell 5.1은 BOM이 없으면 한글을 깨뜨린다.
param(
    [Parameter(Mandatory = $true)][Alias("Spec")][string]$SpecFile,
    [string]$FFmpeg = "",
    [switch]$NoOpen,
    [switch]$NoLogo,
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"
$inv = [Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$utf8 = New-Object Text.UTF8Encoding($false)

# ---- 틀의 고정값 (TEMPLATE.md, 기준 프레임에서 픽셀로 잰 값) -------------------------------
$W = 1080; $H = 1920
$FPS = "30000/1001"
$VIDEO_Y = 582; $VIDEO_W = 1080; $VIDEO_H = 756
$LOGO_X = 368; $LOGO_Y = 106
$COLORS = @{ white = "FFFFFF"; teal = "00D0E1" }
$TITLE_SIZE = 100; $TITLE_SPACING = -5.6
$TITLE_BASELINES = @(407.5, 514)
$BOTTOM_SIZE = 62; $BOTTOM_SPACING = -4.3; $BOTTOM_BASELINE = 1440
$ARROW_W = 40; $ARROW_GAP = 27; $BOTTOM_CENTER_X = 536.5
$CAPTION_SIZE = 40; $CAPTION_BASELINE = $VIDEO_Y + $VIDEO_H - 36
$CAPTION_BORDER = 4
# drawtext의 y는 글자 윗부분 기준이라, y = 기준선 - max_glyph_a 로 둔다. render.py(SVG) 결과와 같은 높이가 되도록
# 크기 100(제목)과 62(아래 안내)에서 잰 오차는 0-1px라 보정값은 0이다. 다른 빌드에서 어긋나면 이 값으로 조정한다.
$BASELINE_SHIFT = 0.0
# 가로 위치 보정(px): render.py 결과와 잰 차이를 맞춘 값
$TITLE_X_ADJUST = -2.5; $LABEL_X_ADJUST = 1; $ARROW_X_ADJUST = 2.5
$MAX_TITLE_WIDTH = 990

function F([double]$n) { return $n.ToString("0.###", $inv) }

function Say([string]$msg) { Write-Host $msg }
function Fail([string]$msg) { throw $msg }

# ---- 도구 찾기 ---------------------------------------------------------------------------
function Find-Tool([string]$name, [string]$hint) {
    if ($hint -and (Test-Path -LiteralPath $hint)) { return (Resolve-Path -LiteralPath $hint).Path }
    $envName = "KAIST_" + $name.ToUpper()
    $envVal = [Environment]::GetEnvironmentVariable($envName)
    if ($envVal -and (Test-Path -LiteralPath $envVal)) { return $envVal }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $local = $env:LOCALAPPDATA
    if ($local) {
        $links = Join-Path $local "Microsoft\WinGet\Links\$name.exe"
        if (Test-Path -LiteralPath $links) { return $links }
        $pk = Join-Path $local "Microsoft\WinGet\Packages"
        if (Test-Path -LiteralPath $pk) {
            $hit = Get-ChildItem -LiteralPath $pk -Recurse -Filter "$name.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Quote-Arg([string]$a) {
    if ($a -eq "") { return '""' }
    if ($a -notmatch '[\s"]') { return $a }
    $s = $a -replace '(\\*)"', '$1$1\"'
    $s = $s -replace '(\\+)$', '$1$1'
    return '"' + $s + '"'
}

# 명령을 돌리고 종료 코드와 출력을 돌려준다 (stderr 때문에 PowerShell이 오류로 끊지 않도록 Process를 직접 쓴다)
function Invoke-Tool([string]$exe, [string[]]$argList, [string]$cwd) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = (($argList | ForEach-Object { Quote-Arg $_ }) -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.CreateNoWindow = $true
    if ($cwd) { $psi.WorkingDirectory = $cwd }
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return New-Object psobject -Property @{ Code = $p.ExitCode; Out = $out; Err = $errTask.Result }
}

function Run-FFmpeg([string[]]$argList, [string]$cwd, [string]$what) {
    $r = Invoke-Tool $script:FFMPEG_EXE $argList $cwd
    if ($r.Code -ne 0) {
        $tail = $r.Err
        if ($tail.Length -gt 1800) { $tail = $tail.Substring($tail.Length - 1800) }
        Fail ("실패: $what`n" + $tail)
    }
    return $r
}

# ---- 글자 폭 (글꼴 파일에서 뽑아 둔 글자별 가로 폭표) --------------------------------------
$advFile = Join-Path $PSScriptRoot "..\assets\gmarket-advances.json"
$advJson = Get-Content -LiteralPath $advFile -Raw -Encoding UTF8 | ConvertFrom-Json
$ADV = New-Object 'System.Collections.Generic.Dictionary[int,int]'
foreach ($prop in $advJson.adv.PSObject.Properties) { $ADV[[int]$prop.Name] = [int]$prop.Value }
$ADV_DEFAULT = [int]$advJson.default
$ADV_UPM = [int]$advJson.upm

# 글줄을 글자 단위로 나눈다 (서로게이트 쌍 포함). 글자 하나의 가로 폭(px)은 폭표 * 크기 / 1000
function Get-Chars([string]$text) {
    $list = New-Object System.Collections.ArrayList
    $e = [Globalization.StringInfo]::GetTextElementEnumerator($text)
    while ($e.MoveNext()) { [void]$list.Add([string]$e.GetTextElement()) }
    return , @($list)
}
function Get-Advance([string]$ch, [double]$size) {
    $cp = [char]::ConvertToUtf32($ch, 0)
    $a = $ADV_DEFAULT
    if ($ADV.ContainsKey($cp)) { $a = $ADV[$cp] }
    return $a * $size / $ADV_UPM
}
function Get-LineWidth([string]$text, [double]$size, [double]$spacing) {
    $sum = 0.0
    foreach ($c in (Get-Chars $text)) { $sum += (Get-Advance $c $size) + $spacing }
    return $sum
}

# ---- 임시 폴더와 글자 파일 ---------------------------------------------------------------
$script:textCount = 0
function New-TextFile([string]$text) {
    $script:textCount++
    $name = "t{0:0000}.txt" -f $script:textCount
    [IO.File]::WriteAllText((Join-Path $script:TMP $name), $text, $utf8)
    return $name
}

function DT([string]$text, [double]$size, [string]$color, [string]$x, [double]$baseline, [string]$extra) {
    $f = New-TextFile $text
    $shift = F ($BASELINE_SHIFT * $size)
    $s = "drawtext=fontfile=font.otf:textfile=${f}:expansion=none:fontsize=$(F $size):fontcolor=0x${color}:x=${x}:y=$(F $baseline)-max_glyph_a-${shift}"
    if ($extra) { $s += ":$extra" }
    return $s
}

# 자간(letter-spacing)을 주려고 글자마다 따로 그린다. 가운데 정렬은 글자 폭 합(자간 포함)으로 계산한다.
function Spaced-Line([string]$text, [double]$size, [double]$spacing, [string]$color, [double]$baseline, [double]$left) {
    $parts = @()
    $x = $left
    foreach ($c in (Get-Chars $text)) {
        if ($c.Trim() -ne "") { $parts += (DT $c $size $color (F $x) $baseline "") }
        $x += (Get-Advance $c $size) + $spacing
    }
    return $parts
}

function Resolve-Color([string]$c) {
    if (-not $c) { return "FFFFFF" }
    if ($COLORS.ContainsKey($c)) { return $COLORS[$c] }
    return $c.TrimStart("#")
}

# ---- 길이와 전환 -------------------------------------------------------------------------
function Get-Opt($obj, [string]$name, $default) {
    $p = $obj.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $default
}
function Seg-Duration($seg) {
    if ($seg.type -eq "video") { return [double]$seg.out - [double]$seg.in }
    return [double]$seg.duration
}
function Transition-Of($seg) {
    $kind = Get-Opt $seg "transition" "cut"
    if ($kind -eq "cut") { return @("cut", 0.0) }
    return @($kind, [double](Get-Opt $seg "transition_duration" 0.3))
}

# ---- 입력 목록 ---------------------------------------------------------------------------
function Build-Inputs($segs, $audio, $sfx, [bool]$overlays) {
    $a = New-Object System.Collections.ArrayList
    $idx = @{ seg_v = @(); seg_a = @(); narr = $null; sfx = @(); logo = $null; arrow = $null }
    $n = 0
    foreach ($seg in $segs) {
        $dur = Seg-Duration $seg
        if ($seg.type -eq "video") {
            [void]$a.AddRange(@("-ss", (F $seg.in), "-t", (F $dur), "-i", $seg.abs))
            $idx.seg_v += $n; $idx.seg_a += $n; $n++
        } else {
            [void]$a.AddRange(@("-loop", "1", "-framerate", $FPS, "-t", (F $dur), "-i", $seg.abs))
            $idx.seg_v += $n; $n++
            [void]$a.AddRange(@("-f", "lavfi", "-t", (F $dur), "-i", "anullsrc=r=48000:cl=stereo"))
            $idx.seg_a += $n; $n++
        }
    }
    if ((Get-Opt $audio "mode" "original") -eq "narration") {
        [void]$a.AddRange(@("-i", $audio.abs)); $idx.narr = $n; $n++
    }
    foreach ($fx in $sfx) {
        [void]$a.AddRange(@("-i", $fx.abs)); $idx.sfx += $n; $n++
    }
    if ($overlays) {
        if ($script:LOGO) { [void]$a.AddRange(@("-i", $script:LOGO)); $idx.logo = $n; $n++ }
        [void]$a.AddRange(@("-i", $script:ARROW)); $idx.arrow = $n; $n++
    }
    return @{ args = [string[]]$a.ToArray(); idx = $idx }
}

# ---- 필터 그래프: 영상 --------------------------------------------------------------------
function Video-Filters($spec, $segs, $idx, [double]$total) {
    $parts = @(); $labels = @()
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $seg = $segs[$i]; $v = $idx.seg_v[$i]
        if ($seg.type -eq "video") {
            if ((Get-Opt $seg "fit" "") -eq "width") {
                $fit = "scale=${VIDEO_W}:${VIDEO_H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${VIDEO_W}:${VIDEO_H}:(ow-iw)/2:(oh-ih)/2:black"
            } else {
                $fit = "scale=${VIDEO_W}:${VIDEO_H}:force_original_aspect_ratio=increase:flags=lanczos,crop=${VIDEO_W}:${VIDEO_H}"
            }
            $parts += "[${v}:v]fps=$FPS,$fit,setsar=1,format=yuv420p,setpts=PTS-STARTPTS,settb=AVTB[v$i]"
        } else {
            $dur = Seg-Duration $seg
            $frames = [Math]::Max(1, [Math]::Round($dur * 30000 / 1001))
            $push = [double](Get-Opt $seg "push_in" 0.08)
            $w2 = $VIDEO_W * 2; $h2 = $VIDEO_H * 2
            $parts += "[${v}:v]scale=${w2}:${h2}:force_original_aspect_ratio=increase,crop=${w2}:${h2},zoompan=z='1+$(F $push)*on/${frames}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=${VIDEO_W}x${VIDEO_H}:fps=$FPS,setsar=1,format=yuv420p,setpts=PTS-STARTPTS,settb=AVTB[v$i]"
        }
        $labels += "[v$i]"
    }
    $cur = $labels[0]; $curLen = Seg-Duration $segs[0]
    for ($i = 1; $i -lt $labels.Count; $i++) {
        $t = Transition-Of $segs[$i]; $kind = $t[0]; $dur = [double]$t[1]
        $nxt = "[m$i]"
        if ($kind -eq "cut") {
            $parts += "$cur$($labels[$i])concat=n=2:v=1:a=0,settb=AVTB$nxt"
        } else {
            $parts += "$cur$($labels[$i])xfade=transition=${kind}:duration=$(F $dur):offset=$(F ($curLen - $dur)),settb=AVTB$nxt"
            $curLen -= $dur
        }
        $curLen += Seg-Duration $segs[$i]
        $cur = $nxt
    }
    $parts += "${cur}null[clip]"
    $parts += "color=c=black:s=${W}x${H}:r=${FPS}:d=$(F $total)[bg]"
    $parts += "[bg][clip]overlay=0:${VIDEO_Y}:shortest=0[a1]"
    if ($null -ne $idx.logo) {
        # 로고는 폭 344로 맞추고(틀의 로고 크기), 높이 112 칸의 가운데에 놓는다. 흰 배경 jpg는 흰색을 투명하게 만든다.
        $keyF = ""
        if ($script:LOGO -match '\.jpe?g$') { $keyF = "colorkey=0xFFFFFF:0.15:0.1," }
        $parts += "[$($idx.logo):v]format=rgba,${keyF}scale=344:-2[lg]"
        $parts += "[a1][lg]overlay=${LOGO_X}:${LOGO_Y}+(112-h)/2[a2]"
    } else { $parts += "[a1]null[a2]" }

    # 제목 2줄 (글자마다 자간을 주어 그린다)
    $draws = @()
    $lines = @($spec.title)
    if ($lines.Count -ne 2) { Fail "title은 정확히 2줄이어야 합니다." }
    for ($k = 0; $k -lt 2; $k++) {
        $line = $lines[$k]
        $size = $TITLE_SIZE
        $spacing = [double](Get-Opt $line "spacing" $TITLE_SPACING)
        $tw = Get-LineWidth $line.text $size $spacing
        if ($tw -gt $MAX_TITLE_WIDTH) {
            $size = [Math]::Floor($TITLE_SIZE * $MAX_TITLE_WIDTH / $tw)
            Say ("주의: 제목 {0}번째 줄이 너무 길어 글자 크기를 {1}로 줄입니다. 글자를 줄이면 더 크게 나옵니다." -f ($k + 1), $size)
            $spacing = $spacing * $size / $TITLE_SIZE
            $tw = Get-LineWidth $line.text $size $spacing
        }
        $color = Resolve-Color (Get-Opt $line "color" "white")
        $draws += Spaced-Line $line.text $size $spacing $color $TITLE_BASELINES[$k] ($W / 2 - $tw / 2 + $TITLE_X_ADJUST)
    }
    # 아래 안내 (맨 앞이 "↓"면 화살표 그림 + 글자를 한 덩어리로 가운데에 놓는다)
    $bottom = Get-Opt $spec "bottom_text" ""
    $arrowX = $null
    if ($bottom) {
        if ($bottom.StartsWith([string][char]0x2193)) {
            $rest = $bottom.Substring(1).Trim()
            $lw = (Get-LineWidth $rest $BOTTOM_SIZE $BOTTOM_SPACING) - $BOTTOM_SPACING
            $left = $BOTTOM_CENTER_X - ($ARROW_W + $ARROW_GAP + $lw) / 2
            $arrowX = [Math]::Round($left + $ARROW_X_ADJUST)
            $draws += Spaced-Line $rest $BOTTOM_SIZE $BOTTOM_SPACING "FFFFFF" $BOTTOM_BASELINE ($left + $ARROW_W + $ARROW_GAP + $LABEL_X_ADJUST)
        } else {
            $lw = Get-LineWidth $bottom $BOTTOM_SIZE $BOTTOM_SPACING
            $draws += Spaced-Line $bottom $BOTTOM_SIZE $BOTTOM_SPACING "FFFFFF" $BOTTOM_BASELINE ($W / 2 - $lw / 2)
        }
    }
    $last = "a2"
    if ($arrowX -ne $null) {
        $parts += "[a2][$($idx.arrow):v]overlay=${arrowX}:1396[a3]"
        $last = "a3"
    }
    $parts += "[$last]" + ($draws -join ",") + "[a4]"
    $last = "a4"
    # 화면 안 자막: 영상 화면 아래쪽, 흰 글자 + 검은 외곽선
    $caps = @(Get-Opt $spec "captions" @())
    if ($caps.Count -gt 0) {
        $capDraws = @()
        foreach ($cap in $caps) {
            $size = $CAPTION_SIZE
            $cw = Get-LineWidth $cap.text $size 0
            if ($cw -gt 1000) { $size = [Math]::Floor($CAPTION_SIZE * 1000 / $cw) }
            $en = "enable='between(t,$(F ([double]$cap.start)),$(F ([double]$cap.end)))'"
            $capDraws += (DT $cap.text $size "FFFFFF" "(w-text_w)/2" $CAPTION_BASELINE "borderw=${CAPTION_BORDER}:bordercolor=0x000000:$en")
        }
        $parts += "[$last]" + ($capDraws -join ",") + "[a5]"
        $last = "a5"
    }
    $parts += "[$last]format=yuv420p[vout]"
    return $parts
}

# ---- 필터 그래프: 소리 --------------------------------------------------------------------
function Audio-Filters($segs, $audio, $sfx, $idx, [double]$total, [string]$loudnorm) {
    $mode = Get-Opt $audio "mode" "original"
    $narration = ($mode -eq "narration")
    $parts = @(); $labels = @()
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $seg = $segs[$i]; $a = $idx.seg_a[$i]
        $default = 1.0
        if ($narration) { $default = [double](Get-Opt $audio "original_volume" 0.2) }
        $vol = [double](Get-Opt $seg "volume" $default)
        $dur = Seg-Duration $seg
        $parts += "[${a}:a]aresample=48000,aformat=channel_layouts=stereo,volume=$(F $vol),apad=whole_dur=$(F $dur),atrim=0:$(F $dur),asetpts=PTS-STARTPTS[a$i]"
        $labels += "[a$i]"
    }
    $cur = $labels[0]
    for ($i = 1; $i -lt $labels.Count; $i++) {
        $t = Transition-Of $segs[$i]; $kind = $t[0]; $dur = [double]$t[1]
        $nxt = "[o$i]"
        if ($kind -eq "cut") { $parts += "$cur$($labels[$i])concat=n=2:v=0:a=1$nxt" }
        else { $parts += "$cur$($labels[$i])acrossfade=d=$(F $dur):c1=tri:c2=tri$nxt" }
        $cur = $nxt
    }
    $parts += "${cur}anull[orig]"
    if ($narration) {
        $nv = [double](Get-Opt $audio "narration_volume" 1.0)
        $parts += "[$($idx.narr):a]aresample=48000,aformat=channel_layouts=stereo,volume=$(F $nv)[narr]"
        $parts += "[orig][narr]amix=inputs=2:duration=longest:normalize=0,atrim=0:$(F $total)[mix]"
    } else {
        $parts += "[orig]atrim=0:$(F $total)[mix]"
    }
    $fxLabels = @()
    for ($k = 0; $k -lt $sfx.Count; $k++) {
        $fx = $sfx[$k]; $fi = $idx.sfx[$k]
        $start = [double](Get-Opt $fx "start" 0)
        $dur = Get-Opt $fx "duration" $null
        if ($null -ne $dur) { $trim = "atrim=$(F $start):$(F ($start + [double]$dur))" } else { $trim = "atrim=start=$(F $start)" }
        $chain = "[${fi}:a]$trim,asetpts=PTS-STARTPTS,aresample=48000,aformat=channel_layouts=stereo"
        $fin = [double](Get-Opt $fx "fade_in" 0)
        $fout = [double](Get-Opt $fx "fade_out" 0)
        if ($fin -gt 0) { $chain += ",afade=t=in:d=$(F $fin)" }
        if ($fout -gt 0 -and $null -ne $dur) { $chain += ",afade=t=out:st=$(F ([double]$dur - $fout)):d=$(F $fout)" }
        $ms = [int][Math]::Round([double]$fx.at * 1000)
        $chain += ",volume=$(F ([double](Get-Opt $fx 'volume_db' -12)))dB,adelay=${ms}|${ms}[fx$k]"
        $parts += $chain
        $fxLabels += "[fx$k]"
    }
    if ($fxLabels.Count -gt 0) {
        $parts += "[mix]" + ($fxLabels -join "") + "amix=inputs=$($fxLabels.Count + 1):duration=first:normalize=0,atrim=0:$(F $total)[mix2]"
        $parts += "[mix2]$loudnorm,aresample=48000[aout]"
    } else {
        $parts += "[mix]$loudnorm,aresample=48000[aout]"
    }
    return $parts
}

# ---- 시작 -------------------------------------------------------------------------------
$specPath = (Resolve-Path -LiteralPath $SpecFile).Path
$specDir = Split-Path -Parent $specPath
$spec = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8 | ConvertFrom-Json

# 프로젝트 폴더(재료 폴더가 있는 곳)를 찾는다. spec 안의 "재료/..." 경로는 여기서 찾는다.
$projectRoot = $specDir
for ($d = $specDir; $d; $d = Split-Path -Parent $d) {
    if (Test-Path -LiteralPath (Join-Path $d "재료") -PathType Container) { $projectRoot = $d; break }
}
function Resolve-Input([string]$p) {
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    $c1 = [IO.Path]::GetFullPath((Join-Path $specDir $p))
    if (Test-Path -LiteralPath $c1) { return $c1 }
    $c2 = [IO.Path]::GetFullPath((Join-Path $projectRoot $p))
    if (Test-Path -LiteralPath $c2) { return $c2 }
    Fail "파일을 찾지 못했습니다: $p`n(spec 폴더와 프로젝트 폴더 둘 다 찾아봤습니다)"
}
function Resolve-Output([string]$p) {
    if ([IO.Path]::IsPathRooted($p)) { return $p }
    if ($p -match '^(결과)[\\/]') { return [IO.Path]::GetFullPath((Join-Path $projectRoot $p)) }
    return [IO.Path]::GetFullPath((Join-Path $specDir $p))
}

$script:FFMPEG_EXE = Find-Tool "ffmpeg" $FFmpeg
if (-not $script:FFMPEG_EXE) { Fail "FFmpeg를 찾지 못했습니다. 설치 파일(setup-windows.bat)을 먼저 실행해 주세요." }
$probe = Invoke-Tool $script:FFMPEG_EXE @("-hide_banner", "-filters") $null
if ($probe.Out -notmatch "drawtext") { Fail "이 FFmpeg에는 글자를 그리는 기능(drawtext)이 없습니다. winget의 Gyan.FFmpeg.Essentials 빌드가 필요합니다." }
$ver = Invoke-Tool $script:FFMPEG_EXE @("-hide_banner", "-version") $null
$major = 0
if ($ver.Out -match "version\D*(\d+)\.") { $major = [int]$Matches[1] }
$graphFlag = "-filter_complex_script"
if ($major -ge 7) { $graphFlag = "-/filter_complex" }

$skillRoot = Split-Path -Parent $PSScriptRoot
$FONT = Join-Path $skillRoot "assets\GmarketSansBold.otf"
$script:ARROW = Join-Path $skillRoot "assets\arrow-down.png"
# 로고: KAIST 공식 로고 파일은 이 프로젝트에 들어 있지 않습니다. spec의 "logo"(경로), 없으면 재료 폴더의 logo.png 를 씁니다.
$LOGO_PAGE = "https://kaist.ac.kr/kr/html/kaist/010401.html"
$script:LOGO = $null
$logoOpt = Get-Opt $spec "logo" ""
if ($logoOpt -is [bool] -and -not $logoOpt) { $NoLogo = $true }
elseif ($logoOpt) { $script:LOGO = Resolve-Input ([string]$logoOpt) }
if (-not $NoLogo -and -not $script:LOGO) {
    foreach ($nm in @("logo.png", "logo.jpg", "logo.jpeg", "kaist-logo.png")) {
        $cand = Join-Path (Join-Path $projectRoot "재료") $nm
        if (Test-Path -LiteralPath $cand) { $script:LOGO = $cand; break }
    }
}
if (-not $NoLogo -and -not $script:LOGO) {
    Fail ("KAIST 로고 파일이 없습니다. 공식 로고는 이 프로젝트에 들어 있지 않습니다.`n" +
        "1) $LOGO_PAGE 에서 'KAIST 로고'를 내려받아(고해상도 파일은 KAIST 포털 로그인이 필요할 수 있습니다) 재료 폴더에 logo.png 로 저장해 주세요. 배경이 투명한 png가 가장 좋습니다.`n" +
        "2) 로고 없이 만들어도 된다고 사용자가 정했다면 -NoLogo 를 붙여 다시 실행하세요.`n" +
        "(KAIST 안내: 로고는 상업적 목적으로 쓸 수 없고, 교육 및 행정 목적에 한해 제공됩니다.)")
}
foreach ($f in @($FONT, $script:ARROW)) { if (-not (Test-Path -LiteralPath $f)) { Fail "스킬 파일이 없습니다: $f" } }
if ($script:LOGO -and -not (Test-Path -LiteralPath $script:LOGO)) { Fail "로고 파일을 찾지 못했습니다: $($script:LOGO)" }

$segs = @($spec.segments)
foreach ($seg in $segs) { Add-Member -InputObject $seg -NotePropertyName abs -NotePropertyValue (Resolve-Input $seg.src) -Force }
$audio = Get-Opt $spec "audio" ([pscustomobject]@{ mode = "original" })
if ((Get-Opt $audio "mode" "original") -eq "narration") { Add-Member -InputObject $audio -NotePropertyName abs -NotePropertyValue (Resolve-Input $audio.file) -Force }
$sfx = @(Get-Opt $spec "sfx" @())
foreach ($fx in $sfx) { Add-Member -InputObject $fx -NotePropertyName abs -NotePropertyValue (Resolve-Input $fx.file) -Force }

# 구간별 출력 시작 시각과 전체 길이
$starts = @(); $t = 0.0
for ($i = 0; $i -lt $segs.Count; $i++) {
    $tr = Transition-Of $segs[$i]
    $overlap = 0.0
    if ($i -gt 0) { $overlap = [double]$tr[1] }
    if ($overlap -gt 0 -and ($overlap -ge (Seg-Duration $segs[$i]) -or $overlap -ge (Seg-Duration $segs[$i - 1]))) {
        Fail "구간 $i 의 transition_duration ${overlap}초가 구간 길이보다 깁니다."
    }
    if ($i -gt 0) { $t -= $overlap } else { $t = 0.0 }
    $starts += $t
    $t += Seg-Duration $segs[$i]
}
$total = $t
for ($i = 0; $i -lt $segs.Count; $i++) {
    $tr = Transition-Of $segs[$i]
    $msg = "구간 {0}: 출력 {1:0.00}-{2:0.00}초" -f $i, $starts[$i], ($starts[$i] + (Seg-Duration $segs[$i]))
    if ($tr[0] -ne "cut") { $msg += " (전환 $($tr[0]) $($tr[1])초)" }
    Say $msg
}

$loud = Get-Opt $spec "loudness" ([pscustomobject]@{})
$target = [double](Get-Opt $loud "target" -19)
$peak = [double](Get-Opt $loud "true_peak" -1.5)
$out = Resolve-Output $spec.output
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null

$script:TMP = Join-Path ([IO.Path]::GetTempPath()) ("kaist-shorts-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $script:TMP | Out-Null
try {
    Copy-Item -LiteralPath $FONT -Destination (Join-Path $script:TMP "font.otf")

    # 1차: 소리만 돌려 loudnorm이 잰 값을 읽는다
    $b = Build-Inputs $segs $audio $sfx $false
    $ln1 = "loudnorm=I=$(F $target):TP=$(F $peak):LRA=11:print_format=json"
    $g1 = (Audio-Filters $segs $audio $sfx $b.idx $total $ln1) -join ";`n"
    [IO.File]::WriteAllText((Join-Path $script:TMP "audio1.txt"), $g1, $utf8)
    $r1 = Run-FFmpeg (@("-hide_banner", "-nostats") + $b.args + @($graphFlag, "audio1.txt", "-map", "[aout]", "-f", "null", "-")) $script:TMP "소리 음량 측정"
    if ($r1.Err -notmatch '\{[^{}]*"input_i"[^{}]*\}') { Fail ("loudnorm 측정값을 읽지 못했습니다.`n" + $r1.Err) }
    $m = $Matches[0] | ConvertFrom-Json
    Say ("1차 측정: 통합 {0} LUFS, 피크 {1} dBTP -> 목표 {2} LUFS" -f $m.input_i, $m.input_tp, $target)
    $ln2 = "loudnorm=I=$(F $target):TP=$(F $peak):LRA=11:measured_I=$($m.input_i):measured_TP=$($m.input_tp):measured_LRA=$($m.input_lra):measured_thresh=$($m.input_thresh):offset=$($m.target_offset):linear=true"

    # 2차: 영상 + 소리
    $b = Build-Inputs $segs $audio $sfx $true
    $g2 = ((Video-Filters $spec $segs $b.idx $total) + (Audio-Filters $segs $audio $sfx $b.idx $total $ln2)) -join ";`n"
    [IO.File]::WriteAllText((Join-Path $script:TMP "graph.txt"), $g2, $utf8)
    $encArgs = @("-map", "[vout]", "-map", "[aout]", "-t", (F $total), "-r", $FPS,
        "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", $out)
    [void](Run-FFmpeg (@("-hide_banner", "-nostats", "-y") + $b.args + @($graphFlag, "graph.txt") + $encArgs) $script:TMP "영상 만들기")
}
finally {
    if (-not $KeepTemp) { Remove-Item -LiteralPath $script:TMP -Recurse -Force -ErrorAction SilentlyContinue }
    else { Say "임시 폴더: $($script:TMP)" }
}
Say ("완료: {0} ({1:0.00}초)" -f $out, $total)

if (-not $NoOpen) {
    try {
        if ($env:OS -eq "Windows_NT") { Start-Process -FilePath $out }
        elseif (Get-Command open -ErrorAction SilentlyContinue) { & open $out }
        elseif (Get-Command xdg-open -ErrorAction SilentlyContinue) { & xdg-open $out }
    } catch { Say "영상은 만들었지만 자동으로 열지 못했습니다. 위 경로의 파일을 직접 열어 주세요." }
}
