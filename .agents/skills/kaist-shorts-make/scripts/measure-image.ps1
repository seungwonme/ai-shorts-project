# 사진 한 장을 재서 영상 영역(1080x756)에 맞는 크롭 후보를 만듭니다 (PowerShell 5.1 / 7 겸용)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File measure-image.ps1 -Image "재료\기사-<번호>\img-01.jpg"
#   powershell -NoProfile -ExecutionPolicy Bypass -File measure-image.ps1 -Image "재료\기사-<번호>\img-01.jpg" -Write
#
# 하는 일: 사진 크기와 글자 덩어리(가로 띠)의 위치를 재서 표로 보여 주고, 글자가 잘리지 않고 중요한 글자가
# 영상 영역의 위쪽 75%(자막 영역 위)에 오는 크롭 후보를 만듭니다. 후보는 render.ps1 이 spec 점검에서 쓰는 것과 같은 방법으로 미리 검사합니다.
# -Write 를 주면 후보를 그 사진과 같은 폴더의 crops.json 에 적습니다(이미 있으면 같은 사진 항목만 바꾸고 나머지는 둡니다).
# spec.json 에서는 그 이름을 "crop": "named:<이름>" 으로 씁니다. 숫자는 이 사진을 직접 잰 값이라 다른 기사에는 쓸 수 없습니다.
#
# 한계(꼭 읽을 것): 이것은 밝기 변화(글자 가장자리)를 세는 어림 측정입니다. 글자인지 무늬인지는 모릅니다.
#   - 사진(인물, 풍경)은 어디나 가장자리가 있어 덩어리를 나눌 수 없습니다. 그런 사진은 후보를 만들지 않고 "사진형"이라고 알립니다. 크롭 없이(가운데 채우기) 쓰거나 눈으로 보고 crop 숫자를 직접 정하세요.
#   - 후보의 이름(part-1, part-2 ...)은 위에서부터 번호만 붙입니다. 사진을 눈으로 보고 title, date 처럼 뜻이 있는 이름으로 바꿔도 됩니다.
#   - 어림값입니다. 눈으로 보고 글자가 잘리거나 자막 영역에 걸리면 crop 숫자를 고쳐 쓰세요.
# 이 파일은 UTF-8 (BOM 포함)으로 저장합니다.
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [switch]$Write,
    [string]$FFmpeg = ""
)
. (Join-Path $PSScriptRoot "common.ps1")

# ---- 어림 기준값 (휴리스틱입니다. render.ps1 의 Test-PicPiece 와 같은 값을 씁니다) --------------------------------
$EDGE_DIFF = 40            # 이웃 칸과 밝기 차이가 이보다 크면 가장자리
$ROW_ACTIVE = 0.012        # 한 줄의 가장자리 비율이 이보다 크면 "글자나 그림이 있는 줄"
$GAP_FRAC = 0.018          # 이만큼(사진 높이 비율) 이하의 빈 줄은 같은 덩어리로 묶는다
$MIN_BAND = 0.008          # 이보다 얇은 덩어리는 버린다
$PHOTO_DENSITY = 0.20      # 사진 전체 가장자리 비율이 이 이상이면 사진형(덩어리로 나눌 수 없음)
$CAP_ZONE = 0.25           # 영상 영역 아래 25%는 자막 영역
$MARGIN_X = 0.04           # 글자 덩어리 좌우 여유
$MIN_CROP_W = 0.70         # 이보다 좁게 잘라 확대하지 않는다
$TOP_PAD = 0.03
$AREA_RATIO = 1080.0 / 756.0

$ff = Find-Tool "ffmpeg" $FFmpeg
if (-not $ff) { Fail "FFmpeg를 찾지 못했습니다. setup-windows.bat을 먼저 실행해 주세요." }
if (-not (Test-Path -LiteralPath $Image)) { Fail "사진을 찾지 못했습니다: $Image" }
$imgPath = (Resolve-Path -LiteralPath $Image).Path

