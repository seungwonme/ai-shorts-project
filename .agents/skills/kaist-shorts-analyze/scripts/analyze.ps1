# 쇼츠 분석 도구 (PowerShell 5.1 / 7 겸용)
#
#   1단계 재료 모으기:  analyze.ps1 -Source "https://www.youtube.com/shorts/xxxx"   (또는 mp4 파일 경로)
#   3단계 보고서 만들기: analyze.ps1 -Report -Dir "결과\260929-분석-xxxx"
#
# 1단계는 영상에서 컷 위치, 컷마다 첫 화면, 컷 모음표, 소리 크기, 제목 글자 부분 사진,
# 12초 소리 조각을 뽑아 결과 폴더에 둡니다. 2단계(findings.json 채우기)는 Codex가 사진을 보고 합니다.
# 3단계는 findings.json과 측정값으로 report.html(인터넷 없이 열리는 한 페이지)을 만들어 엽니다.
#
# 필요한 것: FFmpeg(ffprobe 포함). 주소를 넣을 때만 yt-dlp(와 Deno)가 더 필요합니다. 파이썬은 쓰지 않습니다.
# 이 파일은 UTF-8 (BOM 포함)으로 저장합니다. PowerShell 5.1은 BOM이 없으면 한글을 깨뜨립니다.
param(
    [string]$Source = "",
    [switch]$Report,
    [string]$Dir = "",
    [string]$Name = "",
    [double]$SceneThreshold = 0.10,
    [string]$VideoBox = "",
    [double]$ClipStart = -1,
    [string]$TitleBox = "",
    [string]$FFmpeg = "",
    [string]$YtDlp = "",
    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"
$inv = [Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$utf8 = New-Object Text.UTF8Encoding($false)

function F([double]$n) { return $n.ToString("0.###", $inv) }
function Say([string]$msg) { Write-Host $msg }
function Fail([string]$msg) { throw $msg }

function Find-Tool([string]$name, [string]$hint) {
    if ($hint -and (Test-Path -LiteralPath $hint)) { return (Resolve-Path -LiteralPath $hint).Path }
    $envName = "KAIST_" + $name.ToUpper().Replace("-", "")
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

function Tail([string]$s, [int]$n) {
    if ($s.Length -gt $n) { return $s.Substring($s.Length - $n) }
    return $s
}

function Run-FFmpeg([string[]]$argList, [string]$what) {
    $r = Invoke-Tool $script:FFMPEG_EXE (@("-hide_banner", "-nostats") + $argList) $null
    if ($r.Code -ne 0) { Fail ("실패: $what`n" + (Tail $r.Err 1500)) }
    return $r
}

function Get-Opt($obj, [string]$name, $default) {
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $default
}

function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8) }
function Json([object]$o) { return ($o | ConvertTo-Json -Depth 12) }

# 프로젝트 폴더 = "재료" 폴더가 있는 가장 가까운 윗 폴더
function Find-ProjectRoot {
    foreach ($start in @((Get-Location).Path, $PSScriptRoot)) {
        for ($d = $start; $d; $d = Split-Path -Parent $d) {
            if ((Test-Path -LiteralPath (Join-Path $d "재료") -PathType Container) -and (Test-Path -LiteralPath (Join-Path $d "결과") -PathType Container)) { return $d }
        }
    }
    return (Get-Location).Path
}
$ROOT = Find-ProjectRoot

function Open-File([string]$path) {
    try {
        if ($env:OS -eq "Windows_NT") { Start-Process -FilePath $path }
        elseif (Get-Command open -ErrorAction SilentlyContinue) { & open $path }
        elseif (Get-Command xdg-open -ErrorAction SilentlyContinue) { & xdg-open $path }
    } catch { Say "자동으로 열지 못했습니다. 위 경로의 파일을 직접 열어 주세요." }
}

# =========================================================================================
# 3단계: 보고서
# =========================================================================================
function Esc([string]$s) { return [Net.WebUtility]::HtmlEncode($s) }

function Items-Html($group) {
    if ($null -eq $group) { return "<p class='muted'>아직 채우지 않았습니다.</p>" }
    $rows = ""
    foreach ($it in @(Get-Opt $group "items" @())) {
        $what = [string](Get-Opt $it "what" ""); $value = [string](Get-Opt $it "value" "")
        if (-not $what -and -not $value) { continue }
        $ev = ""
        $evRaw = Get-Opt $it "evidence" @()
        foreach ($e in @($evRaw)) {
            $e = [string]$e
            if (-not $e) { continue }
            if ($e -match '\.(jpg|jpeg|png|gif)$') { $ev += "<a href='$(Esc $e)'><img class='ev' src='$(Esc $e)' alt='근거 사진'></a>" }
            elseif ($e -match '\.(mp3|wav)$') { $ev += "<audio controls src='$(Esc $e)'></audio>" }
            else { $ev += "<span class='tag'>$(Esc $e)</span>" }
        }
        $rows += "<tr><td>$(Esc $what)</td><td>$(Esc $value)</td><td>$ev</td></tr>"
    }
    if (-not $rows) { return "<p class='muted'>아직 채우지 않았습니다.</p>" }
    return "<table><thead><tr><th>무엇이 보이나</th><th>잰 값 / 확인한 내용</th><th>근거</th></tr></thead><tbody>$rows</tbody></table>"
}

function Build-Report([string]$dir) {
    $a = Get-Content -LiteralPath (Join-Path $dir "analysis.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $fp = Join-Path $dir "findings.json"
    $fd = $null
    if (Test-Path -LiteralPath $fp) { $fd = Get-Content -LiteralPath $fp -Raw -Encoding UTF8 | ConvertFrom-Json }
    $g = Get-Opt $fd "groups" $null
    $title = [string](Get-Opt $fd "title" "")
    if (-not $title) { $title = [string](Get-Opt $a.meta "title" $a.name) }
    $summary = [string](Get-Opt $fd "summary" "")

    $m = $a.meta
    $metaRows = @(
        @("제목", (Get-Opt $m "title" "")), @("올린 곳", (Get-Opt $m "uploader" "")), @("올린 날", (Get-Opt $m "upload_date" "")),
        @("조회수", (Get-Opt $m "view_count" "")), @("길이", ("{0:0.0}초" -f [double]$m.duration)),
        @("화면 크기", ("{0} x {1}" -f $m.width, $m.height)), @("프레임 수(초당)", (Get-Opt $m "fps" "")),
        @("영상/소리 방식", ("{0} / {1}" -f (Get-Opt $m "video_codec" "-"), (Get-Opt $m "audio_codec" "소리 없음"))),
        @("원본 주소", (Get-Opt $a "source_url" "(내 컴퓨터의 파일)"))
    )
    $metaHtml = ""
    foreach ($r in $metaRows) { if ("$($r[1])" -ne "") { $metaHtml += "<tr><th>$(Esc $r[0])</th><td>$(Esc ([string]$r[1]))</td></tr>" } }

    # 컷 표
    $cutRows = ""
    foreach ($c in @($a.cuts)) {
        $cutRows += ("<tr><td>{0}</td><td>{1:0.00}</td><td>{2:0.00}</td><td>{3:0.00}</td><td><a href='{4}'><img class='thumb' src='{4}' alt='컷 {0}'></a></td></tr>" -f $c.index, [double]$c.start, [double]$c.end, [double]$c.length, (Esc $c.frame))
    }
    $cs = $a.cut_stats
    $cutSummary = "컷 $($cs.count)개, 평균 $('{0:0.00}' -f [double]$cs.mean)초, 가운데 값 $('{0:0.00}' -f [double]$cs.median)초, 가장 짧은 컷 $('{0:0.00}' -f [double]$cs.min)초, 가장 긴 컷 $('{0:0.00}' -f [double]$cs.max)초"

    # 소리
    $soundHtml = ""
    $lo = $a.loudness
    if ($lo -and $lo.available) {
        $soundHtml = "<table><tbody><tr><th>통합 음량</th><td>$(Esc ([string]$lo.integrated_lufs)) LUFS</td></tr><tr><th>소리 폭(LRA)</th><td>$(Esc ([string]$lo.lra)) LU</td></tr><tr><th>가장 큰 소리(피크)</th><td>$(Esc ([string]$lo.peak_dbfs)) dBFS</td></tr></tbody></table><p class='muted'>참고: KAIST 공식 쇼츠 솔직후기는 약 -18.7 LUFS(2026-11-15 같은 방법으로 잼). 값이 클수록(0에 가까울수록) 큰 소리입니다.</p>"
    } else { $soundHtml = "<p class='muted'>이 영상에는 소리가 없거나 잴 수 없었습니다.</p>" }

    $clipHtml = ""
    if (Get-Opt $a.files "audio_clip_mp3" $null) { $clipHtml = "<audio controls src='$(Esc $a.files.audio_clip_mp3)'></audio>" }
    elseif (Get-Opt $a.files "audio_clip_wav" $null) { $clipHtml = "<audio controls src='$(Esc $a.files.audio_clip_wav)'></audio>" }

    # 폰트 후보
    $fontRows = ""
    foreach ($c in @(Get-Opt (Get-Opt $fd "font" $null) "candidates" @())) {
        $nm = [string](Get-Opt $c "name" "")
        if ($nm) { $fontRows += "<tr><td>$(Esc $nm)</td><td>$(Esc ([string](Get-Opt $c 'confidence' '')))</td><td>$(Esc ([string](Get-Opt $c 'why' '')))</td></tr>" }
    }
    if (-not $fontRows) { $fontRows = "<tr><td colspan='3' class='muted'>아직 후보를 적지 않았습니다.</td></tr>" }
    $musicNote = [string](Get-Opt (Get-Opt $fd "music" $null) "note" "")

    $css = @"
body{font-family:'Malgun Gothic','Apple SD Gothic Neo',sans-serif;margin:0;background:#f6f7f9;color:#1d2330;line-height:1.6}
main{max-width:980px;margin:0 auto;padding:24px 20px 80px}
h1{font-size:28px;margin:8px 0}h2{font-size:21px;margin:0 0 10px;padding-top:6px}
section{background:#fff;border:1px solid #dfe3ea;border-radius:12px;padding:18px 22px;margin:18px 0}
table{border-collapse:collapse;width:100%;font-size:15px}th,td{border-bottom:1px solid #e6e9ef;padding:7px 9px;text-align:left;vertical-align:top}
thead th{background:#eef2f7}.muted{color:#667085;font-size:14px}.tag{background:#eef2f7;border-radius:6px;padding:2px 8px;font-size:13px}
img.ev{height:96px;border-radius:6px;margin:2px 6px 2px 0;border:1px solid #d5dae3}img.thumb{height:84px;border-radius:4px}
img.big{max-width:100%;max-height:520px;border-radius:8px;border:1px solid #d5dae3}
.row{display:flex;gap:18px;flex-wrap:wrap;align-items:flex-start}.row>div{flex:1;min-width:260px}
.hint{background:#fff8e6;border:1px solid #f2dc9b;border-radius:8px;padding:10px 14px;font-size:14px}
ol li,ul li{margin:4px 0}code{background:#eef2f7;padding:1px 6px;border-radius:4px}
nav a{margin-right:12px;font-size:14px}
"@
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add("<!DOCTYPE html><html lang='ko'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>쇼츠 설계도: $(Esc $title)</title><style>$css</style></head><body><main>")
    [void]$parts.Add("<h1>쇼츠 설계도</h1><p><b>$(Esc $title)</b></p>")
    if ($summary) { [void]$parts.Add("<p>$(Esc $summary)</p>") }
    [void]$parts.Add("<nav><a href='#frame'>1 화면 틀</a><a href='#visual'>2 시각 자료</a><a href='#text'>3 글자</a><a href='#sound'>4 소리</a><a href='#flow'>5 흐름</a><a href='#font'>폰트 찾기</a><a href='#music'>곡 찾기</a><a href='#ask'>볼 때 묻는 질문</a></nav>")
    [void]$parts.Add("<section><h2>영상 정보</h2><table><tbody>$metaHtml</tbody></table></section>")

    [void]$parts.Add("<section id='frame'><h2>1. 화면 틀</h2><p class='muted'>화면을 어떤 칸으로 나눴는지(로고, 제목, 영상 칸, 아래 안내)와 크기, 색, 위치입니다.</p><div class='row'><div><img class='big' src='$(Esc $a.files.first_frame)' alt='첫 화면'></div></div>$(Items-Html (Get-Opt $g 'frame' $null))</section>")
    [void]$parts.Add("<section id='visual'><h2>2. 시각 자료</h2><p class='muted'>영상, 사진, 그림 같은 화면 자료가 어떤 것으로 어떻게 쓰였는지입니다. 아래는 컷마다 첫 화면을 모은 표입니다(왼쪽 위부터 번호 순서).</p><a href='$(Esc $a.files.contact_sheet)'><img class='big' src='$(Esc $a.files.contact_sheet)' alt='컷 모음표'></a>$(Items-Html (Get-Opt $g 'visual' $null))</section>")
    [void]$parts.Add("<section id='text'><h2>3. 글자 (제목, 자막)</h2><p class='muted'>제목과 자막의 내용, 색, 크기, 위치, 나타나는 시간입니다.</p>$(Items-Html (Get-Opt $g 'text' $null))</section>")
    [void]$parts.Add("<section id='sound'><h2>4. 소리 (대사/나레이션, 배경 음악, 효과음)</h2>$soundHtml$clipHtml$(Items-Html (Get-Opt $g 'sound' $null))</section>")
    [void]$parts.Add("<section id='flow'><h2>5. 흐름 (컷 길이, 순서)</h2><p><b>$(Esc $cutSummary)</b></p><p class='muted'>컷은 화면이 바뀌는 한 토막입니다. 장면은 뜻으로 묶은 컷 몇 개입니다. 흐름은 컷의 길이와 순서가 도입, 전개, 강조, 마무리로 어떻게 이어지는지 봅니다. 컷은 화면이 확 바뀌는 곳을 프로그램이 찾은 것이라 서서히 바뀌는 전환은 놓칠 수 있습니다.</p>$(Items-Html (Get-Opt $g 'flow' $null))<details open><summary>컷 목록</summary><table><thead><tr><th>번호</th><th>시작(초)</th><th>끝(초)</th><th>길이(초)</th><th>첫 화면</th></tr></thead><tbody>$cutRows</tbody></table></details></section>")

    $fontSec = @"
<section id='font'><h2>폰트 찾기</h2>
<p class='muted'>제목 글자가 있는 부분을 잘라 둔 사진입니다. 글꼴 이름은 사진만으로 확정할 수 없고, 아래 순서로 후보를 좁힙니다.</p>
<img class='big' src='$(Esc $a.files.title_crop)' alt='제목 부분'>
<ol>
<li>이 사진을 Codex 대화창에 붙여 넣고 <code>이 제목 글꼴과 닮은 무료 글꼴 후보 5개를 알려줘</code>라고 말합니다. 답은 후보일 뿐 정답이 아닙니다.</li>
<li>후보 이름을 <b>눈누(noonnu.cc)</b>에서 검색해 모양을 눈으로 비교하고, 글꼴 상세 페이지의 <b>라이선스(상업 이용, 재배포)</b>를 읽습니다.</li>
<li>글꼴 이미지 검색 서비스(예: 산돌구름 글꼴 찾기, WhatTheFont, WhatFontIs)에 이 사진을 올려 볼 수 있습니다. 영어 글꼴 위주인 서비스가 많고, 무료 범위와 로그인 여부는 직접 확인해야 합니다. 외부 사이트에 올리는 것이므로 공개된 영상의 화면만 올립니다.</li>
<li>가장 확실한 방법: 후보 글꼴로 같은 문구를 써서 원본 사진 위에 겹쳐 봅니다. Codex에게 <code>후보 글꼴로 같은 문구를 그려서 원본과 비교해줘</code>라고 부탁하세요.</li>
</ol>
<p class='hint'>무료로 쓸 수 있는 글꼴 예: Gmarket Sans(SIL 오픈 폰트 라이선스, 이 프로젝트에 들어 있음), Pretendard. 어떤 글꼴이든 쓰기 전에 라이선스 문서를 직접 읽으세요.</p>
<table><thead><tr><th>후보</th><th>확신</th><th>이유</th></tr></thead><tbody>$fontRows</tbody></table></section>
"@
    [void]$parts.Add($fontSec)

    $musicSec = @"
<section id='music'><h2>곡 찾기</h2>
<p class='muted'>영상 속 12초를 잘라 둔 소리 조각입니다. 배경 음악만 들리는 구간이 좋습니다.</p>
$clipHtml
<p>$(Esc $musicNote)</p>
<ol>
<li>유튜브 쇼츠라면 먼저 화면 아래의 <b>소리 이름</b>을 눌러 봅니다. 음원이 표시되는 영상이면 가장 빠릅니다.</li>
<li>곡 식별 서비스에 소리 조각을 올려 봅니다: <b>AudD</b>(audd.io), <b>ACRCloud</b>(acrcloud.com). 둘 다 계정이 필요하고 무료 범위가 정해져 있으며, 정책은 바뀔 수 있습니다. 외부에 올리는 것이므로 공개된 영상의 소리만 올립니다.</li>
<li>결과가 없다고 해서 무료 음원이라는 뜻은 아닙니다. 데이터에 없는 곡일 뿐입니다.</li>
<li>곡 이름을 알아내도 <b>써도 된다는 허락은 아닙니다</b>. 허락(라이선스)은 따로 확인합니다.</li>
</ol>
<h3>내 쇼츠에 쓸 음악, 효과음을 구하는 곳</h3>
<ul>
<li><b>공유마당</b>(gongu.copyright.or.kr): 곡마다 조건이 다릅니다. 공공누리 제1유형, CC BY처럼 상업 이용이 되는 것만 고르고, 출처 표시 조건을 지킵니다.</li>
<li><b>YouTube 오디오 라이브러리</b>(YouTube Studio 안): 유튜브에 올릴 영상이면 저작권 클레임 위험이 낮은 편입니다. 다른 곳에 다시 쓸 때의 조건은 약관을 확인합니다.</li>
<li><b>Freesound</b>(freesound.org): 효과음은 <b>CC0</b> 표시된 것만 씁니다.</li>
<li>쓰지 않는 것: <b>CC BY-NC</b>(비영리 한정) 표시 음원. 기관 홍보에는 쓰지 않는 것이 안전합니다.</li>
</ul>
<p class='hint'>음악과 효과음 파일은 이 프로젝트 폴더나 저장소에 넣지 않고 <code>재료</code> 폴더에만 둡니다.</p>
<h3>쓴 소리마다 남길 기록</h3>
<table><thead><tr><th>곡/효과음 제목</th><th>만든 사람</th><th>받은 주소</th><th>라이선스 이름</th><th>상업 이용 가능 문구</th><th>출처 표시 문구</th><th>받은 날</th></tr></thead><tbody><tr><td>&nbsp;</td><td></td><td></td><td></td><td></td><td></td><td></td></tr></tbody></table></section>
"@
    [void]$parts.Add($musicSec)
    $qs = @("첫 장면이 관심을 끄는가?", "가장 먼저 보이는 것은 무엇인가?", "전환 속도가 내용과 맞는가?", "소리가 화면과 맞는가?", "자막이 핵심을 돕는가?", "끝나고 남는 메시지는 무엇인가?")
    $ans = @(Get-Opt $fd "questions" @())
    $qHtml = ""
    for ($qi = 0; $qi -lt $qs.Count; $qi++) {
        $a1 = ""
        if ($qi -lt $ans.Count) { $a1 = [string](Get-Opt $ans[$qi] "answer" "") }
        if ($a1) { $a1 = "<br><span class='tag'>답</span> " + (Esc $a1) } else { $a1 = "<br><span class='muted'>(답을 적지 않았습니다)</span>" }
        $qHtml += "<li>$(Esc $qs[$qi])$a1</li>"
    }
    [void]$parts.Add("<section id='ask'><h2>볼 때 묻는 질문</h2><p class='muted'>쇼츠를 볼 때마다 이 여섯 가지를 스스로에게 물어보세요. 설계도를 읽는 방법이자, 내 쇼츠를 점검하는 방법입니다.</p><ol>$qHtml</ol></section>")
    [void]$parts.Add("<p class='muted'>이 보고서는 분석 도구가 잰 값과 Codex가 사진을 보고 적은 내용으로 만들었습니다. 사진으로 읽은 내용은 틀릴 수 있으니 중요한 값은 직접 확인하세요.</p></main></body></html>")
    $out = Join-Path $dir "report.html"
    Write-Utf8 $out (($parts.ToArray()) -join "`n")
    return $out
}

if ($Report) {
    if (-not $Dir) { Fail "-Dir 에 결과 폴더를 적어 주세요. 예: -Dir 결과\260929-분석-xxxx" }
    $d = $Dir
    if (-not [IO.Path]::IsPathRooted($d)) {
        $c = Join-Path (Get-Location).Path $d
        if (Test-Path -LiteralPath $c) { $d = $c } else { $d = Join-Path $ROOT $d }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $d "analysis.json"))) { Fail "analysis.json이 없습니다. 먼저 1단계(-Source)를 실행하세요: $d" }
    $rp = Build-Report $d
    Say "보고서를 만들었습니다: $rp"
    if (-not $NoOpen) { Open-File $rp }
    return
}

# =========================================================================================
# 1단계: 재료 모으기
# =========================================================================================
if (-not $Source) { Fail "-Source 에 유튜브 주소나 mp4 파일 경로를 적어 주세요." }

$script:FFMPEG_EXE = Find-Tool "ffmpeg" $FFmpeg
if (-not $script:FFMPEG_EXE) { Fail "FFmpeg를 찾지 못했습니다. 설치 파일(setup-windows.bat)을 먼저 실행해 주세요." }
$ffdir = Split-Path -Parent $script:FFMPEG_EXE
$probeName = "ffprobe"; if ($env:OS -eq "Windows_NT") { $probeName = "ffprobe.exe" }
$FFPROBE_EXE = Join-Path $ffdir $probeName
if (-not (Test-Path -LiteralPath $FFPROBE_EXE)) { $FFPROBE_EXE = Find-Tool "ffprobe" "" }
if (-not $FFPROBE_EXE) { Fail "ffprobe를 찾지 못했습니다. FFmpeg 설치가 온전한지 확인해 주세요." }

$isUrl = $Source -match '^https?://'
$info = $null
$src = $null
if ($isUrl) {
    $ytExe = Find-Tool "yt-dlp" $YtDlp
    if (-not $ytExe) { Fail "yt-dlp를 찾지 못했습니다. 주소 대신 mp4 파일을 재료 폴더에 넣고 그 경로를 알려 주세요." }
    Say "주소에서 영상 정보를 읽는 중..."
    $ir = Invoke-Tool $ytExe @("--dump-single-json", "--no-playlist", "--no-warnings", $Source) $null
    if ($ir.Code -ne 0) {
        $hint = ""
        if ($ir.Err -match "(?i)js runtime|javascript|deno") { $hint = "`n(유튜브 주소를 읽으려면 Deno가 필요합니다. 설치 파일에 들어 있는지 확인해 주세요.)" }
        Fail ("yt-dlp가 영상 정보를 읽지 못했습니다.`n" + (Tail $ir.Err 1200) + $hint)
    }
    $info = $ir.Out | ConvertFrom-Json
    $vid = [string](Get-Opt $info "id" "video")
    $slug = $vid
    $mats = Join-Path $ROOT "재료"
    New-Item -ItemType Directory -Force -Path $mats | Out-Null
    $existing = Get-ChildItem -LiteralPath $mats -Filter "ref-$vid.*" -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @(".mp4", ".mkv", ".webm") } | Select-Object -First 1
    if ($existing) { $src = $existing.FullName; Say "이미 받아 둔 영상을 씁니다: $src" }
    else {
        Say "영상을 내려받는 중... (재료 폴더)"
        $tmpl = Join-Path $mats "ref-$vid.%(ext)s"
        $dl = Invoke-Tool $ytExe @("--no-playlist", "--no-warnings", "--ffmpeg-location", $ffdir, "-f", "bv*[height<=1920][vcodec^=avc1]+ba/bv*[height<=1920]+ba/b", "--merge-output-format", "mp4", "-o", $tmpl, $Source) $null
        if ($dl.Code -ne 0) { Fail ("내려받기에 실패했습니다.`n" + (Tail $dl.Err 1200)) }
        $got = Get-ChildItem -LiteralPath $mats -Filter "ref-$vid.*" | Where-Object { $_.Extension -in @(".mp4", ".mkv", ".webm") } | Select-Object -First 1
        if (-not $got) { Fail "내려받은 파일을 찾지 못했습니다." }
        $src = $got.FullName
    }
} else {
    $cand = $Source
    if (-not [IO.Path]::IsPathRooted($cand)) {
        $c1 = Join-Path (Get-Location).Path $cand
        if (Test-Path -LiteralPath $c1) { $cand = $c1 } else { $cand = Join-Path $ROOT $cand }
    }
    if (-not (Test-Path -LiteralPath $cand)) { Fail "파일을 찾지 못했습니다: $Source" }
    $src = (Resolve-Path -LiteralPath $cand).Path
    $slug = [IO.Path]::GetFileNameWithoutExtension($src)
}
if ($Name) { $slug = $Name }
$slug = ($slug -replace '[\\/:*?"<>|\s]+', '-').Trim("-")
if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40) }
$outDir = Join-Path (Join-Path $ROOT "결과") ((Get-Date).ToString("yyMMdd") + "-분석-" + $slug)
$framesDir = Join-Path $outDir "frames"
New-Item -ItemType Directory -Force -Path $framesDir | Out-Null
Say "결과 폴더: $outDir"

# ---- 영상 정보 (ffprobe) --------------------------------------------------------------------
$pr = Invoke-Tool $FFPROBE_EXE @("-v", "error", "-print_format", "json", "-show_format", "-show_streams", $src) $null
if ($pr.Code -ne 0) { Fail ("ffprobe 실패`n" + (Tail $pr.Err 800)) }
$probe = $pr.Out | ConvertFrom-Json
$vs = @($probe.streams | Where-Object { $_.codec_type -eq "video" }) | Select-Object -First 1
$as = @($probe.streams | Where-Object { $_.codec_type -eq "audio" }) | Select-Object -First 1
if (-not $vs) { Fail "영상 줄기를 찾지 못했습니다. 영상 파일이 맞는지 확인해 주세요." }
$dur = [double]::Parse([string]$probe.format.duration, $inv)
$fps = ""
if ($vs.avg_frame_rate -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) { $fps = [Math]::Round([double]$Matches[1] / [double]$Matches[2], 2) }
$audioCodec = $null; if ($as) { $audioCodec = [string]$as.codec_name }
$meta = [ordered]@{
    title = [string](Get-Opt $info "title" ([IO.Path]::GetFileNameWithoutExtension($src)))
    uploader = [string](Get-Opt $info "uploader" "")
    upload_date = [string](Get-Opt $info "upload_date" "")
    view_count = [string](Get-Opt $info "view_count" "")
    duration = $dur
    width = [int]$vs.width
    height = [int]$vs.height
    fps = $fps
    video_codec = [string]$vs.codec_name
    audio_codec = $audioCodec
}
if ($info) { Write-Utf8 (Join-Path $outDir "source-info.json") ($ir.Out) }

# ---- 컷 찾기 (화면 변화 점수) --------------------------------------------------------------------
Say "컷을 찾는 중..."
# 화면 틀(로고, 제목)이 고정이면 영상 칸만 잘라 비교해야 컷이 잡힙니다 (-VideoBox "왼쪽,위,너비,높이" 비율)
$sceneVf = "select='gt(scene,$(F $SceneThreshold))',showinfo"
if ($VideoBox) {
    $vb = @($VideoBox.Split(",") | ForEach-Object { [double]::Parse($_.Trim(), $inv) })
    if ($vb.Count -ne 4) { Fail "-VideoBox 는 '왼쪽,위,너비,높이'를 0~1 사이 비율로 적습니다. 예: 0,0.303,1,0.394" }
    $sceneVf = "crop=w=iw*$(F $vb[2]):h=ih*$(F $vb[3]):x=iw*$(F $vb[0]):y=ih*$(F $vb[1])," + $sceneVf
}
$sc = Run-FFmpeg @("-i", $src, "-vf", $sceneVf, "-an", "-f", "null", "-") "컷 찾기"
$times = New-Object System.Collections.ArrayList
[void]$times.Add(0.0)
foreach ($mm in [regex]::Matches($sc.Err, 'pts_time:([0-9.]+)')) {
    $tt = [double]::Parse($mm.Groups[1].Value, $inv)
    if (($tt - [double]$times[$times.Count - 1]) -ge 0.4 -and ($dur - $tt) -ge 0.4) { [void]$times.Add($tt) }
}
$cuts = @()
for ($i = 0; $i -lt $times.Count; $i++) {
    $s = [double]$times[$i]
    if ($i + 1 -lt $times.Count) { $e = [double]$times[$i + 1] } else { $e = $dur }
    $cuts += [ordered]@{ index = $i + 1; start = [Math]::Round($s, 3); end = [Math]::Round($e, 3); length = [Math]::Round($e - $s, 3); frame = ("frames/cut-{0:000}.jpg" -f ($i + 1)) }
}
Say ("컷 {0}개" -f $cuts.Count)

# 컷마다 첫 화면 (컷 시작 직후 한 장)
foreach ($c in $cuts) {
    $at = [double]$c.start + [Math]::Min(0.1, [double]$c.length / 2)
    [void](Run-FFmpeg @("-y", "-ss", (F $at), "-i", $src, "-frames:v", "1", "-vf", "scale=540:-2", "-q:v", "3", (Join-Path $outDir $c.frame)) "컷 $($c.index) 화면 저장")
}

# 컷 모음표 (컷 첫 화면을 한 장에 모음, 왼쪽 위부터 오른쪽으로 번호 순서)
$cols = [Math]::Min(8, $cuts.Count)
$rows = [Math]::Ceiling($cuts.Count / [double]$cols)
$seqPattern = Join-Path $framesDir "cut-%03d.jpg"
[void](Run-FFmpeg @("-y", "-framerate", "1", "-i", $seqPattern, "-vf", "scale=216:-2,tile=${cols}x${rows}:padding=4:margin=4:color=0x202020", "-frames:v", "1", "-q:v", "3", (Join-Path $outDir "contact-sheet.jpg")) "컷 모음표 만들기")

# 첫 화면 원본 크기
$tFirst = [Math]::Min(1.0, $dur / 2)
[void](Run-FFmpeg @("-y", "-ss", (F $tFirst), "-i", $src, "-frames:v", "1", (Join-Path $outDir "first-frame.png")) "첫 화면 저장")

# 제목 부분 (기본: 세로 영상은 위쪽 15%에서 14% 높이, 가로 영상은 아래쪽 25%)
$box = @(0.0, 0.15, 1.0, 0.14)
if ([double]$meta.width -ge [double]$meta.height) { $box = @(0.0, 0.70, 1.0, 0.25) }
if ($TitleBox) {
    $tb = @($TitleBox.Split(",") | ForEach-Object { [double]::Parse($_.Trim(), $inv) })
    if ($tb.Count -eq 4) { $box = $tb } else { Fail "-TitleBox 는 '왼쪽,위,너비,높이'를 0~1 사이 비율로 적습니다. 예: 0,0.15,1,0.14" }
}
$cropF = "crop=w=iw*$(F $box[2]):h=ih*$(F $box[3]):x=iw*$(F $box[0]):y=ih*$(F $box[1])"
[void](Run-FFmpeg @("-y", "-ss", (F $tFirst), "-i", $src, "-frames:v", "1", "-vf", $cropF, (Join-Path $outDir "title-crop.png")) "제목 부분 저장")

# ---- 소리 ---------------------------------------------------------------------------------
$loud = [ordered]@{ available = $false }
$files = [ordered]@{
    first_frame = "first-frame.png"; contact_sheet = "contact-sheet.jpg"; title_crop = "title-crop.png"
    audio_clip_wav = $null; audio_clip_mp3 = $null
}
if ($as) {
    Say "소리 크기를 재는 중..."
    $lr = Run-FFmpeg @("-i", $src, "-vn", "-af", "ebur128=peak=true", "-f", "null", "-") "소리 크기 재기"
    $iM = [regex]::Matches($lr.Err, 'I:\s+(-?[0-9.]+)\s+LUFS')
    $lM = [regex]::Matches($lr.Err, 'LRA:\s+([0-9.]+)\s+LU')
    $pM = [regex]::Matches($lr.Err, 'Peak:\s+(-?[0-9.]+)\s+dBFS')
    if ($iM.Count -gt 0) {
        $loud = [ordered]@{ available = $true; integrated_lufs = $iM[$iM.Count - 1].Groups[1].Value; lra = ""; peak_dbfs = "" }
        if ($lM.Count -gt 0) { $loud.lra = $lM[$lM.Count - 1].Groups[1].Value }
        if ($pM.Count -gt 0) { $loud.peak_dbfs = $pM[$pM.Count - 1].Groups[1].Value }
    }
    # 12초 소리 조각 (곡 찾기용)
    $cs0 = $ClipStart
    if ($cs0 -lt 0) { if ($dur -gt 17) { $cs0 = 3.0 } else { $cs0 = 0.0 } }
    $clipLen = [Math]::Min(12.0, $dur - $cs0)
    [void](Run-FFmpeg @("-y", "-ss", (F $cs0), "-t", (F $clipLen), "-i", $src, "-vn", "-ac", "1", "-ar", "44100", (Join-Path $outDir "audio-clip.wav")) "소리 조각(wav)")
    $files.audio_clip_wav = "audio-clip.wav"
    $mp3 = Invoke-Tool $script:FFMPEG_EXE @("-hide_banner", "-nostats", "-y", "-ss", (F $cs0), "-t", (F $clipLen), "-i", $src, "-vn", "-ac", "1", "-ar", "44100", "-c:a", "libmp3lame", "-q:a", "4", (Join-Path $outDir "audio-clip.mp3")) $null
    if ($mp3.Code -eq 0) { $files.audio_clip_mp3 = "audio-clip.mp3" }
}

# ---- 정리 파일 ----------------------------------------------------------------------------
$lens = @($cuts | ForEach-Object { [double]$_.length } | Sort-Object)
$median = $lens[[int][Math]::Floor($lens.Count / 2)]
if ($lens.Count % 2 -eq 0 -and $lens.Count -gt 1) { $median = ($lens[$lens.Count / 2 - 1] + $lens[$lens.Count / 2]) / 2 }
$stats = [ordered]@{ count = $cuts.Count; mean = [Math]::Round(($lens | Measure-Object -Average).Average, 3); median = [Math]::Round($median, 3); min = $lens[0]; max = $lens[$lens.Count - 1] }
$sourceUrl = $null; if ($isUrl) { $sourceUrl = $Source }
$analysis = [ordered]@{
    name = $slug; source_url = $sourceUrl; source_file = $src; scene_threshold = $SceneThreshold; video_box = $VideoBox
    meta = $meta; cuts = $cuts; cut_stats = $stats; loudness = $loud; files = $files
    title_crop_box = $box
}
Write-Utf8 (Join-Path $outDir "analysis.json") (Json $analysis)

$fpath = Join-Path $outDir "findings.json"
if (-not (Test-Path -LiteralPath $fpath)) {
    $blank = { param($label) [ordered]@{ label = $label; items = @([ordered]@{ what = ""; value = ""; evidence = @() }) } }
    $tpl = [ordered]@{
        title = $meta.title
        summary = ""
        groups = [ordered]@{
            frame = (& $blank "화면 틀"); visual = (& $blank "시각 자료"); text = (& $blank "글자 (제목, 자막)")
            sound = (& $blank "소리 (대사/나레이션, 배경 음악, 효과음)"); flow = (& $blank "흐름 (컷 길이, 순서)")
        }
        font = [ordered]@{ candidates = @([ordered]@{ name = ""; confidence = ""; why = "" }) }
        music = [ordered]@{ note = "" }
        questions = @(@("첫 장면이 관심을 끄는가?", "가장 먼저 보이는 것은 무엇인가?", "전환 속도가 내용과 맞는가?", "소리가 화면과 맞는가?", "자막이 핵심을 돕는가?", "끝나고 남는 메시지는 무엇인가?") | ForEach-Object { [ordered]@{ question = $_; answer = "" } })
    }
    Write-Utf8 $fpath (Json $tpl)
}

Say ""
Say "1단계 끝. 만든 것:"
Say "  $outDir"
Say "  analysis.json (측정값), contact-sheet.jpg (컷 모음표), frames/ (컷마다 첫 화면), first-frame.png, title-crop.png, audio-clip.*, findings.json (빈 틀)"
Say "다음: 사진을 보고 findings.json을 채운 뒤 -Report -Dir ""$outDir"" 로 보고서를 만듭니다."
