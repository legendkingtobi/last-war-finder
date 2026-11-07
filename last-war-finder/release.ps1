# Last War-Finder: neue Version bauen und als GitHub-Release veroeffentlichen (Fix 125, Fix 130)
# Aufruf:  .\release.ps1 1.0.6            (optional: -Notes "..." - Standard: KEIN Text)
# Ablauf:  Sprach-Pruefung -> APP_VERSION in PrivateOnlyNew.cpp + Version in Resource.rc setzen (byte-genau, Kodierung
#          bleibt) -> Sprach-Pruefung -> Release x64 bauen -> Sprach-Pruefung -> Release vX.Y.Z nur mit der .exe
#          hochladen -> pruefen -> alle aelteren Releases + Tags loeschen.
# Hochgeladen wird NUR die .exe, kein Quellcode, kein deutscher Text (Titel englisch, Beschreibung leer).
# Fix 130: Sprach-Schutz. Abbruch, wenn PrivateOnlyNew.cpp kein UTF-8 mit BOM ist, U+FFFD enthaelt, weniger
#          kyrillische/arabische/thailaendische/CJK/Kana/Hangul/vietnamesische/polnisch-tuerkische Zeichen hat als
#          PrivateOnlyNew.cpp.bak (saubere Referenz) oder ein nicht-ASCII-Text aus der Referenz fehlt.
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Version,
    [string]$Notes = ""
)
$ErrorActionPreference = 'Stop'
$Repo    = 'legendkingtobi/last-war-finder'
$Root    = $PSScriptRoot
$Cpp     = Join-Path $Root 'PrivateOnlyNew\PrivateOnlyNew.cpp'
$RefCpp  = Join-Path $Root 'PrivateOnlyNew\PrivateOnlyNew.cpp.bak'
$Rc      = Join-Path $Root 'PrivateOnlyNew\Resource.rc'
$Sln     = Join-Path $Root 'PrivateOnlyNew.slnx'
$Exe     = Join-Path $Root 'x64\Release\Last War-Finder.exe'
$MSBuild = 'C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe'
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')

$Version = $Version.TrimStart('v','V')
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version bitte als X.Y.Z angeben, z. B. 1.0.1" }
$Tag = "v$Version"
$parts = $Version.Split('.')