$info = Invoke-Tool $ff @("-hide_banner", "-i", $imgPath) $null
$dm = [regex]::Match(($info.Err + $info.Out), 'Video:.*?[, ](\d{2,6})x(\d{2,6})')
if (-not $dm.Success) { Fail "사진 크기를 읽지 못했습니다. 사진 파일이 맞는지 확인해 주세요." }
$iw = [double]$dm.Groups[1].Value; $ih = [double]$dm.Groups[2].Value

function Read-Gray([string]$vf, [int]$w, [int]$h) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("kaist-meas-" + [Guid]::NewGuid().ToString("N").Substring(0, 8) + ".raw")
    try {
        $r = Invoke-Tool $ff @("-hide_banner", "-v", "error", "-y", "-i", $imgPath, "-vf", $vf, "-frames:v", "1", "-f", "rawvideo", $tmp) $null
        if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { return $null }
        $b = [IO.File]::ReadAllBytes($tmp)
        if ($b.Length -lt ($w * $h)) { return $null }
        return $b
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# 가장자리 지도: 오른쪽 또는 아래 이웃과 밝기 차이가 EDGE_DIFF 보다 크면 1
function Get-EdgeMap($b, [int]$w, [int]$h) {
    $e = New-Object 'byte[]' ($w * $h)
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $v = [int]$b[$y * $w + $x]
            if ($x -lt $w - 1 -and [Math]::Abs([int]$b[$y * $w + $x + 1] - $v) -gt $EDGE_DIFF) { $e[$y * $w + $x] = 1 }
            elseif ($y -lt $h - 1 -and [Math]::Abs([int]$b[($y + 1) * $w + $x] - $v) -gt $EDGE_DIFF) { $e[$y * $w + $x] = 1 }
        }
    }
    return ,$e
}

# render.ps1 의 Test-PicPiece 와 같은 검사(216x151 회색 그림, 위 75% / 아래 25% / 좌우 4열). 두 파일을 같이 고칩니다.
function Test-Crop([double]$cx, [double]$cy, [double]$cw, [double]$ch) {
    $W2 = 216; $H2 = 151
    $vf = "crop=iw*$(F $cw):ih*$(F $ch):iw*$(F $cx):ih*$(F $cy),scale=${W2}:${H2}:force_original_aspect_ratio=increase,crop=${W2}:${H2},format=gray"
    $b = Read-Gray $vf $W2 $H2
    if (-not $b) { return $null }
    $cut = [int][Math]::Floor($H2 * 0.75)
    $nTop = 0; $nBot = 0; $nL = 0; $nR = 0
    for ($y = 0; $y -lt $H2; $y++) {
        for ($x = 0; $x -lt $W2; $x++) {
            $v = [int]$b[$y * $W2 + $x]
            $e = $false
            if ($x -lt $W2 - 1 -and [Math]::Abs([int]$b[$y * $W2 + $x + 1] - $v) -gt 40) { $e = $true }
            elseif ($y -lt $H2 - 1 -and [Math]::Abs([int]$b[($y + 1) * $W2 + $x] - $v) -gt 40) { $e = $true }
            if ($e) {
                if ($y -lt $cut) { $nTop++ } else { $nBot++ }
                if ($x -lt 4) { $nL++ }
                if ($x -ge $W2 - 4) { $nR++ }
            }
        }
    }
    $dTop = $nTop / [double]($cut * $W2); $dBot = $nBot / [double](($H2 - $cut) * $W2)
    $dL = $nL / [double](4 * $H2); $dR = $nR / [double](4 * $H2)
    return @{ top = $dTop; bot = $dBot; left = $dL; right = $dR }
}

