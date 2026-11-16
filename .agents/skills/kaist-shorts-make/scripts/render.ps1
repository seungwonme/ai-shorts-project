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
    [switch]$KeepTemp,
    [switch]$Check
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
# 자막 위치(spec의 subtitle_position): inside(기본, 영상 영역 안 아래), bar(영역 안 아래 + 검은 반투명 띠), below(영상 영역 아래, 하단 안내 문구 밑)
$CAPTION_BELOW_BASELINE = 1540; $CAPTION_BELOW_SIZE = 44
$CAPTION_BAR_H = 92; $CAPTION_BAR_ALPHA = 0.72
# 자막 영역: 영상 영역(1080x756) 아래쪽 25%. 안쪽 자막은 글자 높이 40px 한 줄이 맨 아래에서 36px 위(영역의 89-95%)에 놓인다. 여유를 두어 아래 25%를 비워 두고, 강조 박스는 그 위에 둔다.
$CAPTION_ZONE_FRAC = 0.25
# 이 기사(69410) 포스터 img-01.jpg(800x1000)에서 글자가 잘리지 않고 중요한 글자가 위쪽 75%에 오도록 검증한 크롭. crop 에 "poster:title" 처럼 이름으로 쓴다.
$POSTER_CROPS = [ordered]@{
    title    = @{ x = 0.07; y = 0.02;  w = 0.86; h = 0.482 }
    keywords = @{ x = 0.05; y = 0.25;  w = 0.90; h = 0.504 }
    logos    = @{ x = 0.01; y = 0.412; w = 0.98; h = 0.549 }
    date     = @{ x = 0.03; y = 0.445; w = 0.94; h = 0.526 }
}
$POSTER_CROP_HINT = '권장 크롭(이 기사 포스터에서 검증): crop 에 "poster:title"(제목), "poster:keywords"(주제어), "poster:logos"(기관 로고줄), "poster:date"(날짜와 장소) 중 하나를 쓰면 됩니다. 숫자를 쓰려면 title {x:0.07,y:0.02,w:0.86,h:0.482}, keywords {x:0.05,y:0.25,w:0.9,h:0.504}, logos {x:0.01,y:0.412,w:0.98,h:0.549}, date {x:0.03,y:0.445,w:0.94,h:0.526}. 이 점검의 기준값은 이 포스터에 맞춰져 있어 다른 이미지에서 잘못 걸리면 crop 을 조정해 통과시키세요.'
$SPOT_MAX_RUN = 3   # 기사에 이미지가 있으면 본문 highlight 조각은 연속 3개까지
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
# FFmpeg xfade 가 아는 전환 이름(ffmpeg 9.0.2 -h filter=xfade 로 확인). 이름이 다르면 ffmpeg 오류 대신 쉬운 한국어로 멈춘다.
$XFADE_NAMES = @("fade", "wipeleft", "wiperight", "wipeup", "wipedown", "slideleft", "slideright", "slideup", "slidedown", "circlecrop", "rectcrop", "distance", "fadeblack", "fadewhite", "radial", "smoothleft", "smoothright", "smoothup", "smoothdown", "circleopen", "circleclose", "vertopen", "vertclose", "horzopen", "horzclose", "dissolve", "pixelize", "diagtl", "diagtr", "diagbl", "diagbr", "hlslice", "hrslice", "vuslice", "vdslice", "hblur", "fadegrays", "wipetl", "wipetr", "wipebl", "wipebr", "squeezeh", "squeezev", "zoomin", "fadefast", "fadeslow", "hlwind", "hrwind", "vuwind", "vdwind", "coverleft", "coverright", "coverup", "coverdown", "revealleft", "revealright", "revealup", "revealdown")
function Transition-Of($seg) {
    $kind = Get-Opt $seg "transition" "cut"
    if ($kind -is [string] -or $null -eq $kind) { } else {
        # {"name": "fade", "duration": 0.4} 형식도 받는다
        $nm = [string](Get-Opt $kind "name" "fade"); $du = [double](Get-Opt $kind "duration" 0.3)
        if ($nm -eq "cut") { return @("cut", 0.0) }
        return @($nm, $du)
    }
    if ($kind -eq "cut") { return @("cut", 0.0) }
    return @($kind, [double](Get-Opt $seg "transition_duration" 0.3))
}

# ---- 입력 목록 ---------------------------------------------------------------------------
function Build-Inputs($segs, $audio, $sfx, [bool]$overlays, [bool]$withBgm = $false) {
    $a = New-Object System.Collections.ArrayList
    $idx = @{ seg_v = @(); seg_a = @(); narr = $null; sfx = @(); bgm = $null; logo = $null; arrow = $null }
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
    if ($withBgm) {
        # 곡이 영상보다 짧으면 끝없이 되풀이해서 읽고, 필터에서 영상 길이로 자른다.
        [void]$a.AddRange(@("-stream_loop", "-1", "-i", $audio.bgm_abs)); $idx.bgm = $n; $n++
    }
    if ($overlays) {
        if ($script:LOGO) { [void]$a.AddRange(@("-i", $script:LOGO)); $idx.logo = $n; $n++ }
        [void]$a.AddRange(@("-i", $script:ARROW)); $idx.arrow = $n; $n++
    }
    return @{ args = [string[]]$a.ToArray(); idx = $idx }
}

# ---- 필터 그래프: 영상 --------------------------------------------------------------------
# image 조각의 선택 필드 crop: 원본 사진에서 잘라 쓸 영역. 0-1 분수 {x, y, w, h} (원본 가로 세로 대비, 왼쪽 위가 기준).
# 없으면 $null (사진 전체). 잘못된 값이면 한국어 한 문장으로 멈춘다.
function Get-Crop($seg, [int]$n) {
    $c = Get-Opt $seg "crop" $null
    if ($null -eq $c) { return $null }
    if (@("image", "highlight") -notcontains [string]$seg.type) { Fail "조각 ${n}번: crop은 사진(image)과 highlight 조각에만 쓸 수 있습니다." }
    $v = @{}
    foreach ($k in @("x", "y", "w", "h")) {
        $p = $c.PSObject.Properties[$k]
        $d = 0.0
        if ($null -eq $p -or $null -eq $p.Value -or -not ([double]::TryParse([string]$p.Value, [Globalization.NumberStyles]::Float, $inv, [ref]$d))) { Fail "조각 ${n}번: crop에는 x, y, w, h 네 숫자(0에서 1 사이 분수)가 모두 있어야 합니다." }
        $v[$k] = $d
    }
    if ($v.x -lt 0 -or $v.y -lt 0 -or $v.x -ge 1 -or $v.y -ge 1) { Fail "조각 ${n}번: crop의 x, y는 0 이상 1 미만이어야 합니다." }
    if ($v.w -le 0 -or $v.h -le 0) { Fail "조각 ${n}번: crop의 w, h는 0보다 커야 합니다." }
    if ($v.x + $v.w -gt 1.0001 -or $v.y + $v.h -gt 1.0001) { Fail "조각 ${n}번: crop 영역이 사진 밖으로 나갑니다 (x+w와 y+h는 1 이하여야 합니다)." }
    if ($v.w -lt 0.03 -or $v.h -lt 0.03) { Fail "조각 ${n}번: crop 영역이 너무 작습니다 (w, h는 0.03 이상으로 해 주세요)." }
    $ratio = $v.w / $v.h
    if ($ratio -gt 20 -or $ratio -lt 0.05) { Fail "조각 ${n}번: crop 영역의 가로와 세로 비율이 너무 극단적입니다 (w와 h의 차이를 줄여 주세요)." }
    return New-Object psobject -Property @{ x = $v.x; y = $v.y; w = $v.w; h = $v.h }
}

# ---- highlight(사진 위 빨간 박스)와 text_card(기사 문장 카드), 그리고 렌더 전 규칙 점검 ----------------
# 박스 테두리는 FFmpeg drawbox, 카드 글자는 틀의 제목과 같은 drawtext(Gmarket Sans)로 그린다.
$HL_RED = "0xFF3B30"; $HL_DIM = "0.58"; $HL_T = 5; $HL_AT = 0.3; $HL_FADE = 0.3
$CARD_SIZE = 44; $CARD_PAD_X = 60; $CARD_LINE_H = 66; $CARD_GAP = 22; $CARD_MAX_LINES = 7; $CARD_BOX_PAD = 14
$MAX_PIECE_SEC = 4.0; $MAX_BAR = 0.15
$script:DimCache = @{}
$script:SegBoxes = @{}
$script:CardLayouts = @{}

function Is-Pic($seg) { return (@("image", "highlight") -contains [string]$seg.type) }

function Get-ImageSize([string]$path) {
    if ($script:DimCache.ContainsKey($path)) { return $script:DimCache[$path] }
    $info = Invoke-Tool $script:FFMPEG_EXE @("-hide_banner", "-i", $path) $null
    $dm = [regex]::Match(($info.Err + $info.Out), 'Video:.*?[, ](\d{2,6})x(\d{2,6})')
    $res = $null
    if ($dm.Success) { $res = @([double]$dm.Groups[1].Value, [double]$dm.Groups[2].Value) }
    $script:DimCache[$path] = $res
    return $res
}

# image/highlight 조각이 영상 영역(1080x756)에 놓이는 모양: 크기(sw, sh)와 왼쪽 위 위치(ox, oy). 채우기는 ox, oy가 음수일 수 있다.
function Get-Geom($seg, [int]$n) {
    $dim = Get-ImageSize $seg.abs
    if (-not $dim) { Fail "조각 ${n}번: 사진 크기를 읽지 못했습니다: $($seg.src)" }
    $cr = Get-Crop $seg $n
    $rw = $dim[0]; $rh = $dim[1]
    if ($cr) { $rw = $rw * $cr.w; $rh = $rh * $cr.h }
    $fitw = ((Get-Opt $seg "fit" "") -eq "width")
    if ($fitw) { $s = [Math]::Min($VIDEO_W / $rw, $VIDEO_H / $rh) } else { $s = [Math]::Max($VIDEO_W / $rw, $VIDEO_H / $rh) }
    $sw = [Math]::Round($rw * $s); $sh = [Math]::Round($rh * $s)
    return New-Object psobject -Property @{ sw = $sw; sh = $sh; ox = [Math]::Round(($VIDEO_W - $sw) / 2); oy = [Math]::Round(($VIDEO_H - $sh) / 2); fitw = $fitw; rw = $rw; rh = $rh }
}

