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
#   report.html 의 모양은 assets\report-template.html 한 파일이 정합니다(정본). 이 스크립트는 값을 채우기만 합니다.
#   - 자리 표시자 {{이름}} 은 한 번만 나오는 값, <!-- BEGIN:이름 --> ... <!-- END:이름 --> 은 행마다 되풀이하는 블록입니다.
#   - 사용자 글(findings.json 등)은 모두 Esc 로 HTML 이스케이프한 뒤 채웁니다.
# =========================================================================================
# 중괄호까지 바꿔서, 사용자 글 안의 "{{x}}" 가 자리 표시자로 오해되지 않게 한다
function Esc([string]$s) {
    if ($null -eq $s) { return "" }
    return ([Net.WebUtility]::HtmlEncode($s)).Replace("{", "&#123;")
}

function N2($v) { return ([double]$v).ToString("0.00", $inv) }

# 스크립트가 채우는 모든 이름. 템플릿에 하나라도 없으면 오류로 멈춘다(템플릿이 망가졌다는 뜻).
$script:REPORT_NAMES = @(
    "title", "summary", "first_frame", "contact_sheet", "title_crop", "cut_summary", "lufs", "lra", "peak", "clip_src", "music_note",
    "label", "value", "what", "ev", "index", "start", "end", "length", "cut_frame", "duration", "name", "confidence", "why", "question", "answer",
    "summary_block", "meta_rows", "ev_image", "ev_audio", "ev_tag", "cut_rows", "sound_measured", "sound_unavailable",
    "silence_has", "silence_rows", "silence_none", "clip_audio", "music_note_block", "font_rows", "font_empty",
    "license_rows", "question_rows", "answer_given", "answer_missing",
    "items_frame", "items_visual", "items_text", "items_speech", "items_music", "items_sfx", "items_cuts",
    "items_frame_empty", "items_visual_empty", "items_text_empty", "items_speech_empty", "items_music_empty", "items_sfx_empty", "items_cuts_empty"
)

# 보고서에 꼭 있어야 하는 섹션: id 와 h2 제목
$script:REPORT_SECTIONS = @(
    @("info", "영상 정보"), @("frame", "1. 화면 틀"), @("visual", "2. 시각 요소"), @("text", "3. 글자 (제목 글자, 자막)"),
    @("speech", "4. 말소리 (대사, 나레이션)"), @("bgm", "5. 배경 음악"), @("sfx", "6. 효과음"),
    @("cuts", "컷과 편집점 (분석에 쓰는 말)"), @("font", "폰트 찾기"), @("music", "곡 찾기"), @("ask", "볼 때 묻는 질문")
)

function New-List { return , (New-Object System.Collections.ArrayList) }

# 값 찾기: 안쪽 행부터 바깥쪽 순서로 찾는다. 없으면 $null. 목록(블록 행)은 그대로 돌려준다.
function Find-Key([string]$name, [object[]]$chain) {
    foreach ($h in $chain) {
        if ($h.ContainsKey($name)) {
            $v = $h[$name]
            if ($v -is [System.Collections.IList]) { return , $v }
            return $v
        }
    }
    return $null
}