# 세로로 긴 사진(높이가 폭의 1.1배 이상)만 나눈다. render.ps1 의 자막 영역 점검도 같은 사진에만 적용됩니다.
if (($ih / $iw) -lt 1.1) {
    Say ("사진: {0} ({1}x{2}, 가로:세로 {3}:1)" -f (Split-Path -Leaf $imgPath), [int]$iw, [int]$ih, (($iw / $ih).ToString("0.00", $inv)))
    Say "판정: 세로로 길지 않은 사진입니다. 크롭 후보를 만들지 않습니다. crop 없이 쓰면 영상 영역을 가운데 기준으로 채웁니다."
    Say "  특정 부분을 보여 주려면 사진을 눈으로 보고 crop 숫자를 직접 정하세요. crop 의 실제 픽셀 가로:세로 비율은 1.0:1-2.0:1 에 가깝게 하세요."
    return
}

# ---- 1. 사진 전체 측정 ----------------------------------------------------------------------
$MW = 240
$MH = [int][Math]::Min(480, [Math]::Max(60, [Math]::Round($MW * $ih / $iw)))
$gray = Read-Gray "scale=${MW}:${MH}:flags=area,format=gray" $MW $MH
if (-not $gray) { Fail "사진을 읽지 못했습니다." }
$edge = Get-EdgeMap $gray $MW $MH
$total = 0
$rowN = New-Object 'int[]' $MH
for ($y = 0; $y -lt $MH; $y++) { $c = 0; for ($x = 0; $x -lt $MW; $x++) { $c += $edge[$y * $MW + $x] }; $rowN[$y] = $c; $total += $c }
$density = $total / [double]($MW * $MH)

Say ("사진: {0} ({1}x{2}, 가로:세로 {3}:1)" -f (Split-Path -Leaf $imgPath), [int]$iw, [int]$ih, (($iw / $ih).ToString("0.00", $inv)))
Say ("가장자리 비율(사진 전체): {0}  (기준 {1} 이상이면 사진형)" -f ($density.ToString("0.000", $inv)), $PHOTO_DENSITY)

# ---- 2. 글자 덩어리(가로 띠) 찾기 ---------------------------------------------------------------
$bands = @()
$gapRows = [Math]::Max(1, [int][Math]::Round($GAP_FRAC * $MH))
$start = -1; $last = -1
for ($y = 0; $y -le $MH; $y++) {
    $act = $false
    if ($y -lt $MH) { $act = (($rowN[$y] / [double]$MW) -ge $ROW_ACTIVE) }
    if ($act) { if ($start -lt 0) { $start = $y }; $last = $y }
    elseif ($start -ge 0 -and ($y - $last) -gt $gapRows) {
        $bands += @{ y0 = $start; y1 = $last }
        $start = -1
    }
}
$bandsOut = @()
foreach ($bd in $bands) {
    $h0 = ($bd.y1 - $bd.y0 + 1) / [double]$MH
    if ($h0 -lt $MIN_BAND) { continue }
    $colN = New-Object 'int[]' $MW
    for ($y = $bd.y0; $y -le $bd.y1; $y++) { for ($x = 0; $x -lt $MW; $x++) { $colN[$x] += $edge[$y * $MW + $x] } }
    $x0 = -1; $x1 = -1
    for ($x = 0; $x -lt $MW; $x++) { if ($colN[$x] -ge 1) { if ($x0 -lt 0) { $x0 = $x }; $x1 = $x } }
    if ($x0 -lt 0) { continue }
    $bandsOut += @{ y0 = [Math]::Round($bd.y0 / [double]$MH, 4); y1 = [Math]::Round(($bd.y1 + 1) / [double]$MH, 4); x0 = [Math]::Round($x0 / [double]$MW, 4); x1 = [Math]::Round(($x1 + 1) / [double]$MW, 4) }
}
$photoLike = ($density -ge $PHOTO_DENSITY) -or ($bandsOut.Count -lt 1) -or ($bandsOut.Count -eq 1 -and ($bandsOut[0].y1 - $bandsOut[0].y0) -gt 0.9)
Say ""
if ($bandsOut.Count -gt 0) {
    Say "덩어리 (사진 높이와 너비에 대한 비율):"
    $k = 0
    foreach ($bd in $bandsOut) { $k++; Say ("  {0}. 세로 {1}-{2}, 가로 {3}-{4}" -f $k, (F $bd.y0), (F $bd.y1), (F $bd.x0), (F $bd.x1)) }
}
if ($photoLike) {
    Say ""
    Say "판정: 사진형(또는 덩어리를 나눌 수 없음). 크롭 후보를 만들지 않습니다."
    Say "  크롭 없이 쓰면 영상 영역을 가운데 기준으로 채웁니다. 특정 부분을 보여 주려면 사진을 눈으로 보고 crop 숫자를 직접 정하세요."
    Say "  (세로로 긴 사진이면 crop 의 가로:세로 실제 픽셀 비율을 1.0:1-2.0:1 에 가깝게, 중요한 부분을 위쪽 75%에 두세요.)"
    return
}