# highlight 조각의 box: 기준 이미지(crop이 있으면 잘라낸 영역, 없으면 사진 전체)에 대한 0-1 분수. 영상 영역 픽셀 사각형으로 바꿔 돌려준다.
function Get-Boxes($seg, [int]$n, $g) {
    $raw = Get-Opt $seg "box" $null
    if ($null -eq $raw) { Fail "조각 ${n}번: highlight 조각에는 box {x, y, w, h}(0에서 1 사이 분수, 기준 이미지 대비)가 필요합니다." }
    $out = @()
    foreach ($b in @($raw)) {
        $v = @{}
        foreach ($k in @("x", "y", "w", "h")) {
            $p = $b.PSObject.Properties[$k]
            $d = 0.0
            if ($null -eq $p -or $null -eq $p.Value -or -not ([double]::TryParse([string]$p.Value, [Globalization.NumberStyles]::Float, $inv, [ref]$d))) { Fail "조각 ${n}번: box에는 x, y, w, h 네 숫자(0에서 1 사이 분수)가 모두 있어야 합니다." }
            $v[$k] = $d
        }
        if ($v.x -lt 0 -or $v.y -lt 0 -or $v.w -le 0 -or $v.h -le 0 -or $v.x + $v.w -gt 1.0001 -or $v.y + $v.h -gt 1.0001) {
            Fail "조각 ${n}번: box가 기준 이미지 밖으로 나갑니다 (x, y는 0 이상, w, h는 0보다 크고 x+w, y+h는 1 이하여야 합니다)."
        }
        $px = [Math]::Round($g.ox + $v.x * $g.sw); $py = [Math]::Round($g.oy + $v.y * $g.sh)
        $pw = [Math]::Round($v.w * $g.sw); $ph = [Math]::Round($v.h * $g.sh)
        if ($pw -lt 12 -or $ph -lt 12) { Fail "조각 ${n}번: box가 너무 작습니다 (영상 영역에서 12픽셀 이상이어야 합니다)." }
        if ($px -lt -2 -or $py -lt -2 -or $px + $pw -gt $VIDEO_W + 2 -or $py + $ph -gt $VIDEO_H + 2) {
            Fail ("조각 ${n}번: box가 영상 영역 밖으로 나갑니다 (이 조각은 사진의 가장자리가 잘려 box 일부가 보이지 않습니다). box를 영역 안으로 옮기거나, crop으로 box가 있는 부분만 잘라 쓰거나, fit을 width로 해 주세요.")
        }
        $px = [Math]::Max(0, $px); $py = [Math]::Max(0, $py)
        $pw = [Math]::Min($pw, $VIDEO_W - $px); $ph = [Math]::Min($ph, $VIDEO_H - $py)
        $out += New-Object psobject -Property @{ x = [int]$px; y = [int]$py; w = [int]$pw; h = [int]$ph }
    }
    return , @($out)
}

# text_card: lines(문장 목록)를 글자 크기 44로 줄바꿈해 흰 카드에 놓는 계산. 강조할 줄(highlight, 1부터)의 박스 좌표도 여기서 계산한다.
function Get-CardLayout($seg, [int]$n) {
    $sents = @()
    foreach ($l in @(Get-Opt $seg "lines" @())) { $t = ([string]$l).Trim(); if ($t) { $sents += $t } }
    if ($sents.Count -lt 1) { Fail "조각 ${n}번: text_card에는 lines(기사 문장 목록)가 필요합니다." }
    $maxW = $VIDEO_W - 2 * $CARD_PAD_X
    $vis = @()
    for ($k = 0; $k -lt $sents.Count; $k++) {
        $cur = ""
        foreach ($word in @($sents[$k] -split '\s+')) {
            if (-not $word) { continue }
            if ((Get-LineWidth $word $CARD_SIZE 0) -gt $maxW) { Fail "조각 ${n}번: text_card의 낱말 '$word'이 카드 폭보다 길어 글자가 잘립니다. 문장을 고쳐 주세요." }
            if ($cur -eq "") { $try = $word } else { $try = "$cur $word" }
            if ((Get-LineWidth $try $CARD_SIZE 0) -le $maxW) { $cur = $try }
            else { $vis += New-Object psobject -Property @{ text = $cur; sent = $k }; $cur = $word }
        }
        if ($cur -ne "") { $vis += New-Object psobject -Property @{ text = $cur; sent = $k } }
    }
    if ($vis.Count -gt $CARD_MAX_LINES) {
        Fail ("조각 ${n}번: text_card의 글자가 한 카드에 다 들어가지 않습니다 (줄바꿈하면 {0}줄, 한 카드는 {1}줄까지). lines를 둘로 나눠 카드 2장(조각 2개)으로 만들어 주세요." -f $vis.Count, $CARD_MAX_LINES)
    }
    $height = $vis.Count * $CARD_LINE_H + ($sents.Count - 1) * $CARD_GAP
    $top = [Math]::Floor(($VIDEO_H - $height) / 2)
    for ($i = 0; $i -lt $vis.Count; $i++) {
        $vis[$i] | Add-Member -NotePropertyName y -NotePropertyValue ($top + $i * $CARD_LINE_H + $vis[$i].sent * $CARD_GAP) -Force
    }
    $hlRaw = Get-Opt $seg "highlight" $null
    $boxes = @()
    foreach ($hv in @($hlRaw)) {
        if ($null -eq $hv) { continue }
        $hn = 0
        if (-not [int]::TryParse([string]$hv, [ref]$hn) -or $hn -lt 1 -or $hn -gt $sents.Count) { Fail "조각 ${n}번: highlight는 lines의 줄 번호(1에서 $($sents.Count) 사이 정수, 여러 개는 목록)여야 합니다." }
        $mine = @($vis | Where-Object { $_.sent -eq ($hn - 1) })
        $wmax = 0.0
        foreach ($m in $mine) { $wmax = [Math]::Max($wmax, (Get-LineWidth $m.text $CARD_SIZE 0)) }
        $boxes += New-Object psobject -Property @{ x = [int]($CARD_PAD_X - $CARD_BOX_PAD); y = [int]($mine[0].y - 2); w = [int][Math]::Ceiling($wmax + 2 * $CARD_BOX_PAD); h = [int]($mine.Count * $CARD_LINE_H + 4) }
    }
    return New-Object psobject -Property @{ vis = $vis; boxes = @($boxes) }
}

