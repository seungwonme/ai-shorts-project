# 공용 함수 (collect-video.ps1, collect-article.ps1, typecast.ps1이 불러 씁니다). UTF-8 BOM으로 저장합니다.
$ErrorActionPreference = "Stop"
$inv = [Globalization.CultureInfo]::InvariantCulture
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$utf8 = New-Object Text.UTF8Encoding($false)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

function F([double]$n) { return $n.ToString("0.###", $inv) }
function Say([string]$msg) { Write-Host $msg }
function Fail([string]$msg) { throw $msg }
function Tail([string]$s, [int]$n) { if ($s.Length -gt $n) { return $s.Substring($s.Length - $n) } return $s }
function Write-Utf8([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, $utf8) }
function Get-Opt($obj, [string]$name, $default) {
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value) { return $p.Value }
    return $default
}

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

# 프로젝트 폴더 = "재료" 폴더가 있는 가장 가까운 윗 폴더 (현재 폴더에서 먼저, 없으면 스크립트 위치에서)
function Find-ProjectRoot {
    foreach ($start in @((Get-Location).Path, $PSScriptRoot)) {
        for ($d = $start; $d; $d = Split-Path -Parent $d) {
            if (Test-Path -LiteralPath (Join-Path $d "재료") -PathType Container) { return $d }
        }
    }
    return (Get-Location).Path
}

# 파일 이름으로 쓸 수 있게 다듬는다
function Safe-Name([string]$s, [int]$max) {
    $t = ($s -replace '[\\/:*?"<>|\s]+', '-').Trim("-")
    if ($t.Length -gt $max) { $t = $t.Substring(0, $max) }
    return $t
}

# 비밀 값(API 키)을 내 계정만 읽을 수 있는 파일에 저장한다. 순서가 중요하다:
# 폴더 권한 제한 -> 빈 파일 만들기 -> 파일 권한 제한 -> 그 다음에야 값을 쓴다.
# 권한 제한이 하나라도 실패하면 파일을 지우고 멈춘다(값은 쓰지 않는다).
function Save-SecretFile([string]$dir, [string]$file, [string]$value) {
    $win = ($env:OS -eq "Windows_NT")
    $failMsg = "키 파일을 내 계정만 읽도록 제한하지 못해 저장하지 않았습니다. 이 컴퓨터의 보안 설정을 확인해 주세요."
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    try {
        if ($win) {
            $grant = ($env:USERNAME + ":(OI)(CI)F")
            $r = Invoke-Tool "icacls.exe" @($dir, "/inheritance:r", "/grant:r", $grant) $null
            if ($r.Code -ne 0) { throw "icacls dir $($r.Code)" }
        } else {
            $r = Invoke-Tool "chmod" @("700", $dir) $null
            if ($r.Code -ne 0) { throw "chmod dir $($r.Code)" }
        }
        # 빈 파일을 먼저 만든다 (값은 아직 쓰지 않는다)
        [IO.File]::WriteAllBytes($file, (New-Object byte[] 0))
        if ($win) {
            $grantF = ($env:USERNAME + ":F")
            $r = Invoke-Tool "icacls.exe" @($file, "/inheritance:r", "/grant:r", $grantF) $null
            if ($r.Code -ne 0) { throw "icacls file $($r.Code)" }
        } else {
            $r = Invoke-Tool "chmod" @("600", $file) $null
            if ($r.Code -ne 0) { throw "chmod file $($r.Code)" }
        }
    } catch {
        try { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } } catch { }
        Fail $failMsg
    }
    Write-Utf8 $file $value
}

# ---- API 키 읽기 -------------------------------------------------------------------------------
# 우선순위: 환경 변수 > 프로젝트 폴더의 .env > 예전 키 파일(-SetupKey 로 만든 파일).
# 키 값은 화면, 로그, 오류 메시지에 절대 내보내지 않는다. (어디서 읽었는지만 말한다.)