# ---- 3. 크롭 후보 만들기 ---------------------------------------------------------------------
# 가장자리 지도의 적분 이미지(구간 합을 한 번에 구한다)
$IW1 = $MW + 1
$integ = New-Object 'int[]' (($MW + 1) * ($MH + 1))
for ($y = 0; $y -lt $MH; $y++) {
    $rowSum = 0
    for ($x = 0; $x -lt $MW; $x++) {
        $rowSum += $edge[$y * $MW + $x]
        $integ[($y + 1) * $IW1 + ($x + 1)] = $integ[$y * $IW1 + ($x + 1)] + $rowSum
    }
}
# 사진 비율(0-1) 영역 안의 가장자리 칸 수
function Region-Sum([double]$fx0, [double]$fy0, [double]$fx1, [double]$fy1) {
    $x0 = [int][Math]::Max(0, [Math]::Min($MW, [Math]::Round($fx0 * $MW))); $x1 = [int][Math]::Max(0, [Math]::Min($MW, [Math]::Round($fx1 * $MW)))
    $y0 = [int][Math]::Max(0, [Math]::Min($MH, [Math]::Round($fy0 * $MH))); $y1 = [int][Math]::Max(0, [Math]::Min($MH, [Math]::Round($fy1 * $MH)))
    if ($x1 -le $x0 -or $y1 -le $y0) { return @(0, 1) }
    $sum = $integ[$y1 * $IW1 + $x1] - $integ[$y0 * $IW1 + $x1] - $integ[$y1 * $IW1 + $x0] + $integ[$y0 * $IW1 + $x0]
    return @($sum, (($x1 - $x0) * ($y1 - $y0)))
}
# 크롭 창(x,y,w,h)을 어림으로 점검: 위 75% 대비 아래 25% 글자 밀도, 좌우 가장자리 띠(크롭 폭의 1.85%)의 밀도
function Eval-Window([double]$cx, [double]$cy, [double]$cw, [double]$ch) {
    $cutY = $cy + 0.75 * $ch
    $t = Region-Sum $cx $cy ($cx + $cw) $cutY; $bt = Region-Sum $cx $cutY ($cx + $cw) ($cy + $ch)
    $dT = $t[0] / [double]$t[1]; $dB = $bt[0] / [double]$bt[1]
    $strip = 0.0185 * $cw
    $l = Region-Sum $cx $cy ($cx + $strip) ($cy + $ch); $r = Region-Sum ($cx + $cw - $strip) $cy ($cx + $cw) ($cy + $ch)
    $dL = $l[0] / [double]$l[1]; $dR = $r[0] / [double]$r[1]
    if ($cx -le 0.005) { $dL = 0.0 }
    if (($cx + $cw) -ge 0.995) { $dR = 0.0 }
    $capOk = (-not ($dB -ge 0.03 -and $dB -ge 0.7 * $dT))
    $sideOk = ($dL -le 0.03 -and $dR -le 0.03)
    return @{ ok = ($capOk -and $sideOk); cap = $capOk; side = $sideOk; dB = $dB; dT = $dT; dL = $dL; dR = $dR }
}
# 덩어리 i..j 를 위쪽 75%에 담는 창을 찾는다. 가장 좁은 폭, 그다음 덩어리가 위쪽 40% 근처에 오는 위치를 고른다.
function Find-Window([int]$i, [int]$j) {
    $gx0 = ($bandsOut[$i..$j] | ForEach-Object { $_.x0 } | Measure-Object -Minimum).Minimum
    $gx1 = ($bandsOut[$i..$j] | ForEach-Object { $_.x1 } | Measure-Object -Maximum).Maximum
    $gy0 = $bandsOut[$i].y0; $gy1 = $bandsOut[$j].y1
    $wmin = [Math]::Min(1.0, [Math]::Max($MIN_CROP_W, ($gx1 - $gx0) + 2 * $MARGIN_X))
    $cands = @()
    for ($w = $wmin; $w -le 1.0001; $w += 0.04) {
        $w = [Math]::Min(1.0, $w)
        $hF = ($w * $iw / $AREA_RATIO) / $ih
        if ($hF -gt 1.0) { break }
        $lo = [Math]::Max(0.0, $gy1 + 0.01 - 0.75 * $hF); $hi = [Math]::Min($gy0 - 0.01, 1.0 - $hF)
        if ($gy0 -lt 0.02) { $hi = [Math]::Min(1.0 - $hF, [Math]::Max(0.0, $gy0)) }
        if ($hi -lt $lo) { continue }
        $xc = (($gx0 + $gx1) / 2.0) - $w / 2.0
        $cx = [Math]::Max(0.0, [Math]::Min(1.0 - $w, $xc))
        if ($cx -gt $gx0 - 0.01 -or ($cx + $w) -lt $gx1 + 0.01) { continue }
        for ($cy = $lo; $cy -le $hi + 0.0001; $cy += 0.01) {
            $ev = Eval-Window $cx $cy $w $hF
            if ($ev.ok) {
                $mid = (($gy0 + $gy1) / 2.0 - $cy) / $hF
                $cands += @{ x = $cx; y = $cy; w = $w; h = $hF; score = ([Math]::Abs($mid - 0.38) + 3 * ($w - $wmin)); gy0 = $gy0; gy1 = $gy1 }
            }
        }
        if ($cands.Count -gt 0) { break }
    }
    if ($cands.Count -eq 0) { return $null }
    return ,@($cands | Sort-Object { $_.score })
}