# crop "poster": 기사 캡처(page.png)에서 첫 기사 이미지(포스터 그림)의 위쪽을 영상 영역 비율(1080:756)로 자른다. page-boxes.json 의 images[0] 좌표를 쓴다.
function Resolve-PosterCrops($segs) {
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $seg = $segs[$i]; $n = $i + 1
        if (@("image", "highlight") -notcontains [string]$seg.type) { continue }
        $co = Get-Opt $seg "crop" $null
        if ($co -is [string] -and $co -like "poster:*") {
            # 이름 붙인 포스터 크롭: 이 기사(69410)의 포스터 img-NN.jpg(800x1000)에서 검증한 값. 숫자를 직접 쓰지 않아도 된다.
            $nm = ([string]$co).Substring(7)
            if (-not $POSTER_CROPS.Contains($nm)) { Fail ("조각 ${n}번: 포스터 크롭 이름 '$nm' 을 모릅니다. 쓸 수 있는 이름: " + (($POSTER_CROPS.Keys | ForEach-Object { "poster:$_" }) -join ", ")) }
            if ((Split-Path -Leaf $seg.abs) -notlike "img-*") { Fail "조각 ${n}번: crop `"$co`" 는 기사 포스터 사진(img-01.jpg 같은 재료 폴더의 기사 이미지)에만 쓸 수 있습니다." }
            $dimP = Get-ImageSize $seg.abs
            if ($dimP -and [Math]::Abs($dimP[0] / [double]$dimP[1] - 0.8) -gt 0.05) { Fail "조각 ${n}번: crop `"$co`" 는 가로 세로 4:5 포스터(800x1000)용입니다. 이 사진은 $($dimP[0])x$($dimP[1]) 이라 직접 crop 숫자를 써 주세요." }
            $v = $POSTER_CROPS[$nm]
            $seg | Add-Member -MemberType NoteProperty -Name crop -Value ([pscustomobject]@{ x = $v.x; y = $v.y; w = $v.w; h = $v.h }) -Force
            continue
        }
        if (-not ($co -is [string] -and $co -eq "poster")) { continue }
        $bj = Join-Path (Split-Path -Parent $seg.abs) "page-boxes.json"
        if ((Split-Path -Leaf $seg.abs) -ne "page.png" -or -not (Test-Path -LiteralPath $bj)) { Fail "조각 ${n}번: crop `"poster`" 는 capture-article.ps1 이 만든 page.png 와 page-boxes.json 이 있을 때만 쓸 수 있습니다." }
        $pb = Get-Content -LiteralPath $bj -Raw -Encoding UTF8 | ConvertFrom-Json
        $im = @($pb.images)
        if ($im.Count -lt 1) { Fail "조각 ${n}번: 기사 캡처에 이미지(포스터)가 없어 crop `"poster`" 를 쓸 수 없습니다." }
        $b = $im[0].box
        $iw = [double]$pb.image.w; $ih = [double]$pb.image.h
        # 포스터 위쪽에서 좌우 7% 여백을 두고(글자가 잘리지 않게) 제목 블록이 영역의 위쪽 75% 안에 오게 자른다
        $pw = [double]$b.w * 0.86
        $hPx = [Math]::Min([double]$b.h * $ih * 0.98, $pw * $iw * $VIDEO_H / $VIDEO_W)
        $seg | Add-Member -MemberType NoteProperty -Name crop -Value ([pscustomobject]@{ x = [Math]::Round([double]$b.x + [double]$b.w * 0.07, 5); y = [Math]::Round([double]$b.y + [double]$b.h * 0.02, 5); w = [Math]::Round($pw, 5); h = [Math]::Round($hPx / $ih, 5) }) -Force
    }
}

# 기사 캡처(page.png)의 문장 지정: highlight 조각에 sentence(문장 번호, 여러 개는 목록) 또는 quote(문장 앞부분)를 쓰면
# capture-article.ps1 이 만든 page-boxes.json 의 좌표로 crop(자동)과 box를 계산해 채운다. 모델이 좌표를 추측하지 않는다.
# 선택: lines [처음, 끝] = 그 문장의 몇 번째 줄부터 몇 번째 줄까지만 박스로 칠한다(긴 문장을 여러 조각으로 나눌 때).
$script:BoxesCache = @{}
function Resolve-Sentences($segs) {
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $seg = $segs[$i]; $n = $i + 1
        if ($seg.type -ne "highlight") { continue }
        $sent = Get-Opt $seg "sentence" $null
        $quote = [string](Get-Opt $seg "quote" "")
        if ($null -eq $sent -and -not $quote) {
            $c0 = Get-Opt $seg "crop" $null
            if ($c0 -is [string]) { Fail "조각 ${n}번: crop `"$c0`" 는 sentence 나 quote 와 함께 써야 합니다." }
            continue
        }
        if ($null -ne (Get-Opt $seg "box" $null)) { Fail "조각 ${n}번: sentence/quote 와 box 를 같이 쓸 수 없습니다 (box는 문장에서 자동으로 계산됩니다)." }
        $bj = Join-Path (Split-Path -Parent $seg.abs) "page-boxes.json"
        if ((Split-Path -Leaf $seg.abs) -ne "page.png" -or -not (Test-Path -LiteralPath $bj)) { Fail "조각 ${n}번: 문장 지정(sentence, quote)은 capture-article.ps1 이 만든 page.png 와 page-boxes.json 이 있을 때만 쓸 수 있습니다." }
        if (-not $script:BoxesCache.ContainsKey($bj)) { $script:BoxesCache[$bj] = (Get-Content -LiteralPath $bj -Raw -Encoding UTF8 | ConvertFrom-Json) }
        $pb = $script:BoxesCache[$bj]
        $all = @()
        foreach ($p in @($pb.paragraphs)) { foreach ($sn in @($p.sentences)) { $all += $sn } }
        $pick = @()
        if ($null -ne $sent) {
            foreach ($sv in @($sent)) {
                $num = 0
                if (-not [int]::TryParse([string]$sv, [ref]$num)) { Fail "조각 ${n}번: sentence 는 문장 번호(정수, 여러 개는 목록)여야 합니다." }
                $hit = @($all | Where-Object { [int]$_.n -eq $num })
                if ($hit.Count -ne 1) { Fail "조각 ${n}번: page-boxes.json 에 문장 번호 $num 이 없습니다 (1에서 $($all.Count) 사이)." }
                $pick += $hit[0]
            }
        } else {
            $qn = ($quote -replace '\s+', ' ').Trim()
            if ($qn.Length -lt 4) { Fail "조각 ${n}번: quote 는 문장 앞부분 4글자 이상이어야 합니다." }
            $hit = @($all | Where-Object { ([string]$_.text).StartsWith($qn) })
            if ($hit.Count -eq 0) { $hit = @($all | Where-Object { ([string]$_.text).Contains($qn) }) }
            if ($hit.Count -eq 0) { Fail "조각 ${n}번: quote `"$qn`" 로 시작하는 문장이 page-boxes.json 에 없습니다. 문장 번호(sentence)를 쓰거나 기사 글자 그대로 적어 주세요." }
            if ($hit.Count -gt 1) { Fail ("조각 ${n}번: quote `"$qn`" 에 맞는 문장이 {0}개입니다(문장 번호 {1}). 더 길게 적거나 sentence 번호를 써 주세요." -f $hit.Count, (($hit | ForEach-Object { $_.n }) -join ", ")) }
            $pick += $hit[0]
        }
        $rects = @()
        $lr = Get-Opt $seg "lines" $null
        foreach ($sn in $pick) {
            $ls = @($sn.lines)
            if ($null -ne $lr -and $pick.Count -eq 1) {
                $lv = @($lr)
                if ($lv.Count -ne 2) { Fail "조각 ${n}번: lines 는 [처음 줄, 끝 줄] 두 숫자입니다." }
                $a1 = [int]$lv[0]; $b1 = [int]$lv[1]
                if ($a1 -lt 1 -or $b1 -lt $a1 -or $b1 -gt $ls.Count) { Fail "조각 ${n}번: lines 는 1부터 $($ls.Count) 사이이고 처음 줄이 끝 줄보다 크지 않아야 합니다 (이 문장은 $($ls.Count)줄)." }
                if ($ls.Count -gt 1 -and ($a1 -ne 1 -or $b1 -ne $ls.Count)) {
                    # 줄 단위로 나눈 박스가 문장 끝 한두 단어만 치면 멈춘다 (문장 글자 수는 줄 폭 비율로 나눠 센다)
                    $wAll = ($ls | ForEach-Object { [double]$_.w } | Measure-Object -Sum).Sum
                    $wMax = ($ls | ForEach-Object { [double]$_.w } | Measure-Object -Maximum).Maximum
                    $nCh = ([string]$sn.text).Length
                    $sel = @($ls[($a1 - 1)..($b1 - 1)])
                    $wSel = ($sel | ForEach-Object { [double]$_.w } | Measure-Object -Sum).Sum
                    $short = ($wSel / $wAll) -lt 0.4
                    foreach ($ln in $sel) { if ($nCh * [double]$ln.w / $wAll -lt 5) { $short = $true } }
                    if ($sel.Count -eq 1 -and ([double]$sel[0].w / $wMax) -lt 0.6) { $short = $true }
                    if ($short) { Fail "조각 ${n}번: 문장을 줄 단위로 나누면 박스가 너무 짧아집니다 (문장 $($sn.n)의 lines [$a1,$b1]). 문장 전체를 한 화면에 담거나 다른 문장으로 넘어가세요." }
                }
                $ls = @($ls[($a1 - 1)..($b1 - 1)])
            }
            foreach ($l in $ls) { $rects += $l }
        }
        $iw = [double]$pb.image.w; $ih = [double]$pb.image.h
        $dim = Get-ImageSize $seg.abs
        if ($dim -and ([Math]::Abs($dim[0] - $iw) -gt 1 -or [Math]::Abs($dim[1] - $ih) -gt 1)) { Fail "조각 ${n}번: page.png 크기($($dim[0])x$($dim[1]))가 page-boxes.json 의 기록(${iw}x${ih})과 다릅니다. capture-article.ps1 을 다시 실행해 주세요." }
        $x0 = ($rects | ForEach-Object { [double]$_.x } | Measure-Object -Minimum).Minimum
        $y0 = ($rects | ForEach-Object { [double]$_.y } | Measure-Object -Minimum).Minimum
        $x1 = ($rects | ForEach-Object { [double]$_.x + [double]$_.w } | Measure-Object -Maximum).Maximum
        $y1 = ($rects | ForEach-Object { [double]$_.y + [double]$_.h } | Measure-Object -Maximum).Maximum
        $padX = 10 / $iw; $padY = 6 / $ih
        # 주의: PowerShell 7 에서 [Math]::Max(0, 소수)는 정수로 잘려 0이 되므로 숫자를 [double]로 맞춘다
        $x0 = [Math]::Max([double]0, $x0 - $padX); $y0 = [Math]::Max([double]0, $y0 - $padY); $x1 = [Math]::Min([double]1, $x1 + $padX); $y1 = [Math]::Min([double]1, $y1 + $padY)
        $u = @{ x = $x0; y = $y0; w = $x1 - $x0; h = $y1 - $y0 }
        # crop: 직접 준 값이 없으면(또는 "auto") 페이지 전체 폭으로, 영상 영역 비율(1080:756)에 맞춰 문장을 세로 가운데에 둔다.
        $co = Get-Opt $seg "crop" $null
        if ($null -eq $co -or ($co -is [string] -and $co -eq "auto")) {
            $chPx = $iw * $VIDEO_H / $VIDEO_W
            if ($chPx -ge $ih) { $cr = @{ x = 0.0; y = 0.0; w = 1.0; h = 1.0 } }
            else {
                $chf = $chPx / $ih
                # 강조 문장을 영상 영역 위쪽 약 35% 높이에 둔다(아래 25%는 자막 영역)
                $cy = $u.y + $u.h / 2 - $chf * 0.35
                $cy = [Math]::Max([double]0, [Math]::Min([double]$cy, [double](1 - $chf)))
                $cr = @{ x = 0.0; y = $cy; w = 1.0; h = $chf }
            }
        } else { $c1 = Get-Crop $seg $n; $cr = @{ x = $c1.x; y = $c1.y; w = $c1.w; h = $c1.h } }
        if ($u.x -lt $cr.x - 0.002 -or $u.y -lt $cr.y - 0.002 -or $u.x + $u.w -gt $cr.x + $cr.w + 0.002 -or $u.y + $u.h -gt $cr.y + $cr.h + 0.002) {
            Fail ("조각 ${n}번: 이 문장은 {0}줄이라 한 화면(영상 영역)에 글자가 읽히는 크기로 다 담기지 않습니다. lines [처음, 끝]으로 줄을 나눠 조각 2개로 만들거나(예: lines [1,3]과 lines [4,6]), 더 짧은 문장을 고르세요." -f $rects.Count)
        }
        # 글자 크기 점검: 영상에서 한 줄의 높이(픽셀)가 40 미만이면 작게 보인다.
        $lineH = ($rects | ForEach-Object { [double]$_.h * $ih } | Measure-Object -Average).Average
        $outLineH = $lineH * $VIDEO_W / ($iw * $cr.w)
        if ($outLineH -lt 40) { Say ("경고: 조각 {0}번의 글자가 작게 보일 수 있습니다 (영상에서 한 줄 높이 약 {1}픽셀). capture-article.ps1 을 -Width 를 줄여 다시 실행하면 글자가 커집니다." -f $n, [Math]::Round($outLineH)) }
        $rel = [pscustomobject]@{ x = [Math]::Round(($u.x - $cr.x) / $cr.w, 5); y = [Math]::Round(($u.y - $cr.y) / $cr.h, 5); w = [Math]::Round($u.w / $cr.w, 5); h = [Math]::Round($u.h / $cr.h, 5) }
        $seg | Add-Member -MemberType NoteProperty -Name crop -Value ([pscustomobject]@{ x = [Math]::Round($cr.x, 5); y = [Math]::Round($cr.y, 5); w = [Math]::Round($cr.w, 5); h = [Math]::Round($cr.h, 5) }) -Force
        $seg | Add-Member -MemberType NoteProperty -Name box -Value $rel -Force
        Say ("조각 {0}번: 문장 {1} -> {2}" -f $n, (($pick | ForEach-Object { $_.n }) -join ","), (([string]$pick[0].text).Substring(0, [Math]::Min(24, ([string]$pick[0].text).Length))))
    }
}

# 사진의 어떤 영역(0-1 분수)이 사실상 비어 있는지(글자나 그림이 없는지) 잰다: 32x16 칸으로 평균 낸 밝기의 최댓값-최솟값.
function Get-RegionRange([string]$img, $r, $dim) {
    $px = [Math]::Max(0, [Math]::Floor($r.x * $dim[0])); $py = [Math]::Max(0, [Math]::Floor($r.y * $dim[1]))
    $pw = [Math]::Max(2, [Math]::Min($dim[0] - $px, [Math]::Floor($r.w * $dim[0]))); $ph = [Math]::Max(2, [Math]::Min($dim[1] - $py, [Math]::Floor($r.h * $dim[1])))
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kaist-region-" + [Guid]::NewGuid().ToString("N").Substring(0, 8) + ".raw")
    try {
        $res = Invoke-Tool $script:FFMPEG_EXE @("-hide_banner", "-v", "error", "-y", "-i", $img, "-vf", "crop=${pw}:${ph}:${px}:${py},scale=32:16:flags=area,format=gray", "-frames:v", "1", "-f", "rawvideo", $tmp) $null
        if ($res.Code -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { return $null }
        $b = [IO.File]::ReadAllBytes($tmp)
        if ($b.Length -lt 16) { return $null }
        return ([int]($b | Measure-Object -Maximum).Maximum - [int]($b | Measure-Object -Minimum).Minimum)
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# 포스터 같은 사진 조각(박스 없는 image)이 영상 영역에 어떻게 보이는지 216x151 회색 그림으로 떠서 글자 가장자리(엣지) 밀도를 잰다.
# 경고 1: 아래 25%(자막 영역)의 엣지 밀도가 위 75%의 70% 이상이면 중요한 글자가 자막 아래로 몰린 것이다.
# 경고 2: 왼쪽/오른쪽 가장자리 4열에 엣지가 3% 넘게 있으면 글자가 크롭 가장자리에 걸쳐 잘렸을 가능성이 크다.
# 걸리면 Test-Spec 이 멈춘다(안내에 권장 크롭 이름과 숫자가 있다). 세로 포스터 이미지 조각에만 쓰고, 영상 조각(video)과 가로 사진에는 쓰지 않는다.
function Test-PicPiece($seg, [int]$n) {
    $out = @()
    if ([string]$seg.type -ne "image") { return $out }
    $g = Get-Geom $seg $n
    if ($g.fitw) { return $out }
    # 세로로 긴 포스터(높이가 폭의 1.1배 이상)에만 쓴다. 가로 사진과 영상 장면은 어디나 무늬가 있어 이 측정이 맞지 않는다.
    $dimQ = Get-ImageSize $seg.abs
    if (-not $dimQ -or ([double]$dimQ[1] / [double]$dimQ[0]) -lt 1.1) { return $out }
    $c = Get-Crop $seg $n
    $cx = 0.0; $cy = 0.0; $cw = 1.0; $ch = 1.0
    if ($c) { $cx = [double]$c.x; $cy = [double]$c.y; $cw = [double]$c.w; $ch = [double]$c.h }
    $W = 216; $H = 151
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kaist-edge-" + [Guid]::NewGuid().ToString("N").Substring(0, 8) + ".raw")
    try {
        $vf = "crop=iw*$(F $cw):ih*$(F $ch):iw*$(F $cx):ih*$(F $cy),scale=${W}:${H}:force_original_aspect_ratio=increase,crop=${W}:${H},format=gray"
        $res = Invoke-Tool $script:FFMPEG_EXE @("-hide_banner", "-v", "error", "-y", "-i", $seg.abs, "-vf", $vf, "-frames:v", "1", "-f", "rawvideo", $tmp) $null
        if ($res.Code -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { return $out }
        $b = [IO.File]::ReadAllBytes($tmp)
        if ($b.Length -lt ($W * $H)) { return $out }
        $cut = [int][Math]::Floor($H * 0.75)
        $nTop = 0; $nBot = 0; $nL = 0; $nR = 0
        for ($y = 0; $y -lt $H; $y++) {
            for ($x = 0; $x -lt $W; $x++) {
                $v = [int]$b[$y * $W + $x]
                $e = $false
                if ($x -lt $W - 1 -and [Math]::Abs([int]$b[$y * $W + $x + 1] - $v) -gt 40) { $e = $true }
                elseif ($y -lt $H - 1 -and [Math]::Abs([int]$b[($y + 1) * $W + $x] - $v) -gt 40) { $e = $true }
                if ($e) {
                    if ($y -lt $cut) { $nTop++ } else { $nBot++ }
                    if ($x -lt 4) { $nL++ }
                    if ($x -ge $W - 4) { $nR++ }
                }
            }
        }
        $dTop = $nTop / [double]($cut * $W); $dBot = $nBot / [double](($H - $cut) * $W)
        $dL = $nL / [double](4 * $H); $dR = $nR / [double](4 * $H)
        if ($dBot -ge 0.03 -and $dBot -ge 0.7 * $dTop) { $out += "조각 ${n}번: 영상 영역 아래쪽 25%(자막 영역)에 글자나 로고가 몰려 있어 자막이 덮습니다. 크롭을 위로 올려 중요한 글자가 영상 영역의 위쪽 75%에 오게 하세요. $POSTER_CROP_HINT" }
        if ($dL -gt 0.03 -or $dR -gt 0.03) { $out += "조각 ${n}번: 크롭의 좌우 가장자리에 글자나 그림이 걸쳐 있어 잘렸습니다. 크롭의 좌우 여백을 늘리세요. $POSTER_CROP_HINT" }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    return $out
}

function Region-Key($seg, [int]$n, $g) {
    if ($seg.type -eq "text_card") {
        $hl = (@(Get-Opt $seg "highlight" @()) | ForEach-Object { [string]$_ }) -join ","
        return "카드|" + ((@($seg.lines) | ForEach-Object { ([string]$_).Trim() }) -join "/") + "|" + $hl
    }
    $cr = Get-Crop $seg $n
    $ck = "전체"
    if ($cr) { $ck = ("{0},{1},{2},{3}" -f (F ([Math]::Round($cr.x, 2))), (F ([Math]::Round($cr.y, 2))), (F ([Math]::Round($cr.w, 2))), (F ([Math]::Round($cr.h, 2)))) }
    $bk = ""
    if ($seg.type -eq "highlight") {
        $b0 = @($seg.box)[0]
        $bk = ("|박스 {0},{1},{2},{3}" -f (F ([Math]::Round([double]$b0.x, 2))), (F ([Math]::Round([double]$b0.y, 2))), (F ([Math]::Round([double]$b0.w, 2))), (F ([Math]::Round([double]$b0.h, 2))))
    }
    return ("{0}|{1}{2}" -f (Split-Path -Leaf $seg.abs), $ck, $bk)
}

# 같은 화면 판정에 쓰는 사진 속 영역(0-1 분수): 일반 조각은 crop(없으면 전체), highlight는 box가 가리키는 곳.
# 같은 사진에서 영역이 절반 넘게 겹치면(교집합/합집합 0.5 이상) 칸 몇 개만 옮긴 같은 화면으로 본다.
function Get-SeenRect($seg, [int]$n) {
    $cr = Get-Crop $seg $n
    $r = @{ x = 0.0; y = 0.0; w = 1.0; h = 1.0 }
    if ($cr) { $r = @{ x = $cr.x; y = $cr.y; w = $cr.w; h = $cr.h } }
    if ($seg.type -eq "highlight") {
        $b = @($seg.box)[0]
        $r = @{ x = $r.x + [double]$b.x * $r.w; y = $r.y + [double]$b.y * $r.h; w = [double]$b.w * $r.w; h = [double]$b.h * $r.h }
    }
    return $r
}
function Rect-Iou($a, $b) {
    $ix = [Math]::Max([double]0, [Math]::Min([double]($a.x + $a.w), [double]($b.x + $b.w)) - [Math]::Max([double]$a.x, [double]$b.x))
    $iy = [Math]::Max([double]0, [Math]::Min([double]($a.y + $a.h), [double]($b.y + $b.h)) - [Math]::Max([double]$a.y, [double]$b.y))
    $inter = $ix * $iy
    $union = $a.w * $a.h + $b.w * $b.h - $inter
    if ($union -le 0) { return 0 }
    return $inter / $union
}

# 렌더 전 spec 점검: 위반이면 이유를 한국어로 알리고 멈춘다. 건너뛰는 옵션은 없다.
function Test-Spec($spec, $segs) {
    $problems = @()
    $narr = ((Get-Opt (Get-Opt $spec "audio" ([pscustomobject]@{})) "mode" "original") -eq "narration")
    $keys = @(); $counts = @{}; $rects = @{}
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $seg = $segs[$i]; $n = $i + 1; $type = [string]$seg.type
        if (@("video", "image", "highlight", "text_card") -notcontains $type) { $problems += "조각 ${n}번: 알 수 없는 type '$type' (video, image, highlight, text_card 중 하나)"; $keys += $null; continue }
        if ($type -eq "video") { $keys += $null; continue }
        if ($null -eq (Get-Opt $seg "duration" $null)) { $problems += "조각 ${n}번: duration(초)이 없습니다"; $keys += $null; continue }
        if ($type -ne "image" -and [double](Get-Opt $seg "push_in" 0) -ne 0) { $problems += "조각 ${n}번: $type 조각은 확대 움직임(push_in)을 쓸 수 없습니다. 정지만 됩니다 (박스는 0.3초 뒤 페이드 인)" }
        $key = $null
        try {
            if ($type -eq "text_card") {
                foreach ($bad in @("src", "crop", "fit")) { if ($null -ne (Get-Opt $seg $bad $null)) { throw "조각 ${n}번: text_card에는 $bad 를 쓸 수 없습니다 (lines와 highlight만)." } }
                $lay = Get-CardLayout $seg $n
                $script:CardLayouts[$i] = $lay; $script:SegBoxes[$i] = @($lay.boxes)
            } else {
                $g = Get-Geom $seg $n
                if ($g.fitw) {
                    $barX = ($VIDEO_W - $g.sw) / $VIDEO_W; $barY = ($VIDEO_H - $g.sh) / $VIDEO_H
                    $bar = [Math]::Max($barX, $barY)
                    if ($bar -gt $MAX_BAR) { throw ("조각 ${n}번: fit 때문에 검은 띠가 영역의 {0}%입니다 (한도 15%). 영역 비율(1.43:1)에 가깝게 crop하거나 fit을 지워 영역을 채워 주세요." -f [Math]::Round($bar * 100)) }
                }
                if ($type -eq "highlight") {
                    $script:SegBoxes[$i] = Get-Boxes $seg $n $g
                    # 자막 영역(영상 영역 아래쪽 25%)과 박스가 겹치면 멈춘다 (자막이 있고 below 가 아닐 때, fit 없는 조각)
                    if (@(Get-Opt $spec "captions" @()).Count -gt 0 -and [string](Get-Opt $spec "subtitle_position" "inside") -ne "below" -and -not $g.fitw) {
                        $bb = @($seg.box)[0]
                        if (([double]$bb.y + [double]$bb.h) -gt (1 - $CAPTION_ZONE_FRAC) + 0.003) { throw ("조각 ${n}번: 박스가 자막 영역(영상 영역 아래쪽 25%)과 겹칩니다. 문장을 위로 올리세요: crop을 아래로 옮기거나(기사 캡처는 crop 을 지우고 auto 로 두면 문장이 위쪽 70%에 놓입니다), box를 영역 위쪽 75% 안에 두세요.") }
                    }
                    # 박스가 사진에서 사실상 빈 곳(글자나 그림이 없는 곳)을 가리키면 멈춘다
                    $sr = Get-SeenRect $seg $n
                    $rng = Get-RegionRange $seg.abs $sr (Get-ImageSize $seg.abs)
                    if ($null -ne $rng -and $rng -lt 18) { throw ("조각 ${n}번: box가 사진에서 거의 빈 곳(글자나 그림이 없음)을 가리킵니다. 사진을 보고 글자나 그림이 있는 곳으로 box를 옮기거나, 기사 캡처라면 sentence 로 문장을 지정하세요.") }
                }
            }
            $key = Region-Key $seg $n $null
            if ($type -eq "image") { $problems += @(Test-PicPiece $seg $n) }
            if ($type -ne "text_card") { $rects[$i] = @{ file = (Split-Path -Leaf $seg.abs); type = $type; rect = (Get-SeenRect $seg $n) } }
        } catch { $problems += $_.Exception.Message }
        $keys += $key
        if ($key) { if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 } }
        if ($narr -and [double]$seg.duration -gt $MAX_PIECE_SEC) { $problems += ("조각 {0}번: 한 화면이 {1}초입니다 (4초 넘는 줄은 서로 다른 화면 2개로 나눠야 합니다)." -f $n, ([Math]::Round([double]$seg.duration, 2))) }
    }
    function Same-Screen([int]$a, [int]$b) {
        if (-not $keys[$a] -or -not $keys[$b]) { return $false }
        # 같은 문장 번호는 같은 화면이다. 단, 한 문장을 줄 범위가 서로 겹치지 않게 나눈 경우(4초 넘는 줄 분할)만 다른 화면으로 본다.
        $sa = Get-Opt $segs[$a] "sentence" $null; $sb = Get-Opt $segs[$b] "sentence" $null
        if ($segs[$a].type -eq "highlight" -and $segs[$b].type -eq "highlight" -and $null -ne $sa -and $null -ne $sb -and @($sa).Count -eq 1 -and @($sb).Count -eq 1 -and [string]$sa -eq [string]$sb -and $segs[$a].abs -eq $segs[$b].abs) {
            $la = @(Get-Opt $segs[$a] "lines" @()); $lb = @(Get-Opt $segs[$b] "lines" @())
            if ($la.Count -eq 2 -and $lb.Count -eq 2 -and ([int]$la[1] -lt [int]$lb[0] -or [int]$lb[1] -lt [int]$la[0])) { return $false }
            return $true
        }
        if ($keys[$a] -eq $keys[$b]) { return $true }
        if ($rects.ContainsKey($a) -and $rects.ContainsKey($b)) {
            $ra = $rects[$a]; $rb = $rects[$b]
            if ($ra.file -eq $rb.file -and $ra.type -eq $rb.type -and (Rect-Iou $ra.rect $rb.rect) -ge 0.5) { return $true }
        }
        return $false
    }
    for ($i = 1; $i -lt $keys.Count; $i++) {
        if (Same-Screen $i ($i - 1)) { $problems += "조각 $i 번과 $($i + 1)번이 같은 화면이거나 절반 넘게 겹치는 영역입니다 ($($keys[$i])). 연속으로 같은 영역을 쓸 수 없습니다. 겹치지 않는 다른 영역, 다른 box, 다른 카드로 바꿔 주세요." }
    }
    $reported = @{}
    for ($i = 0; $i -lt $keys.Count; $i++) {
        if (-not $keys[$i] -or $reported.ContainsKey($i)) { continue }
        $grp = @(); for ($j = 0; $j -lt $keys.Count; $j++) { if (Same-Screen $i $j) { $grp += $j } }
        if ($grp.Count -ge 3) {
            foreach ($j in $grp) { $reported[$j] = $true }
            $problems += "같은 화면(또는 절반 넘게 겹치는 영역, 조각 $(($grp | ForEach-Object { $_ + 1 }) -join ', '))이 $($grp.Count)번 나옵니다. 한 영상에서 같은 화면은 2번까지입니다. 겹치지 않는 다른 영역(crop), 다른 box 위치, 다른 text_card로 바꿔 주세요."
        }
    }
    # 기사에 이미지가 있으면 본문 highlight 조각이 4개 이상 연속하지 않게 이미지 조각(포스터, 포스터 일부, 기사 사진)을 끼운다
    $pageSeg = @($segs | Where-Object { $_.type -ne "text_card" -and $_.abs -and (Split-Path -Leaf $_.abs) -eq "page.png" })
    if ($pageSeg.Count -gt 0) {
        $dirP = Split-Path -Parent $pageSeg[0].abs
        $hasImg = (@(Get-ChildItem -LiteralPath $dirP -Filter "img-*" -ErrorAction SilentlyContinue).Count -gt 0)
        $bjp = Join-Path $dirP "page-boxes.json"
        if (-not $hasImg -and (Test-Path -LiteralPath $bjp)) { try { $hasImg = (@((Get-Content -LiteralPath $bjp -Raw -Encoding UTF8 | ConvertFrom-Json).images).Count -gt 0) } catch { } }
        if ($hasImg) {
            $run = 0; $runStart = 0
            for ($i = 0; $i -le $segs.Count; $i++) {
                $isBody = $false
                if ($i -lt $segs.Count) {
                    $sg = $segs[$i]
                    $isBody = ($sg.type -eq "text_card") -or ($sg.type -eq "highlight" -and $sg.abs -and (Split-Path -Leaf $sg.abs) -eq "page.png" -and ($null -ne (Get-Opt $sg "sentence" $null) -or [string](Get-Opt $sg "quote" "")))
                }
                if ($isBody) { if ($run -eq 0) { $runStart = $i }; $run++ }
                else {
                    if ($run -gt $SPOT_MAX_RUN) { $problems += "조각 $($runStart + 1)번부터 $($i)번까지 본문 문장 highlight가 $run 개 연속입니다. 기사에 이미지가 있으므로 본문 조각은 연속 $SPOT_MAX_RUN 개까지이고, 그 사이에 이미지 조각(포스터 전체, 포스터의 다른 부분 crop, 기사 사진)을 넣어 주세요." }
                    $run = 0
                }
            }
        }
    }
    if ($problems.Count -gt 0) { Fail ("spec 규칙 점검에서 멈췄습니다. 아래를 고친 뒤 다시 실행해 주세요.`n  " + ($problems -join "`n  ")) }
}

# 만든 영상의 통합 음량을 잰다 (loudnorm 측정 모드)
function Measure-Lufs([string]$file) {
    $r = Invoke-Tool $script:FFMPEG_EXE @("-hide_banner", "-nostats", "-i", $file, "-vn", "-af", "loudnorm=I=-19:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-") $null
    if ($r.Err -match '\{[^{}]*"input_i"[^{}]*\}') {
        $mm = $Matches[0] | ConvertFrom-Json; $val = 0.0
        if ([double]::TryParse([string]$mm.input_i, [Globalization.NumberStyles]::Float, $inv, [ref]$val)) { return $val }
    }
    return $null
}

function Video-Filters($spec, $segs, $idx, [double]$total) {
    $parts = @(); $labels = @()
    for ($i = 0; $i -lt $segs.Count; $i++) {
        $seg = $segs[$i]; $v = $idx.seg_v[$i]
        if ($seg.type -eq "video") {
            [void](Get-Crop $seg ($i + 1))   # video 조각의 crop은 지원하지 않으므로 여기서 한국어 오류로 멈춘다
            if ((Get-Opt $seg "fit" "") -eq "width") {
                $fit = "scale=${VIDEO_W}:${VIDEO_H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${VIDEO_W}:${VIDEO_H}:(ow-iw)/2:(oh-ih)/2:black"
            } else {
                $fit = "scale=${VIDEO_W}:${VIDEO_H}:force_original_aspect_ratio=increase:flags=lanczos,crop=${VIDEO_W}:${VIDEO_H}"
            }
            $parts += "[${v}:v]fps=$FPS,$fit,setsar=1,format=yuv420p,setpts=PTS-STARTPTS,settb=AVTB[v$i]"
        } else {
            $dur = Seg-Duration $seg
            $frames = [Math]::Max(1, [Math]::Round($dur * 30000 / 1001))
            # push_in 기본값은 0(정지). 명시한 조각만 천천히 확대한다.
            $push = [double](Get-Opt $seg "push_in" 0)
            # zoompan은 x, y를 정수 픽셀로 반올림하므로 확대할 때는 사진을 6배로 키워 둔 뒤 자른다(반올림 오차가 출력에서 1/6픽셀 이하로 줄어 떨림이 사라진다).
            # 정지(push_in 0)는 키울 필요가 없어 영상 영역 크기 그대로 쓴다.
            $mul = 1; if ($push -gt 0) { $mul = 6 }
            $w2 = $VIDEO_W * $mul; $h2 = $VIDEO_H * $mul
            # crop(선택): 사진에서 잘라 쓸 영역(분수). 없으면 사진 전체.
            $pre = ""
            $cr = Get-Crop $seg ($i + 1)
            if ($cr) { $pre = "crop=iw*$(F $cr.w):ih*$(F $cr.h):iw*$(F $cr.x):ih*$(F $cr.y)," }
            # fit(선택): "width"면 잘라낸 영역(또는 사진 전체)이 통째로 보이게 맞추고 남는 곳은 검게 둔다. 없으면 영상 영역을 가득 채운다(가장자리가 잘린다).
            if ((Get-Opt $seg "fit" "") -eq "width") {
                $fit2 = "scale=${w2}:${h2}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${w2}:${h2}:(ow-iw)/2:(oh-ih)/2:black"
            } else {
                $fit2 = "scale=${w2}:${h2}:force_original_aspect_ratio=increase:flags=lanczos,crop=${w2}:${h2}"
            }
            $core = "[${v}:v]${pre}${fit2},zoompan=z='1+$(F $push)*on/${frames}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=${VIDEO_W}x${VIDEO_H}:fps=$FPS,setsar=1,format=yuv420p"
            $bx = @()
            if ($script:SegBoxes.ContainsKey($i)) { $bx = @($script:SegBoxes[$i]) }
            if ($bx.Count -eq 0) {
                $parts += "${core},setpts=PTS-STARTPTS,settb=AVTB[v$i]"
            } else {
                # highlight: 박스 바깥을 검정 반투명으로 어둡게 하고 박스 안은 그대로 둔 뒤, 빨간 테두리를 그린다. 이 겹침 층을 0.3초 뒤부터 0.3초 동안 페이드 인한다.
                $nb = $bx.Count
                $outs = "[hb$i][hc$i]"
                for ($j = 0; $j -lt $nb; $j++) { $outs += "[hk${i}_$j]" }
                $parts += "${core},split=$(2 + $nb)$outs"
                $prev = "hc$i"
                $parts += "[hc$i]drawbox=x=0:y=0:w=${VIDEO_W}:h=${VIDEO_H}:color=black@${HL_DIM}:t=fill[hd${i}_0]"
                for ($j = 0; $j -lt $nb; $j++) {
                    $b = $bx[$j]
                    $parts += "[hk${i}_$j]crop=$($b.w):$($b.h):$($b.x):$($b.y)[hq${i}_$j]"
                    $parts += "[hd${i}_$j][hq${i}_$j]overlay=$($b.x):$($b.y)[hd${i}_$($j + 1)]"
                }
                $ol = @()
                foreach ($b in $bx) {
                    $ox0 = [Math]::Max(0, $b.x - $HL_T); $oy0 = [Math]::Max(0, $b.y - $HL_T)
                    $ox1 = [Math]::Min($VIDEO_W, $b.x + $b.w + $HL_T); $oy1 = [Math]::Min($VIDEO_H, $b.y + $b.h + $HL_T)
                    $ol += "drawbox=x=${ox0}:y=${oy0}:w=$($ox1 - $ox0):h=$($oy1 - $oy0):color=${HL_RED}@1:t=${HL_T}"
                }
                $parts += "[hd${i}_${nb}]" + ($ol -join ",") + ",format=rgba,fade=t=in:st=$(F $HL_AT):d=$(F $HL_FADE):alpha=1[hf$i]"
                $parts += "[hb$i][hf$i]overlay=0:0:format=auto,format=yuv420p,setpts=PTS-STARTPTS,settb=AVTB[v$i]"
            }
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
    # 자막: 기본은 영상 화면 안 아래쪽(흰 글자 + 검은 외곽선). subtitle_position 으로 바꾼다.
    $subPos = [string](Get-Opt $spec "subtitle_position" "inside")
    if (@("inside", "bar", "below") -notcontains $subPos) { Fail "subtitle_position 은 inside(기본), bar, below 중 하나여야 합니다: $subPos" }
    $caps = @(Get-Opt $spec "captions" @())
    if ($caps.Count -gt 0) {
        $capDraws = @()
        $baseline = $CAPTION_BASELINE; $baseSize = $CAPTION_SIZE
        if ($subPos -eq "below") { $baseline = $CAPTION_BELOW_BASELINE; $baseSize = $CAPTION_BELOW_SIZE }
        foreach ($cap in $caps) {
            $size = $baseSize
            $cw = Get-LineWidth $cap.text $size 0
            if ($cw -gt 1000) { $size = [Math]::Floor($baseSize * 1000 / $cw) }
            $en = "enable='between(t,$(F ([double]$cap.start)),$(F ([double]$cap.end)))'"
            if ($subPos -eq "bar") {
                $capDraws += "drawbox=x=0:y=$($VIDEO_Y + $VIDEO_H - $CAPTION_BAR_H):w=${VIDEO_W}:h=${CAPTION_BAR_H}:color=black@${CAPTION_BAR_ALPHA}:t=fill:$en"
            }
            $capDraws += (DT $cap.text $size "FFFFFF" "(w-text_w)/2" $baseline "borderw=${CAPTION_BORDER}:bordercolor=0x000000:$en")
        }
        $parts += "[$last]" + ($capDraws -join ",") + "[a5]"
        $last = "a5"
    }
    $parts += "[$last]format=yuv420p[vout]"
    return $parts
}

# ---- 필터 그래프: 소리 --------------------------------------------------------------------
function Audio-Filters($segs, $audio, $sfx, $idx, [double]$total, [string]$loudnorm, $bgmGain = $null) {
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
    # BGM(선택): 말소리(나레이션과 원본 소리를 섞은 것)보다 bgm_db(기본 -20) dB 낮게, 시작은 페이드 인, 끝은 페이드 아웃으로 깐다.
    $mixLabel = "[mix]"
    if ($null -ne $bgmGain) {
        $fi = [Math]::Min([double](Get-Opt $audio "bgm_fade_in" 1), $total / 2)
        $fo = [Math]::Min([double](Get-Opt $audio "bgm_fade_out" 2), $total / 2)
        $bc = "[$($idx.bgm):a]aresample=48000,aformat=channel_layouts=stereo,atrim=0:$(F $total),asetpts=PTS-STARTPTS,volume=$(F $bgmGain)dB"
        if ($fi -gt 0) { $bc += ",afade=t=in:st=0:d=$(F $fi)" }
        if ($fo -gt 0) { $bc += ",afade=t=out:st=$(F ($total - $fo)):d=$(F $fo)" }
        $parts += ($bc + "[bgmx]")
        $parts += "[mix][bgmx]amix=inputs=2:duration=first:normalize=0,atrim=0:$(F $total)[mixb]"
        $mixLabel = "[mixb]"
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
        $parts += $mixLabel + ($fxLabels -join "") + "amix=inputs=$($fxLabels.Count + 1):duration=first:normalize=0,atrim=0:$(F $total)[mix2]"
        $parts += "[mix2]$loudnorm,aresample=48000[aout]"
    } else {
        $parts += "$mixLabel$loudnorm,aresample=48000[aout]"
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
if (-not $NoLogo -and -not $script:LOGO -and $Check) {
    # -Check 는 영상을 만들지 않고 검사만 하므로 로고 파일이 없어도 멈추지 않는다.
    Say "로고가 없어 이 검사에서는 건너뜁니다."
}
elseif (-not $NoLogo -and -not $script:LOGO) {
    Fail ("KAIST 로고 파일이 없습니다. 공식 로고는 이 프로젝트에 들어 있지 않습니다.`n" +
        "1) $LOGO_PAGE 에서 'KAIST 로고'를 내려받아(고해상도 파일은 KAIST 포털 로그인이 필요할 수 있습니다) 재료 폴더에 logo.png 로 저장해 주세요. 배경이 투명한 png가 가장 좋습니다.`n" +
        "2) 로고 없이 만들어도 된다고 사용자가 정했다면 -NoLogo 를 붙여 다시 실행하세요.`n" +
        "(KAIST 안내: 로고는 상업적 목적으로 쓸 수 없고, 교육 및 행정 목적에 한해 제공됩니다.)")
}
foreach ($f in @($FONT, $script:ARROW)) { if (-not (Test-Path -LiteralPath $f)) { Fail "스킬 파일이 없습니다: $f" } }
if ($script:LOGO -and -not (Test-Path -LiteralPath $script:LOGO)) { Fail "로고 파일을 찾지 못했습니다: $($script:LOGO)" }

$segs = @($spec.segments)
foreach ($seg in $segs) { if ($seg.type -ne "text_card") { Add-Member -InputObject $seg -NotePropertyName abs -NotePropertyValue (Resolve-Input $seg.src) -Force } }
Resolve-PosterCrops $segs   # crop "poster" 는 page-boxes.json 의 첫 기사 이미지 위쪽으로 바꾼다
function Warn-FirstPoster($segs) {
    if ($segs.Count -lt 1) { return }
    $seg = $segs[0]
    if (@("image", "highlight") -notcontains [string]$seg.type -or (Split-Path -Leaf $seg.abs) -ne "page.png") { return }
    $bj = Join-Path (Split-Path -Parent $seg.abs) "page-boxes.json"
    if (-not (Test-Path -LiteralPath $bj)) { return }
    $pb = Get-Content -LiteralPath $bj -Raw -Encoding UTF8 | ConvertFrom-Json
    $im = @($pb.images)
    if ($im.Count -lt 1) { return }
    $c = Get-Crop $seg 1
    $b = $im[0].box
    $ok = $false
    if ($c) {
        $ix = [Math]::Max([double]0, [Math]::Min([double]($c.x + $c.w), [double]($b.x + $b.w)) - [Math]::Max([double]$c.x, [double]$b.x))
        $iy = [Math]::Max([double]0, [Math]::Min([double]($c.y + $c.h), [double]($b.y + $b.h)) - [Math]::Max([double]$c.y, [double]$b.y))
        if ($c.w * $c.h -gt 0 -and ($ix * $iy) / ($c.w * $c.h) -ge 0.5) { $ok = $true }
    }
    if (-not $ok) { Say "경고: 첫 조각이 기사의 포스터 그림이 아닙니다. 첫 컷은 포스터 그림이 보이게 하세요: {`"type`": `"image`", `"src`": `"재료/기사-<번호>/page.png`", `"crop`": `"poster`", `"duration`": 2.7}" }
}
Resolve-Sentences $segs   # sentence/quote 로 지정한 highlight 의 crop 과 box 를 page-boxes.json 에서 채운다
Warn-FirstPoster $segs
for ($ci = 0; $ci -lt $segs.Count; $ci++) { [void](Get-Crop $segs[$ci] ($ci + 1)) }   # crop 값 오류는 무거운 작업 전에 멈춘다
# crop 영역의 실제 픽셀 가로:세로 비율이 3:1 초과 또는 1:3 미만이면 영상 영역이 검은 여백으로 비므로 멈추지 않고 경고만 한다.
for ($ci = 0; $ci -lt $segs.Count; $ci++) {
    $cr = Get-Crop $segs[$ci] ($ci + 1)
    if (-not $cr) { continue }
    $info = Invoke-Tool $script:FFMPEG_EXE @("-hide_banner", "-i", $segs[$ci].abs) $null
    $dm = [regex]::Match(($info.Err + $info.Out), 'Video:.*?[, ](\d{2,6})x(\d{2,6})')
    if (-not $dm.Success) { continue }
    $pr = ([double]$dm.Groups[1].Value * $cr.w) / ([double]$dm.Groups[2].Value * $cr.h)
    if ($pr -gt 3 -or $pr -lt (1 / 3)) {
        Say ("경고: 조각 {0}번의 crop은 실제 픽셀 비율이 {1}:1로 너무 납작하거나 길쭉해 영상 영역이 검은 여백으로 많이 빕니다. 위아래 이웃 요소를 함께 잘라 1.0:1-2.0:1에 가깝게 해 주세요." -f ($ci + 1), $pr.ToString("0.0", $inv))
    }
}

# 웹 사진(Openverse 검색으로 받은 web-NN)은 사람이 원본 페이지에서 확인해 sources.json 의 web_images 에
# human_approved "yes"와 rights_status "확인됨"으로 기록되고, 라이선스(CC0 1.0 또는 CC BY x.y)와 작성자 칸이 채워진 것만 쓴다.
# 같은 내용의 사본(이름을 바꾼 파일)이나 web-NN 파일이 이 조건을 못 채우면 여기서 멈춘다.
function Web-Entry-Problem($en) {
    $lic = ([string](Get-Opt $en "license" "")).Trim()
    if (-not $lic) { return "라이선스 칸이 비어 있음" }
    if ($lic -notmatch '^(CC0 1\.0|CC BY \d\.\d)$') { return "허용하지 않는 라이선스($lic)" }
    if (-not ([string](Get-Opt $en "creator" "")).Trim()) { return "작성자 칸이 비어 있음" }
    if (([string](Get-Opt $en "rights_status" "")) -ne "확인됨" -or ([string](Get-Opt $en "human_approved" "")).Trim().ToLower() -ne "yes") { return "사람 확인(승인) 전" }
    return $null
}
$usedWeb = @()
$noReason = @()
$blockedPhotos = @()
$byHash = @{}
$matsRoot = Join-Path $projectRoot "재료"
if (Test-Path -LiteralPath $matsRoot) {
    foreach ($sf in @(Get-ChildItem -LiteralPath $matsRoot -Recurse -Filter "sources.json" -ErrorAction SilentlyContinue)) {
        try { $sj = Get-Content -LiteralPath $sf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $sj.PSObject.Properties["web_images"] -or -not $sj.web_images) { continue }
        foreach ($en in @($sj.web_images)) {
            $okRights = ($null -eq (Web-Entry-Problem $en))
            $shaVal = [string](Get-Opt $en "sha256" "")
            if ($shaVal -and (-not $okRights -or -not $byHash.ContainsKey($shaVal))) { $byHash[$shaVal] = $okRights }
        }
    }
}
foreach ($seg in $segs) {
    if (-not (Is-Pic $seg)) { continue }
    $why = $null
    $fileHash = (Get-FileHash -LiteralPath $seg.abs -Algorithm SHA256).Hash.ToLower()
    if ($byHash.ContainsKey($fileHash) -and -not $byHash[$fileHash]) { $why = "사람 확인(승인) 전이거나 라이선스, 작성자 기록이 모자람" }
    if ((Split-Path -Leaf $seg.abs) -match '^web-\d+\.(jpg|jpeg|png|gif|webp)$') {
        $why = $null
        $sjPath = Join-Path (Split-Path -Parent $seg.abs) "sources.json"
        $found = $false
        if (Test-Path -LiteralPath $sjPath) {
            try { $sj2 = Get-Content -LiteralPath $sjPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $sj2 = $null }
            if ($sj2 -and $sj2.PSObject.Properties["web_images"]) {
                foreach ($en in @($sj2.web_images)) {
                    if (([string]$en.file) -eq (Split-Path -Leaf $seg.abs)) { $found = $true; $why = Web-Entry-Problem $en; if (-not $why) { $usedWeb += $en; if (-not ([string](Get-Opt $en "used_for" "")).Trim()) { $noReason += ("{0} ({1})" -f $seg.src, ([string]$en.title)) } } }
                }
            }
        }
        if (-not $found) { $why = "출처 기록 없음" }
    }
    if ($why) { $blockedPhotos += ("{0} ({1})" -f $seg.src, $why) }
}
if ($blockedPhotos.Count -gt 0) {
    Fail ("쓸 권리가 확인되지 않은 웹 사진이 들어 있어 영상을 만들지 않습니다.`n  " + ($blockedPhotos -join "`n  ") + "`n각 사진의 원본 페이지(sources.json 의 source_page)를 열어 라이선스, 만든 사람, 사진 속 얼굴(초상권), 로고나 캐릭터 포함 여부를 확인한 뒤, 확인했다고 말해 주세요. 확인하지 않은 사진은 spec.json에서 빼야 합니다.")
}
if ($noReason.Count -gt 0) {
    Fail ("이 사진을 왜 쓰는지 적어야 합니다. sources.json 의 해당 사진에 used_for 칸을 채워 주세요 (어느 줄의 어떤 내용 때문에 쓰는지 한 줄). 주제와 직접 관련 없는 채움 사진은 쓰지 않습니다.`n  " + ($noReason -join "`n  "))
}
$audio = Get-Opt $spec "audio" ([pscustomobject]@{ mode = "original" })
if ((Get-Opt $audio "mode" "original") -eq "narration") { Add-Member -InputObject $audio -NotePropertyName abs -NotePropertyValue (Resolve-Input $audio.file) -Force }
# BGM(선택): audio.bgm 은 사람이 재료/ 에 넣은 곡 파일이다. 곡과 같은 폴더의 sources.json 의 bgm 항목에
# 곡 이름, 만든 사람, URL, 라이선스, 받은 날이 적혀 있고 human_approved 가 "yes"(사람이 쓸 권리를 확인하고 승인함)일 때만 쓴다.
$bgmPath = [string](Get-Opt $audio "bgm" "")
if ($bgmPath) {
    Add-Member -InputObject $audio -NotePropertyName bgm_abs -NotePropertyValue (Resolve-Input $bgmPath) -Force
    $bgmLeaf = Split-Path -Leaf $audio.bgm_abs
    $bgmSj = Join-Path (Split-Path -Parent $audio.bgm_abs) "sources.json"
    $bgmWhy = $null; $bgmEntry = $null
    if (Test-Path -LiteralPath $bgmSj) {
        try { $sjB = Get-Content -LiteralPath $bgmSj -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $sjB = $null }
        if ($sjB -and $sjB.PSObject.Properties["bgm"]) {
            foreach ($en in @($sjB.bgm)) { if (([string](Get-Opt $en "file" "")) -eq $bgmLeaf) { $bgmEntry = $en } }
        }
    }
    if (-not $bgmEntry) { $bgmWhy = "곡 정보가 sources.json 의 bgm 항목에 없습니다" }
    else {
        $empty = @()
        foreach ($k in @(@("title", "곡 이름"), @("creator", "만든 사람"), @("url", "URL"), @("license", "라이선스 이름"), @("downloaded", "받은 날"))) {
            if (-not ([string](Get-Opt $bgmEntry $k[0] "")).Trim()) { $empty += $k[1] }
        }
        if ($empty.Count -gt 0) { $bgmWhy = ($empty -join ", ") + " 칸이 비어 있습니다" }
        elseif (([string](Get-Opt $bgmEntry "human_approved" "")).Trim().ToLower() -ne "yes") { $bgmWhy = "사람이 승인하지 않았습니다(human_approved 가 yes 가 아님)" }
    }
    if ($bgmWhy) {
        Fail ("BGM 곡의 출처 기록과 승인이 끝나지 않아 영상을 만들지 않습니다.`n  {0}: {1}`n곡 이름, 만든 사람, URL, 라이선스 이름, 받은 날을 {2} 의 bgm 항목에 적고, 사람이 쓸 권리를 직접 확인한 뒤 human_approved 를 yes 로 바꿔야 합니다. 승인은 사람만 할 수 있습니다." -f $bgmLeaf, $bgmWhy, $bgmSj)
    }
}
$sfx = @(Get-Opt $spec "sfx" @())
foreach ($fx in $sfx) { Add-Member -InputObject $fx -NotePropertyName abs -NotePropertyValue (Resolve-Input $fx.file) -Force }
# 효과음 출처 기록과 승인 점검: 효과음 파일과 같은 폴더의 sources.json 의 sfx 항목에 곡 정보가 있고 human_approved 가 "yes" 여야 쓴다.
# (효과음은 openverse.ps1 -SearchSfx/-DownloadSfx 로만 받는다. 이 점검을 건너뛰는 옵션은 없다.)
$sfxEntries = @{}
$sfxWhy = @()
foreach ($fx in $sfx) {
    $leafX = Split-Path -Leaf $fx.abs
    $sjX = Join-Path (Split-Path -Parent $fx.abs) "sources.json"
    $enX = $null
    if (Test-Path -LiteralPath $sjX) {
        try { $sjXo = Get-Content -LiteralPath $sjX -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $sjXo = $null }
        if ($sjXo -and $sjXo.PSObject.Properties["sfx"]) { foreach ($e1 in @($sjXo.sfx)) { if (([string](Get-Opt $e1 "file" "")) -eq $leafX) { $enX = $e1 } } }
    }
    if (-not $enX) { $sfxWhy += "${leafX}: 출처 기록이 sources.json 의 sfx 항목에 없습니다"; continue }
    $emptyX = @()
    foreach ($k in @(@("title", "소리 이름"), @("creator", "만든 사람"), @("license", "라이선스"), @("foreign_landing_url", "원본 페이지"), @("downloaded", "받은 날"))) {
        if (-not ([string](Get-Opt $enX $k[0] "")).Trim()) { $emptyX += $k[1] }
    }
    if ($emptyX.Count -gt 0) { $sfxWhy += "${leafX}: " + ($emptyX -join ", ") + " 칸이 비어 있습니다"; continue }
    if (([string](Get-Opt $enX "human_approved" "")).Trim().ToLower() -ne "yes") { $sfxWhy += "${leafX}: 사람이 승인하지 않았습니다(human_approved 가 yes 가 아님)"; continue }
    $licX = ([string]$enX.license).Trim()
    if ($licX -notmatch '^CC0( 1\.0)?$' -and $licX -notmatch '^CC BY (1\.0|2\.0|2\.5|3\.0|4\.0)$' -and $licX -notmatch '^(ElevenLabs|YouTube)') { $sfxWhy += "${leafX}: 허용하지 않는 라이선스입니다($licX). CC0, CC BY만 쓸 수 있습니다"; continue }
    $sfxEntries[$leafX] = $enX
}
if ($sfxWhy.Count -gt 0) {
    Fail ("효과음의 출처 기록과 승인이 끝나지 않아 영상을 만들지 않습니다.`n  " + ($sfxWhy -join "`n  ") + "`n효과음은 openverse.ps1 -SearchSfx 로 찾아 -DownloadSfx 로 받고, 사람이 원본 페이지에서 권리를 확인한 뒤 human_approved 를 yes 로 바꿔야 합니다. 승인은 사람만 할 수 있습니다.")
}

# 구간별 출력 시작 시각과 전체 길이
$starts = @(); $t = 0.0
for ($i = 0; $i -lt $segs.Count; $i++) {
    $tr = Transition-Of $segs[$i]
    $overlap = 0.0
    if ($i -gt 0) { $overlap = [double]$tr[1] }
    if ($i -gt 0 -and $tr[0] -ne "cut" -and $XFADE_NAMES -notcontains [string]$tr[0]) {
        Fail ("조각 $($i + 1)번: 알 수 없는 전환 이름 '$($tr[0])' 입니다. 쓸 수 있는 이름: fade, slideleft, slideright, smoothleft, smoothup, wipeleft, wiperight, circleopen, zoomin, dissolve, fadeblack 등 (전체 목록은 SKILL.md). 전환이 없으면 transition 을 지우거나 cut 으로 두세요.")
    }
    if ($i -gt 0 -and $tr[0] -ne "cut" -and ([double]$tr[1] -lt 0.1 -or [double]$tr[1] -gt 1.0)) {
        Fail "조각 $($i + 1)번: transition_duration 은 0.1초에서 1초 사이로 정해 주세요 (권장 0.3-0.5초, 지금 값 $($tr[1])초)."
    }
    if ($overlap -gt 0 -and ($overlap -ge (Seg-Duration $segs[$i]) -or $overlap -ge (Seg-Duration $segs[$i - 1]))) {
        Fail "구간 $i 의 transition_duration ${overlap}초가 구간 길이보다 깁니다."
    }
    if ($i -gt 0) { $t -= $overlap } else { $t = 0.0 }
    $starts += $t
    $t += Seg-Duration $segs[$i]
}
$total = $t
# 효과음 밀도 점검: 효과음이 너무 많으면 말소리가 묻히고 시끄럽다. 4초에 1개 넘게, 또는 0.5초 안에 두 소리가 겹치게 넣으면 멈춘다.
if ($sfx.Count -gt 0) {
    $maxSfx = [Math]::Max(1, [int][Math]::Floor($total / 4.0))
    $sfxProb = @()
    if ($sfx.Count -gt $maxSfx) { $sfxProb += "효과음이 $($sfx.Count)개입니다. 이 영상(${total}초)에는 최대 ${maxSfx}개(4초에 1개)까지만 넣을 수 있습니다. 모든 조각이나 모든 전환에 넣지 말고, 눈에 띄는 지점(첫 포스터가 나올 때, 하이라이트 박스가 처음 나올 때, 날짜 조각 등) 몇 곳에만 넣으세요." }
    $ats = @($sfx | ForEach-Object { [double]$_.at } | Sort-Object)
    for ($k = 1; $k -lt $ats.Count; $k++) { if (($ats[$k] - $ats[$k - 1]) -lt 0.5) { $sfxProb += ("효과음 두 개가 {0:0.0}초와 {1:0.0}초에 거의 동시에 들어갑니다. 한 지점에는 소리 하나만 쓰세요." -f $ats[$k - 1], $ats[$k]); break } }
    if ($sfxProb.Count -gt 0) { Fail ("효과음 점검에서 멈췄습니다.`n  " + ($sfxProb -join "`n  ")) }
}
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
Test-Spec $spec $segs
$stampPath = Join-Path (Split-Path -Parent $out) "render-stamp.json"
$specSha = (Get-FileHash -LiteralPath $specPath -Algorithm SHA256).Hash.ToLower()
if ($Check) {
    # 최종 영상 점검: render.ps1이 만든 것인지(도장 파일), spec의 output과 같은 파일인지, 음량이 정규화됐는지
    $cp = @()
    if (-not (Test-Path -LiteralPath $out)) { $cp += "spec의 output 파일이 없습니다: $out" }
    elseif (-not (Test-Path -LiteralPath $stampPath)) { $cp += "render.ps1이 만든 기록(render-stamp.json)이 없습니다. 최종 영상은 render.ps1로만 만들어야 합니다. 직접 ffmpeg로 만든 파일은 쓰지 않습니다." }
    else {
        $st = Get-Content -LiteralPath $stampPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (([string]$st.output) -ne (Split-Path -Leaf $out)) { $cp += "기록의 파일 이름($($st.output))과 spec의 output($((Split-Path -Leaf $out)))이 다릅니다." }
        if (([string]$st.file_sha256) -ne (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLower()) { $cp += "영상 파일이 render.ps1이 만든 뒤에 바뀌었습니다. render.ps1로 다시 만들어 주세요." }
        if (([string]$st.spec_sha256) -ne $specSha) { $cp += "spec.json이 마지막 렌더 뒤에 바뀌었습니다. render.ps1로 다시 만들어 주세요." }
        $lu = Measure-Lufs $out
        if ($null -eq $lu) { $cp += "영상의 음량을 읽지 못했습니다." }
        elseif ([Math]::Abs($lu - $target) -gt 1.5) { $cp += ("영상 음량이 {0:0.0} LUFS라 목표({1})에서 1.5 넘게 벗어납니다. 음량 정규화가 적용되지 않았습니다." -f $lu, $target) }
    }
    if ($cp.Count -gt 0) { Fail ("최종 영상 점검에서 멈췄습니다.`n  " + ($cp -join "`n  ")) }
    Say "최종 영상 점검 통과: $out"
    return
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $out) | Out-Null
Remove-Item -LiteralPath $stampPath -Force -ErrorAction SilentlyContinue

$script:TMP = Join-Path ([IO.Path]::GetTempPath()) ("kaist-shorts-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $script:TMP | Out-Null
try {
    Copy-Item -LiteralPath $FONT -Destination (Join-Path $script:TMP "font.otf")
    # text_card는 흰 바탕 카드 그림(1080x756)으로 먼저 그려 두고 사진 조각처럼 쓴다.
    for ($ci = 0; $ci -lt $segs.Count; $ci++) {
        if ($segs[$ci].type -ne "text_card") { continue }
        $lay = $script:CardLayouts[$ci]
        $dts = @()
        foreach ($vl in $lay.vis) { $dts += (DT $vl.text $CARD_SIZE "111111" (F $CARD_PAD_X) ($vl.y + 48) "") }
        $cardName = "card-{0}.png" -f ($ci + 1)
        [void](Run-FFmpeg @("-hide_banner", "-nostats", "-y", "-f", "lavfi", "-i", "color=c=white:s=${VIDEO_W}x${VIDEO_H}:d=1", "-vf", ($dts -join ","), "-frames:v", "1", $cardName) $script:TMP "글자 카드 그리기")
        Add-Member -InputObject $segs[$ci] -NotePropertyName abs -NotePropertyValue (Join-Path $script:TMP $cardName) -Force
    }

    $ln1 = "loudnorm=I=$(F $target):TP=$(F $peak):LRA=11:print_format=json"
    # BGM이 있으면 먼저 BGM 없는 소리(말소리)의 음량과 곡의 음량을 재서, 곡이 말소리보다 bgm_db(기본 -20) dB 낮아지는 증폭량을 구한다.
    $bgmGain = $null
    if ($bgmPath) {
        $b0 = Build-Inputs $segs $audio $sfx $false
        $g0 = (Audio-Filters $segs $audio $sfx $b0.idx $total $ln1) -join ";`n"
        [IO.File]::WriteAllText((Join-Path $script:TMP "audio0.txt"), $g0, $utf8)
        $r0 = Run-FFmpeg (@("-hide_banner", "-nostats") + $b0.args + @($graphFlag, "audio0.txt", "-map", "[aout]", "-f", "null", "-")) $script:TMP "말소리 음량 측정"
        $speechLufs = $target
        if ($r0.Err -match '\{[^{}]*"input_i"[^{}]*\}') { $m0 = $Matches[0] | ConvertFrom-Json; $tmpS = 0.0
            if ([double]::TryParse([string]$m0.input_i, [Globalization.NumberStyles]::Float, $inv, [ref]$tmpS) -and $tmpS -gt -70) { $speechLufs = $tmpS } }
        $rb = Invoke-Tool $script:FFMPEG_EXE @("-hide_banner", "-nostats", "-i", $audio.bgm_abs, "-vn", "-af", "loudnorm=I=-23:TP=-2:LRA=11:print_format=json", "-f", "null", "-") $null
        $bgmLufs = 0.0
        if ($rb.Code -ne 0 -or $rb.Err -notmatch '\{[^{}]*"input_i"[^{}]*\}') { Fail "BGM 곡 파일에서 소리를 읽지 못했습니다: $bgmLeaf" }
        $mb = $Matches[0] | ConvertFrom-Json
        if (-not [double]::TryParse([string]$mb.input_i, [Globalization.NumberStyles]::Float, $inv, [ref]$bgmLufs) -or $bgmLufs -le -70) { Fail "BGM 곡에 들리는 소리가 없습니다: $bgmLeaf" }
        $bgmDb = [double](Get-Opt $audio "bgm_db" -20)
        $bgmGain = $speechLufs + $bgmDb - $bgmLufs
        Say ("BGM: 말소리 {0:0.0} LUFS, 곡 {1:0.0} LUFS -> 곡을 말소리보다 {2} dB 낮게(증폭 {3:0.0} dB)" -f $speechLufs, $bgmLufs, $bgmDb, $bgmGain)
    }

    # 1차: 소리만 돌려 loudnorm이 잰 값을 읽는다
    $b = Build-Inputs $segs $audio $sfx $false ([bool]$bgmPath)
    $g1 = (Audio-Filters $segs $audio $sfx $b.idx $total $ln1 $bgmGain) -join ";`n"
    [IO.File]::WriteAllText((Join-Path $script:TMP "audio1.txt"), $g1, $utf8)
    $tArgs = @(); if ($bgmPath) { $tArgs = @("-t", (F $total)) }
    $r1 = Run-FFmpeg (@("-hide_banner", "-nostats") + $b.args + @($graphFlag, "audio1.txt", "-map", "[aout]") + $tArgs + @("-f", "null", "-")) $script:TMP "소리 음량 측정"
    if ($r1.Err -notmatch '\{[^{}]*"input_i"[^{}]*\}') { Fail ("loudnorm 측정값을 읽지 못했습니다.`n" + $r1.Err) }
    $m = $Matches[0] | ConvertFrom-Json
    Say ("1차 측정: 통합 {0} LUFS, 피크 {1} dBTP -> 목표 {2} LUFS" -f $m.input_i, $m.input_tp, $target)
    $ln2 = "loudnorm=I=$(F $target):TP=$(F $peak):LRA=11:measured_I=$($m.input_i):measured_TP=$($m.input_tp):measured_LRA=$($m.input_lra):measured_thresh=$($m.input_thresh):offset=$($m.target_offset):linear=true"

    # 2차: 영상 + 소리
    $b = Build-Inputs $segs $audio $sfx $true ([bool]$bgmPath)
    $g2 = ((Video-Filters $spec $segs $b.idx $total) + (Audio-Filters $segs $audio $sfx $b.idx $total $ln2 $bgmGain)) -join ";`n"
    [IO.File]::WriteAllText((Join-Path $script:TMP "graph.txt"), $g2, $utf8)
    $encArgs = @("-map", "[vout]", "-map", "[aout]", "-t", (F $total), "-r", $FPS,
        "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-pix_fmt", "yuv420p",
        "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-movflags", "+faststart", $out)
    [void](Run-FFmpeg (@("-hide_banner", "-nostats", "-y") + $b.args + @($graphFlag, "graph.txt") + $encArgs) $script:TMP "영상 만들기")
    # 표기 문구(credits.txt): CC BY 사진이 쓰였거나 기사 캡처(page.png)가 쓰였으면 영상 설명란에 붙일 문구를 결과 폴더에 적는다
    $usedUniq = @($usedWeb | Sort-Object { [string]$_.file } -Unique)
    $ccbyUsed = @($usedUniq | Where-Object { ([string]$_.license) -like "CC BY*" })
    $capLines = @(); $capSeen = @{}
    foreach ($sg in $segs) {
        if (-not (Is-Pic $sg) -or (Split-Path -Leaf $sg.abs) -ne "page.png") { continue }
        $sjc = Join-Path (Split-Path -Parent $sg.abs) "sources.json"
        if (-not (Test-Path -LiteralPath $sjc)) { continue }
        try { $sjo2 = Get-Content -LiteralPath $sjc -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($sjo2 -and $sjo2.PSObject.Properties["page_capture"] -and -not $capSeen.ContainsKey([string]$sjo2.page_capture.url)) {
            $capSeen[[string]$sjo2.page_capture.url] = $true
            $capLines += ("기사 화면 캡처: {0}, {1}, 캡처 {2}" -f ([string]$sjo2.page_capture.source), ([string]$sjo2.page_capture.url), ([string]$sjo2.page_capture.captured_at))
        }
    }
    # 원본 영상 표기: video 조각이 collect-video.ps1 로 받은 영상이면 같은 폴더의 meta.json 에서 제목, 올린 곳, 주소, 라이선스를 적는다
    $vidLines = @(); $vidSeen = @{}
    foreach ($sg in $segs) {
        if ([string]$sg.type -ne "video") { continue }
        $mj = Join-Path (Split-Path -Parent $sg.abs) "meta.json"
        if (-not (Test-Path -LiteralPath $mj)) { continue }
        try { $mo = Get-Content -LiteralPath $mj -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $vu = [string](Get-Opt $mo "webpage_url" "")
        if (-not $vu -or $vidSeen.ContainsKey($vu)) { continue }
        $vidSeen[$vu] = $true
        $vl = '원본 영상: "{0}" - {1}, {2}' -f ([string](Get-Opt $mo "title" "")), ([string](Get-Opt $mo "channel" (Get-Opt $mo "uploader" ""))), $vu
        $vlic = ([string](Get-Opt $mo "license" "")).Trim()
        if ($vlic) { $vl += ", 라이선스: $vlic" }
        $vidLines += $vl
    }
    # BGM 표기: 곡 기록(sources.json 의 bgm)에서 곡명, 만든 사람, 출처, 라이선스를 적는다. attribution_required 가 yes 이면 필수, 아니면 "표기 선택"
    $bgmLine = $null
    if ($bgmPath -and $bgmEntry) {
        $srcName = [string](Get-Opt $bgmEntry "source" "")
        if (-not $srcName) { $srcName = [string](Get-Opt $bgmEntry "url" "") }
        $bgmLine = 'BGM: "{0}" - {1}, 출처: {2}, {3}' -f ([string]$bgmEntry.title), ([string]$bgmEntry.creator), $srcName, ([string]$bgmEntry.license)
        $attrTxt = ([string](Get-Opt $bgmEntry "attribution" "")).Trim()
        if (([string](Get-Opt $bgmEntry "attribution_required" "no")).Trim().ToLower() -eq "yes") { $bgmLine += " (표기 필수" + $(if ($attrTxt) { ": $attrTxt" } else { "" }) + ")" }
        else { $bgmLine += " (표기 선택)" }
    }
    if ($ccbyUsed.Count -gt 0 -or $capLines.Count -gt 0 -or $vidLines.Count -gt 0 -or $bgmLine -or $sfxEntries.Count -gt 0) {
        $cl = @("영상을 올릴 때 설명란에 아래 표기를 붙여 주세요.", "")
        foreach ($en in $usedUniq) {
            $line = '"{0}" by {1}, {2}, {3}' -f ([string]$en.title), ([string]$en.creator), ([string]$en.license), ([string](Get-Opt $en "source_page" ""))
            if (([string]$en.license) -like "CC0*") { $line += " (표기 선택)" }
            $cl += $line
        }
        $cl += $capLines
        $cl += $vidLines
        if ($bgmLine) { $cl += $bgmLine }
        foreach ($kx in @($sfxEntries.Keys | Sort-Object)) {
            $ex = $sfxEntries[$kx]
            $ln = '효과음: "{0}" by {1}, {2}, {3}' -f ([string]$ex.title), ([string]$ex.creator), ([string]$ex.license), ([string]$ex.foreign_landing_url)
            if (([string]$ex.license) -like "CC0*") { $ln += " (표기 선택)" }
            $cl += $ln
        }
        $creditsPath = Join-Path (Split-Path -Parent $out) "credits.txt"
        [IO.File]::WriteAllText($creditsPath, (($cl -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding($true)))
        Say "표기 문구를 만들었습니다: $creditsPath (영상 설명란에 붙여야 합니다)"
    }
}
finally {
    if (-not $KeepTemp) { Remove-Item -LiteralPath $script:TMP -Recurse -Force -ErrorAction SilentlyContinue }
    else { Say "임시 폴더: $($script:TMP)" }
}
$lufsOut = Measure-Lufs $out
if ($null -eq $lufsOut -or [Math]::Abs($lufsOut - $target) -gt 1.5) {
    Fail ("만든 영상의 음량이 목표({0} LUFS)에서 1.5 넘게 벗어납니다 ({1}). 영상은 {2} 에 있지만 쓰지 마세요." -f $target, $lufsOut, $out)
}
$stamp = [ordered]@{ output = (Split-Path -Leaf $out); file_sha256 = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLower(); spec_sha256 = $specSha; lufs = [Math]::Round($lufsOut, 1); rendered_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
[IO.File]::WriteAllText($stampPath, ($stamp | ConvertTo-Json), $utf8)
Say ("완료: {0} ({1:0.00}초, {2:0.0} LUFS)" -f $out, $total, $lufsOut)

if (-not $NoOpen) {
    try {
        if ($env:OS -eq "Windows_NT") { Start-Process -FilePath $out }
        elseif (Get-Command open -ErrorAction SilentlyContinue) { & open $out }
        elseif (Get-Command xdg-open -ErrorAction SilentlyContinue) { & xdg-open $out }
    } catch { Say "영상은 만들었지만 자동으로 열지 못했습니다. 위 경로의 파일을 직접 열어 주세요." }
}