# ---------- Kodierung: strikt, ohne stille Ersetzung ----------
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)   # kein BOM beim GetBytes, Fehler bei kaputten Bytes
$latin1     = [Text.Encoding]::GetEncoding(28591)                   # nur fuer reine Bytes ohne BOM (1 Byte = 1 Zeichen)
function Read-Utf8Bom([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { throw "ABBRUCH: $Path ist nicht UTF-8 mit BOM" }
    return $utf8Strict.GetString($b, 3, $b.Length - 3)   # wirft bei ungueltigem UTF-8
}
function Write-Utf8Bom([string]$Path, [string]$Text) {
    $body = $utf8Strict.GetBytes($Text)
    $out = New-Object byte[] ($body.Length + 3)
    $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
    [Array]::Copy($body, 0, $out, 3, $body.Length)
    [IO.File]::WriteAllBytes($Path, $out)
}

# ---------- Fix 130: Sprach-Pruefung gegen die saubere Referenz ----------
$Scripts = [ordered]@{
    'Kyrillisch (ru)'      = @(0x0400, 0x04FF)
    'Arabisch (ar)'        = @(0x0600, 0x06FF)
    'Thai (th)'            = @(0x0E00, 0x0E7F)
    'CJK (zh/ja)'          = @(0x4E00, 0x9FFF)
    'Kana (ja)'            = @(0x3040, 0x30FF)
    'Hangul (ko)'          = @(0xAC00, 0xD7AF)
    'Latin Ext-A (tr/pl)'  = @(0x0100, 0x017F)
    'Latin Ext-Add (vi)'   = @(0x1E00, 0x1EFF)
    'Latin-1 (de/fr/es..)' = @(0x00C0, 0x00FF)
}
function Get-ScriptCounts([string]$t) {
    $c = [ordered]@{}; foreach ($k in $Scripts.Keys) { $c[$k] = 0 }
    foreach ($ch in $t.ToCharArray()) {
        $u = [int]$ch
        if ($u -lt 0xC0) { continue }
        foreach ($k in $Scripts.Keys) { if ($u -ge $Scripts[$k][0] -and $u -le $Scripts[$k][1]) { $c[$k]++; break } }
    }
    return $c
}
function Assert-Languages([string]$When) {
    if (-not (Test-Path $RefCpp)) { throw "ABBRUCH ($When): Referenz $RefCpp fehlt" }
    $ref = Read-Utf8Bom $RefCpp
    $cur = Read-Utf8Bom $Cpp
    if ($cur.Contains([string][char]0xFFFD)) { throw "ABBRUCH ($When): PrivateOnlyNew.cpp enthaelt U+FFFD (kaputte Zeichen)" }
    $cr = Get-ScriptCounts $ref; $cc = Get-ScriptCounts $cur
    foreach ($k in $Scripts.Keys) {
        if ($cc[$k] -lt $cr[$k]) { throw "ABBRUCH ($When): $k nur $($cc[$k]) Zeichen statt $($cr[$k]) wie in der Referenz" }
    }
    # Jeder String-Literal mit Nicht-ASCII-Zeichen aus der Referenz muss unveraendert vorhanden sein
    $rx = [regex]'(?:L|u8)?"(?:[^"\\\n]|\\.)*"'
    $missing = @()
    foreach ($m in $rx.Matches($ref)) {
        $v = $m.Value
        if ($v -match '[^\x00-\x7F]' -and -not $cur.Contains($v)) { $missing += $v }
    }
    if ($missing.Count -gt 0) { throw "ABBRUCH ($When): $($missing.Count) Sprach-Texte fehlen/kaputt, z. B. $($missing[0])" }
    Write-Host "Sprach-Pruefung OK ($When): BOM, kein U+FFFD, alle Schriften und Sprach-Texte vollstaendig" -ForegroundColor Green
}

Assert-Languages 'vorher'

# Tag darf es noch nicht geben
$existing = @(gh release list --repo $Repo --limit 100 --json tagName --jq '.[].tagName')
if ($LASTEXITCODE -ne 0) { throw "gh release list fehlgeschlagen (angemeldet? gh auth status)" }
if ($existing -contains $Tag) { throw "Release $Tag gibt es schon - bitte eine hoehere Version nehmen." }

# ---------- Version setzen (byte-genau bis auf die Versionsnummer) ----------
$cppText = Read-Utf8Bom $Cpp
if ($cppText -notmatch '#define APP_VERSION L"[^"]*"') { throw "APP_VERSION nicht gefunden in $Cpp" }
$cppNew = $cppText -replace '#define APP_VERSION L"[^"]*"', ('#define APP_VERSION L"' + $Version + '"')
if ($cppNew -ne $cppText) { Write-Utf8Bom $Cpp $cppNew }

# Resource.rc in ihrer eigenen Kodierung lassen (UTF-16 LE/BE oder UTF-8 mit BOM oder reine Bytes)
$rcBytes = [IO.File]::ReadAllBytes($Rc)
if     ($rcBytes.Length -ge 2 -and $rcBytes[0] -eq 0xFF -and $rcBytes[1] -eq 0xFE) { $rcEnc = New-Object System.Text.UnicodeEncoding($false, $false, $true); $pre = 2 }
elseif ($rcBytes.Length -ge 2 -and $rcBytes[0] -eq 0xFE -and $rcBytes[1] -eq 0xFF) { $rcEnc = New-Object System.Text.UnicodeEncoding($true,  $false, $true); $pre = 2 }
elseif ($rcBytes.Length -ge 3 -and $rcBytes[0] -eq 0xEF -and $rcBytes[1] -eq 0xBB -and $rcBytes[2] -eq 0xBF) { $rcEnc = $utf8Strict; $pre = 3 }
else   { $rcEnc = $latin1; $pre = 0 }
$rcText = $rcEnc.GetString($rcBytes, $pre, $rcBytes.Length - $pre)
$v4c = "$($parts[0]),$($parts[1]),$($parts[2]),0"
$v4d = "$Version.0"
$rcNew = $rcText -replace '(?m)^(\s*FILEVERSION\s+)[\d, ]+', ('${1}' + $v4c)
$rcNew = $rcNew -replace '(?m)^(\s*PRODUCTVERSION\s+)[\d, ]+', ('${1}' + $v4c)
$rcNew = $rcNew -replace '(VALUE "FileVersion",\s*")[^"]*', ('${1}' + $v4d)
$rcNew = $rcNew -replace '(VALUE "ProductVersion",\s*")[^"]*', ('${1}' + $v4d)
if ($rcNew -ne $rcText) {
    $body = $rcEnc.GetBytes($rcNew)
    $out = New-Object byte[] ($body.Length + $pre)
    [Array]::Copy($rcBytes, 0, $out, 0, $pre)
    [Array]::Copy($body, 0, $out, $pre, $body.Length)
    [IO.File]::WriteAllBytes($Rc, $out)
}
Write-Host "Version gesetzt: $Version" -ForegroundColor Green
Assert-Languages 'nach Versionsnummer'

# Bauen
& $MSBuild $Sln /t:Build /p:Configuration=Release /p:Platform=x64 /m /v:quiet /nologo /clp:ErrorsOnly
if ($LASTEXITCODE -ne 0) { throw "Build fehlgeschlagen" }
$fv = (Get-Item $Exe).VersionInfo.FileVersion
Write-Host "Gebaut: $Exe (FileVersion $fv)" -ForegroundColor Green
Assert-Languages 'vor dem Upload'

# Veroeffentlichen: englischer Titel, Beschreibung leer (leere Datei, damit nichts abgefragt wird)
$notesFile = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllBytes($notesFile, $utf8Strict.GetBytes($Notes))
    gh release create $Tag "$Exe#Last War-Finder.exe" --repo $Repo --title "Last War-Finder $Tag" --notes-file $notesFile --latest
    if ($LASTEXITCODE -ne 0) { throw "gh release create fehlgeschlagen - aeltere Releases bleiben unveraendert" }
} finally { Remove-Item $notesFile -ErrorAction SilentlyContinue }