$props = @()
foreach ($pass in @(@{ span = 9.0; pre = "part" }, @{ span = 0.25; pre = "detail" })) {
$i = 0
$part = 0
while ($i -lt $bandsOut.Count) {
    $bestList = $null; $bestJ = $i
    for ($j = $i; $j -lt $bandsOut.Count; $j++) {
        if ($j -gt $i -and ($bandsOut[$j].y1 - $bandsOut[$i].y0) -gt $pass.span) { break }
        $lst = Find-Window $i $j
        if ($lst -and $lst.Count -gt 0 -and $lst[0]) { $bestList = $lst; $bestJ = $j } else { break }
    }
    $part++
    if ($bestList) {
        # 어림으로 고른 후보 몇 개를 render.ps1 과 같은 방법(실제 크롭 사진)으로 다시 검사한다
        $picked = $null; $why = @()
        $tries = [Math]::Min(6, $bestList.Count)
        for ($t = 0; $t -lt $tries; $t++) {
            $cd = $bestList[$t]
            $r = Test-Crop $cd.x $cd.y $cd.w $cd.h
            $good = $true; $why = @()
            if ($r) {
                if ($r.bot -ge 0.03 -and $r.bot -ge 0.7 * $r.top) { $good = $false; $why += "자막 영역에 글자가 몰림" }
                if (($cd.x -gt 0.005 -and $r.left -gt 0.03) -or (($cd.x + $cd.w) -lt 0.995 -and $r.right -gt 0.03)) { $good = $false; $why += "좌우 가장자리에 글자가 걸림" }
            }
            if ($good) { $picked = $cd; break }
        }
        if ($picked -and $pass.pre -eq "detail" -and (@($props | Where-Object { $_.ok -and $_.covers -eq ("세로 {0}-{1}" -f (F $picked.gy0), (F $picked.gy1)) }).Count -gt 0)) { $i = $bestJ + 1; continue }
        if ($picked) {
            $props += @{ name = ($pass.pre + "-" + $part); x = [Math]::Round($picked.x, 3); y = [Math]::Round($picked.y, 3); w = [Math]::Round($picked.w, 3); h = [Math]::Round($picked.h, 3); ok = $true; why = ""; covers = ("세로 {0}-{1}" -f (F $picked.gy0), (F $picked.gy1)) }
            $i = $bestJ + 1
            continue
        }
        $props += @{ name = ($pass.pre + "-" + $part); x = [Math]::Round($bestList[0].x, 3); y = [Math]::Round($bestList[0].y, 3); w = [Math]::Round($bestList[0].w, 3); h = [Math]::Round($bestList[0].h, 3); ok = $false; why = ($why -join ", "); covers = ("세로 {0}-{1}" -f (F $bestList[0].gy0), (F $bestList[0].gy1)) }
        $i = $bestJ + 1
        continue
    }
    $bd = $bandsOut[$i]
    $props += @{ name = ($pass.pre + "-" + $part); x = 0.0; y = 0.0; w = 1.0; h = 1.0; ok = $false; why = "이 덩어리는 영상 영역에 글자가 잘리지 않고 위쪽 75%에 담을 수 있는 크롭이 없음(눈으로 보고 직접 정하세요)"; covers = ("세로 {0}-{1}" -f (F $bd.y0), (F $bd.y1)) }
    $i = $i + 1
}
}