function Fill-Scalars([string]$text, [object[]]$chain) {
    $sb = New-Object Text.StringBuilder
    $pos = 0
    foreach ($m in [regex]::Matches($text, '\{\{(\w+)\}\}')) {
        [void]$sb.Append($text.Substring($pos, $m.Index - $pos))
        $v = Find-Key $m.Groups[1].Value $chain
        if ($v -is [string]) { [void]$sb.Append($v) } else { [void]$sb.Append($m.Value) }   # 모르는 자리는 그대로 두고, 마지막 점검에서 잡는다
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append($text.Substring($pos))
    return $sb.ToString()
}

function Expand-Tpl([string]$text, [object[]]$chain) {
    $sb = New-Object Text.StringBuilder
    $pos = 0
    foreach ($m in [regex]::Matches($text, '<!-- BEGIN:(\w+) -->(.*?)<!-- END:\1 -->', [Text.RegularExpressions.RegexOptions]::Singleline)) {
        [void]$sb.Append((Fill-Scalars $text.Substring($pos, $m.Index - $pos) $chain))
        $rows = Find-Key $m.Groups[1].Value $chain
        if ($rows -is [System.Collections.IList]) {
            foreach ($r in $rows) { [void]$sb.Append((Expand-Tpl $m.Groups[2].Value (@($r) + $chain))) }
        } else { [void]$sb.Append($m.Value) }   # 모르는 블록은 그대로 두고, 마지막 점검에서 잡는다
        $pos = $m.Index + $m.Length
    }
    [void]$sb.Append((Fill-Scalars $text.Substring($pos) $chain))
    return $sb.ToString()
}

# 요소별 항목 표의 행 목록: 한 행 = what, value, 근거(ev_image / ev_audio / ev_tag)
function Item-Rows($group) {
    $rows = New-List
    if ($null -eq $group) { return , $rows }
    foreach ($it in @(Get-Opt $group "items" @())) {
        $what = [string](Get-Opt $it "what" ""); $value = [string](Get-Opt $it "value" "")
        if (-not $what -and -not $value) { continue }
        $img = New-List; $aud = New-List; $tag = New-List
        foreach ($e in @(Get-Opt $it "evidence" @())) {
            $e = [string]$e
            if (-not $e) { continue }
            # 바깥 주소(http:, javascript: 등)는 링크로 만들지 않고 글자로만 보여 준다. 근거는 결과 폴더 안의 상대 경로만 쓴다.
            $isLocal = ($e -match '^[A-Za-z0-9_\-./\uAC00-\uD7A3]+\z') -and ($e -notmatch '\.\.') -and ($e -notmatch '^[\\/]')  # 허용 목록: 공백, 제어 문자, 쌍점(주소 형식)이 든 값은 링크로 만들지 않는다
            if ($isLocal -and $e -match '\.(jpg|jpeg|png|gif)$') { [void]$img.Add(@{ ev = (Esc $e) }) }
            elseif ($isLocal -and $e -match '\.(mp3|wav)$') { [void]$aud.Add(@{ ev = (Esc $e) }) }
            else { [void]$tag.Add(@{ ev = (Esc $e) }) }
        }
        [void]$rows.Add(@{ what = (Esc $what); value = (Esc $value); ev_image = $img; ev_audio = $aud; ev_tag = $tag })
    }
    return , $rows
}

function Build-Report([string]$dir) {
    # ---- 템플릿 읽기 (정본은 템플릿 하나) ----
    $tplPath = [IO.Path]::Combine((Split-Path -Parent $PSScriptRoot), "assets", "report-template.html")
    if (-not (Test-Path -LiteralPath $tplPath)) {
        Fail "보고서 틀 파일을 찾지 못했습니다: $tplPath`n스킬 폴더(kaist-shorts-analyze)의 assets 폴더에 report-template.html 이 있어야 합니다. 폴더를 통째로 다시 받아 주세요."
    }
    $tpl = [IO.File]::ReadAllText($tplPath, [Text.Encoding]::UTF8)
    $tpl = [regex]::Replace($tpl, '^\s*<!-- report-template.*?-->\s*', '', [Text.RegularExpressions.RegexOptions]::Singleline)   # 맨 위 설명 주석은 보고서에 넣지 않는다

    # 템플릿에 스크립트가 채우는 자리가 모두 있는지 (하나라도 지워졌으면 멈춘다)
    $found = @{}
    foreach ($m in [regex]::Matches($tpl, '\{\{(\w+)\}\}')) { $found[$m.Groups[1].Value] = $true }
    foreach ($m in [regex]::Matches($tpl, '<!-- BEGIN:(\w+) -->')) { $found[$m.Groups[1].Value] = $true }
    $gone = @($script:REPORT_NAMES | Where-Object { -not $found.ContainsKey($_) })
    if ($gone.Count -gt 0) {
        Fail ("보고서 틀(report-template.html)에서 꼭 필요한 자리가 빠졌습니다: " + (($gone | ForEach-Object { $_ }) -join ", ") + "`n틀 파일을 직접 고친 경우 빠진 자리를 되살려 주세요. 파일: $tplPath")
    }

    # ---- 값 모으기 ----
    $a = Get-Content -LiteralPath (Join-Path $dir "analysis.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $fp = Join-Path $dir "findings.json"
    $fd = $null
    if (Test-Path -LiteralPath $fp) { $fd = Get-Content -LiteralPath $fp -Raw -Encoding UTF8 | ConvertFrom-Json }
    $g = Get-Opt $fd "groups" $null
    $title = [string](Get-Opt $fd "title" "")
    if (-not $title) { $title = [string](Get-Opt $a.meta "title" $a.name) }
    $summary = [string](Get-Opt $fd "summary" "")
    $m = $a.meta

    $ctx = @{}
    $ctx.title = Esc $title
    $ctx.first_frame = Esc ([string]$a.files.first_frame)
    $ctx.contact_sheet = Esc ([string]$a.files.contact_sheet)
    $ctx.title_crop = Esc ([string]$a.files.title_crop)

    $sb = New-List
    if ($summary) { [void]$sb.Add(@{ summary = (Esc $summary) }) }
    $ctx.summary_block = $sb

    # 영상 정보 표
    $metaRows = @(
        @("제목", (Get-Opt $m "title" "")), @("올린 곳", (Get-Opt $m "uploader" "")), @("올린 날", (Get-Opt $m "upload_date" "")),
        @("조회수", (Get-Opt $m "view_count" "")), @("길이", ("{0}초" -f ([double]$m.duration).ToString("0.0", $inv))),
        @("화면 크기", ("{0} x {1}" -f $m.width, $m.height)), @("프레임 수(초당)", (Get-Opt $m "fps" "")),
        @("영상/소리 방식", ("{0} / {1}" -f (Get-Opt $m "video_codec" "-"), (Get-Opt $m "audio_codec" "소리 없음"))),
        @("원본 주소", (Get-Opt $a "source_url" "(내 컴퓨터의 파일)"))
    )
    $ml = New-List
    foreach ($r in $metaRows) { if ("$($r[1])" -ne "") { [void]$ml.Add(@{ label = (Esc ([string]$r[0])); value = (Esc ([string]$r[1])) }) } }
    $ctx.meta_rows = $ml

    # 요소별 항목 표 (6요소 + 컷과 편집점)
    foreach ($k in @("frame", "visual", "text", "speech", "music", "sfx", "cuts")) {
        $rows = Item-Rows (Get-Opt $g $k $null)
        $ctx["items_$k"] = $rows
        $empty = New-List
        if ($rows.Count -eq 0) { [void]$empty.Add(@{}) }
        $ctx["items_${k}_empty"] = $empty
    }

    # 컷 표
    $cl = New-List
    foreach ($c in @($a.cuts)) {
        [void]$cl.Add(@{ index = (Esc ([string]$c.index)); start = (N2 $c.start); end = (N2 $c.end); length = (N2 $c.length); cut_frame = (Esc ([string]$c.frame)) })
    }
    $ctx.cut_rows = $cl
    $cs = $a.cut_stats
    $ctx.cut_summary = Esc ("컷 $($cs.count)개, 평균 $(N2 $cs.mean)초, 가운데 값 $(N2 $cs.median)초, 가장 짧은 컷 $(N2 $cs.min)초, 가장 긴 컷 $(N2 $cs.max)초")

    # 소리 측정: 말소리, 배경 음악, 효과음이 한데 섞인 값이다
    $lo = $a.loudness
    $sm = New-List; $su = New-List
    if ($lo -and $lo.available) {
        $sil = New-List
        foreach ($sl in @(Get-Opt $lo "silences" @())) { [void]$sil.Add(@{ start = (N2 $sl.start); end = (N2 $sl.end); duration = ([double]$sl.duration).ToString("0.0", $inv) }) }
        $silHas = New-List; $silNone = New-List
        if ($sil.Count -gt 0) { [void]$silHas.Add(@{}) } else { [void]$silNone.Add(@{}) }
        [void]$sm.Add(@{ lufs = (Esc ([string]$lo.integrated_lufs)); lra = (Esc ([string]$lo.lra)); peak = (Esc ([string]$lo.peak_dbfs)); silence_has = $silHas; silence_rows = $sil; silence_none = $silNone })
    } else { [void]$su.Add(@{}) }
    $ctx.sound_measured = $sm
    $ctx.sound_unavailable = $su

    $clip = New-List
    $clipSrc = ""
    if (Get-Opt $a.files "audio_clip_mp3" $null) { $clipSrc = [string]$a.files.audio_clip_mp3 }
    elseif (Get-Opt $a.files "audio_clip_wav" $null) { $clipSrc = [string]$a.files.audio_clip_wav }
    if ($clipSrc) { [void]$clip.Add(@{ clip_src = (Esc $clipSrc) }) }
    $ctx.clip_audio = $clip

    # 폰트 후보
    $fl = New-List
    foreach ($c in @(Get-Opt (Get-Opt $fd "font" $null) "candidates" @())) {
        $nm = [string](Get-Opt $c "name" "")
        if ($nm) { [void]$fl.Add(@{ name = (Esc $nm); confidence = (Esc ([string](Get-Opt $c "confidence" ""))); why = (Esc ([string](Get-Opt $c "why" ""))) }) }
    }
    $ctx.font_rows = $fl
    $fe = New-List
    if ($fl.Count -eq 0) { [void]$fe.Add(@{}) }
    $ctx.font_empty = $fe

    # 곡 찾기 메모, 라이선스 기록 표(빈 줄 3개)
    $musicNote = [string](Get-Opt (Get-Opt $fd "music_search" $null) "note" "")
    if (-not $musicNote) { $musicNote = [string](Get-Opt (Get-Opt $fd "music" $null) "note" "") }
    $mn = New-List
    if ($musicNote) { [void]$mn.Add(@{ music_note = (Esc $musicNote) }) }
    $ctx.music_note_block = $mn
    $lic = New-List
    for ($li = 0; $li -lt 3; $li++) { [void]$lic.Add(@{}) }
    $ctx.license_rows = $lic

    # 볼 때 묻는 질문 (여섯 가지 고정)
    $qs = @("첫 장면이 관심을 끄는가?", "가장 먼저 보이는 것은 무엇인가?", "컷이 바뀌는 속도가 내용과 맞는가?", "소리가 화면과 맞는가?", "자막이 핵심을 돕는가?", "끝나고 남는 메시지는 무엇인가?")
    $ans = @(Get-Opt $fd "questions" @())
    $ql = New-List
    for ($qi = 0; $qi -lt $qs.Count; $qi++) {
        $a1 = ""
        if ($qi -lt $ans.Count) { $a1 = [string](Get-Opt $ans[$qi] "answer" "") }
        $given = New-List; $missing = New-List
        if ($a1) { [void]$given.Add(@{ answer = (Esc $a1) }) } else { [void]$missing.Add(@{}) }
        [void]$ql.Add(@{ question = (Esc $qs[$qi]); answer_given = $given; answer_missing = $missing })
    }
    $ctx.question_rows = $ql

    # ---- 채우기 ----
    $html = Expand-Tpl $tpl @($ctx)

    # 남은 자리 점검: 채우지 못한 {{...}} 나 블록 표시가 있으면 어느 자리인지 알려 주고 멈춘다
    $left = New-List
    foreach ($m2 in [regex]::Matches($html, '\{\{[^}\r\n]*\}\}|<!-- (?:BEGIN|END):\w+ -->|\{\{')) {
        $before = $html.Substring(0, $m2.Index)
        $line = ($before.Split("`n")).Count
        $sec = "머리말"
        $sm2 = [regex]::Matches($before, 'id="(\w+)"')
        if ($sm2.Count -gt 0) { $sec = $sm2[$sm2.Count - 1].Groups[1].Value }
        [void]$left.Add("  $($m2.Value)  (구역 $sec, 완성본 $line 번째 줄 근처)")
    }
    if ($left.Count -gt 0) {
        Fail ("보고서 틀(report-template.html)에 채우지 못한 자리가 있습니다. 자리 이름의 철자를 확인하거나 틀을 원래대로 되돌려 주세요.`n" + (($left.ToArray()) -join "`n") + "`n파일: $tplPath")
    }

    # 점검: 모든 섹션이 있는지 (id 와 h2 제목). 빠졌으면 report.html 을 만들지 않고 멈춘다.
    $out = Join-Path $dir "report.html"
    $lack = New-List
    foreach ($s in $script:REPORT_SECTIONS) {
        $okId = $html.Contains("id=""$($s[0])""")
        $okH2 = $html.Contains("<h2>$($s[1])</h2>")
        if (-not ($okId -and $okH2)) { [void]$lack.Add("$($s[1]) (id=$($s[0]))") }
    }
    if ($lack.Count -gt 0) {
        Fail ("보고서에 빠진 구역이 있습니다: " + (($lack.ToArray()) -join ", ") + "`n틀(report-template.html)에서 해당 구역이 지워졌는지 확인해 주세요. report.html 은 만들지 않았습니다.")
    }
    Write-Utf8 $out $html
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
    $lr = Run-FFmpeg @("-i", $src, "-vn", "-af", "ebur128=peak=true,silencedetect=n=-50dB:d=0.5", "-f", "null", "-") "소리 크기 재기"
    $iM = [regex]::Matches($lr.Err, 'I:\s+(-?[0-9.]+)\s+LUFS')
    $lM = [regex]::Matches($lr.Err, 'LRA:\s+([0-9.]+)\s+LU')
    $pM = [regex]::Matches($lr.Err, 'Peak:\s+(-?[0-9.]+)\s+dBFS')
    if ($iM.Count -gt 0) {
        $loud = [ordered]@{ available = $true; integrated_lufs = $iM[$iM.Count - 1].Groups[1].Value; lra = ""; peak_dbfs = "" }
        if ($lM.Count -gt 0) { $loud.lra = $lM[$lM.Count - 1].Groups[1].Value }
        if ($pM.Count -gt 0) { $loud.peak_dbfs = $pM[$pM.Count - 1].Groups[1].Value }
    }
    # 소리가 거의 없는 구간(-50 dB 아래로 0.5초 이상). 말소리, 배경 음악, 효과음이 모두 없는 구간이다.
    $silences = @()
    $openStart = $null
    foreach ($ln in ($lr.Err -split "\r?\n")) {
        $ms = [regex]::Match($ln, 'silence_start:\s*(-?[0-9.]+)')
        if ($ms.Success) { $openStart = [Math]::Max(0.0, [double]::Parse($ms.Groups[1].Value, $inv)); continue }
        $me = [regex]::Match($ln, 'silence_end:\s*(-?[0-9.]+)\s*\|\s*silence_duration:\s*([0-9.]+)')
        if ($me.Success -and $null -ne $openStart) {
            $silences += [ordered]@{ start = [Math]::Round($openStart, 2); end = [Math]::Round([double]::Parse($me.Groups[1].Value, $inv), 2); duration = [Math]::Round([double]::Parse($me.Groups[2].Value, $inv), 2) }
            $openStart = $null
        }
    }
    if ($null -ne $openStart) { $silences += [ordered]@{ start = [Math]::Round($openStart, 2); end = [Math]::Round($dur, 2); duration = [Math]::Round($dur - $openStart, 2) } }
    $loud.silences = $silences
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
            frame = (& $blank "화면 틀"); visual = (& $blank "시각 요소"); text = (& $blank "글자 (제목 글자, 자막)")
            speech = (& $blank "말소리 (대사, 나레이션)"); music = (& $blank "배경 음악"); sfx = (& $blank "효과음")
            cuts = (& $blank "컷과 편집점 (분석에 쓰는 말)")
        }
        font = [ordered]@{ candidates = @([ordered]@{ name = ""; confidence = ""; why = "" }) }
        music_search = [ordered]@{ note = "" }
        questions = @(@("첫 장면이 관심을 끄는가?", "가장 먼저 보이는 것은 무엇인가?", "컷이 바뀌는 속도가 내용과 맞는가?", "소리가 화면과 맞는가?", "자막이 핵심을 돕는가?", "끝나고 남는 메시지는 무엇인가?") | ForEach-Object { [ordered]@{ question = $_; answer = "" } })
    }
    Write-Utf8 $fpath (Json $tpl)
}

Say ""
Say "1단계 끝. 만든 것:"
Say "  $outDir"
Say "  analysis.json (측정값), contact-sheet.jpg (컷 모음표), frames/ (컷마다 첫 화면), first-frame.png, title-crop.png, audio-clip.*, findings.json (빈 틀)"
Say "다음: 사진을 보고 findings.json을 채운 뒤 -Report -Dir ""$outDir"" 로 보고서를 만듭니다."