# Pruefen, ob die neue Release mit der .exe wirklich da ist
$ok = $false
for ($i = 0; $i -lt 10 -and -not $ok; $i++) {
    $json = gh release view $Tag --repo $Repo --json tagName,isDraft,assets 2>$null
    if ($LASTEXITCODE -eq 0 -and $json) {
        $r = $json | ConvertFrom-Json
        $asset = @($r.assets | Where-Object { $_.name -like '*.exe' -and $_.state -eq 'uploaded' }) | Select-Object -First 1
        $latest = gh api "repos/$Repo/releases/latest" --jq '.tag_name' 2>$null
        if (-not $r.isDraft -and $asset -and $asset.size -eq (Get-Item $Exe).Length -and $latest -eq $Tag) { $ok = $true; break }
    }
    Start-Sleep -Seconds 2
}
if (-not $ok) { throw "Neue Release $Tag konnte nicht bestaetigt werden - aeltere Releases werden NICHT geloescht." }
Write-Host "Veroeffentlicht: $Tag, Datei '$($asset.name)' ($($asset.size) Bytes)" -ForegroundColor Green

# Aeltere Releases + Tags loeschen. Fix 240: die direkt vorherige Release bleibt stehen - laufende Programme, die sie schon
# gefunden haben (Knopf UPDATE), koennen sie sonst nicht mehr laden (404 -> 'Update failed'). Erst die uebernaechste Release loescht sie.
$all = @(gh release list --repo $Repo --limit 100 --json tagName --jq '.[].tagName')
$keepPrev = @($all | Where-Object { $_ -and $_ -ne $Tag }) | Select-Object -First 1
if ($keepPrev) { Write-Host "Vorherige Release bleibt: $keepPrev" }
foreach ($t in $all) {
    if ($t -and $t -ne $Tag -and $t -ne $keepPrev) {
        gh release delete $t --repo $Repo --cleanup-tag --yes
        if ($LASTEXITCODE -eq 0) { Write-Host "Alte Release geloescht: $t" } else { Write-Warning "Konnte $t nicht loeschen" }
    }
}
Assert-Languages 'nach dem Upload'
Write-Host "Fertig. https://github.com/$Repo/releases/tag/$Tag" -ForegroundColor Green