Say ""
Say "크롭 후보 (spec.json 에서는 `"crop`": `"named:이름`" 으로 씁니다):"
foreach ($p in @($props | Where-Object { $_.ok -or $_.name -like "part-*" })) {
    $flag = "통과"; if (-not $p.ok) { $flag = "주의: " + $p.why }
    $px = ($p.w * $iw) / ($p.h * $ih)
    Say ("  {0}: x {1}, y {2}, w {3}, h {4}  ({5}, 실제 비율 {6}:1)  {7}" -f $p.name, (F $p.x), (F $p.y), (F $p.w), (F $p.h), $p.covers, $px.ToString("0.00", $inv), $flag)
}

if ($Write) {
    $dir = Split-Path -Parent $imgPath
    $cj = Join-Path $dir "crops.json"
    $root = [ordered]@{}
    if (Test-Path -LiteralPath $cj) {
        try {
            $old = Get-Content -LiteralPath $cj -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($pr in $old.PSObject.Properties) { $root[$pr.Name] = $pr.Value }
        } catch { Fail "기존 crops.json 을 읽지 못했습니다. 파일을 확인해 주세요: $cj" }
    }
    $mine = [ordered]@{}
    foreach ($p in $props) {
        if (-not $p.ok) { continue }
        $mine[$p.name] = [ordered]@{ x = $p.x; y = $p.y; w = $p.w; h = $p.h; covers = $p.covers; measured = (Get-Date).ToString("yyyy-MM-dd HH:mm"); tool = "measure-image.ps1" }
    }
    if ($mine.Count -eq 0) {
        Say ""
        Say "통과한 후보가 없어 crops.json 에 적지 않았습니다. 사진을 눈으로 보고 crop 숫자를 직접 정하거나 crop 없이 쓰세요."
        return
    }
    $root[(Split-Path -Leaf $imgPath)] = $mine
    Write-Utf8 $cj (($root | ConvertTo-Json -Depth 6))
    Say ""
    Say ("crops.json 에 통과한 후보 {0}개를 적었습니다: {1}" -f $mine.Count, $cj)
    Say "  (주의 표시가 붙은 후보는 적지 않았습니다. 이름은 사진을 보고 title, date 처럼 바꿔도 됩니다.)"
}