# 한 줄의 "=" 뒤쪽을 값으로 다듬는다. 줄 끝 주석(`KEY=값  # 설명`, agents-env 가 `KEY="값" # 태그`로 쓴다)을 허용한다.
#  - 따옴표(" 또는 ')로 시작하면 짝이 되는 따옴표까지가 값이다. 따옴표 안의 # 은 값의 일부다.
#    닫는 따옴표 뒤에는 비어 있거나 공백 + # 주석만 올 수 있다. 그 밖의 글자가 붙어 있으면 따옴표 처리를 하지 않고 줄 전체를 값으로 돌려준다(공백이 있으면 뒤에서 거절된다).
#  - 따옴표가 없으면 공백(또는 탭) 바로 뒤의 # 부터가 주석이다. 공백 없이 붙은 # 은 값의 일부다.
# 값 안에 공백이 있으면 여기서는 그대로 돌려주고, Get-ApiKey 가 키로 인정하지 않는다.
function Split-EnvValue([string]$raw) {
    if ($raw -match '^[ \t]+#') { return "" }   # KEY= # 주석만 있는 줄은 빈 값
    $t = $raw.Trim()
    if ($t.Length -ge 1 -and ($t[0] -eq [char]34 -or $t[0] -eq [char]39)) {
        $q = $t[0]
        $end = $t.IndexOf($q, 1)
        if ($end -ge 1) {
            $rest = $t.Substring($end + 1)
            if ($rest.Trim() -eq "" -or $rest -match '^[ \t]+#') { return $t.Substring(1, $end - 1).Trim() }
        }
        return $t
    }
    $c = [regex]::Match($t, '[ \t]#')
    if ($c.Success) { $t = $t.Substring(0, $c.Index).TrimEnd() }
    return $t
}

# .env 를 KEY=VALUE 로 읽는다. 주석(#), 빈 줄, export 접두사, 따옴표, 앞뒤 공백, BOM, CRLF 를 처리한다.
# 한 줄에 값 하나만 본다(여러 줄 값은 지원하지 않는다). 같은 이름이 또 나오면 마지막 것을 쓴다.
function Read-EnvFile([string]$path) {
    $map = @{}
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
    $text = $utf8.GetString([IO.File]::ReadAllBytes($path)).TrimStart([char]0xFEFF)
    foreach ($raw in ($text -split "`r`n|`n|`r")) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $line = $line -replace '^export\s+', ''
        $m = [regex]::Match($line, '^([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$')
        if (-not $m.Success) { continue }
        $v = Split-EnvValue $m.Groups[2].Value
        $map[$m.Groups[1].Value] = $v
    }
    return $map
}

# 결과: Value(키, 없으면 $null), Source("환경 변수" / ".env" / "키 파일"), Problem(한국어 문제 설명 또는 $null), EmptyInEnv(.env 에 줄은 있는데 값이 빔)
function Get-ApiKey([string]$name, [string]$legacyFile) {
    $r = New-Object psobject -Property @{ Value = $null; Source = $null; Problem = $null; EmptyInEnv = $false }
    $ev = [Environment]::GetEnvironmentVariable($name)
    if ($ev -and $ev.Trim()) { $r.Value = $ev.Trim(); $r.Source = "환경 변수" }
    if (-not $r.Value) {
        $map = Read-EnvFile (Join-Path (Find-ProjectRoot) ".env")
        if ($map.ContainsKey($name)) {
            if ($map[$name]) { $r.Value = $map[$name]; $r.Source = ".env" } else { $r.EmptyInEnv = $true }
        }
    }
    if (-not $r.Value -and $legacyFile -and (Test-Path -LiteralPath $legacyFile)) {
        $t = (Get-Content -LiteralPath $legacyFile -Raw -Encoding UTF8)
        if ($t -and $t.Trim()) { $r.Value = $t.Trim(); $r.Source = "키 파일" }
    }
    # 키는 보이는 영문, 숫자, 기호 한 덩어리다. 공백, 줄바꿈, 한글이 섞이면 잘못 붙여 넣은 것이다.
    if ($r.Value -and $r.Value -notmatch '^[\x21-\x7E]+$') {
        $r.Problem = "$($r.Source)의 키에 공백, 줄바꿈, 한글 같은 글자가 섞여 있습니다. 키 전체만 = 바로 뒤에 붙여 넣었는지 확인해 주세요. (키 값은 화면에 보여 주지 않습니다.)"
        $r.Value = $null
    }
    return $r
}

# 키가 없을 때 사용자에게 보여 줄 한 문장 (값은 들어 있지 않다)
function Key-Missing([object]$r, [string]$service) {
    if ($r.Problem) { return $r.Problem }
    if ($r.EmptyInEnv) { return "$service 키가 비어 있음: 키-입력.bat 으로 .env에 붙여 넣으세요." }
    return "$service 키가 없습니다: 키-입력.bat 으로 .env에 붙여 넣으세요."
}
