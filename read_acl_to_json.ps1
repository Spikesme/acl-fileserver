# Export-NTFS-ACLs-Interaktiv.ps1
# Interaktives Skript zum Auslesen von NTFS-Berechtigungen (kompatibel mit PS 5.1 und 7+)

Write-Host "NTFS-Berechtigungen Export (interaktiv)" -ForegroundColor Cyan
Write-Host "======================================" -ForegroundColor Cyan
Write-Host ""

# ────────────────────────────────────────────────
# 1. Pfad abfragen
# ────────────────────────────────────────────────
Write-Host "Welchen Ordner möchtest du auslesen?" -ForegroundColor Yellow
Write-Host "Beispiel: D:\Daten\AbteilungX" -ForegroundColor Gray

do {
    $rootPath = Read-Host "Pfad"
    $rootPath = $rootPath.Trim()

    if (-not $rootPath) {
        Write-Host "Pfad darf nicht leer sein." -ForegroundColor Red
        continue
    }

    if (-not (Test-Path $rootPath -PathType Container)) {
        Write-Host "Der angegebene Pfad existiert nicht oder ist kein Ordner." -ForegroundColor Red
        $rootPath = $null
        continue
    }

    # Netzwerkpfade normalisieren (falls UNC)
    $rootPath = Resolve-Path $rootPath | Select-Object -ExpandProperty Path

} while (-not $rootPath)

Write-Host "→ Ausgewählter Pfad: $rootPath" -ForegroundColor Green
Write-Host ""

# ────────────────────────────────────────────────
# 2. Ausgabedatei abfragen
# ────────────────────────────────────────────────
$defaultJsonName = "ACL-Export_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').json"

# Kompatibel mit PowerShell 5.1: Kein ternärer Operator
if ($PSScriptRoot) {
    $defaultFolder = $PSScriptRoot
} else {
    $defaultFolder = $PWD.Path
}

Write-Host "Wohin soll die JSON-Datei gespeichert werden?" -ForegroundColor Yellow
Write-Host "Nur Enter = $defaultFolder + $defaultJsonName" -ForegroundColor Gray
Write-Host "Beispiel: C:\Temp\mein-export.json" -ForegroundColor Gray

$outFile = Read-Host "Ausgabedatei (oder nur Enter)"

if (-not $outFile) {
    $outFile = Join-Path $defaultFolder $defaultJsonName
}
else {
    $outFile = $outFile.Trim()
    # Wenn nur Dateiname angegeben wurde → im default-Ordner
    if (-not [System.IO.Path]::IsPathRooted($outFile)) {
        $outFile = Join-Path $defaultFolder $outFile
    }
    # Endung .json erzwingen, falls vergessen
    if ([IO.Path]::GetExtension($outFile) -notin @('.json','.JSON')) {
        $outFile += ".json"
    }
}

# Ordner der Ausgabedatei erstellen, falls nicht existent
$outDir = Split-Path $outFile -Parent
if (-not (Test-Path $outDir)) {
    try {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
        Write-Host "Ausgabeordner wurde erstellt: $outDir" -ForegroundColor Green
    }
    catch {
        Write-Host "Konnte Ausgabeordner nicht erstellen: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

Write-Host "→ Ausgabedatei: $outFile" -ForegroundColor Green
Write-Host ""

# ────────────────────────────────────────────────
# 3. Dateien mit auslesen? (meist sehr viel Volumen)
# ────────────────────────────────────────────────
Write-Host "Sollen auch einzelne Dateien ausgelesen werden?" -ForegroundColor Yellow
Write-Host "(Nur Ordner = schneller & meist ausreichend)" -ForegroundColor Gray

$includeFilesRaw = Read-Host "Dateien mit auslesen? (j/n) [Standard: nein]"
$includeFiles = $includeFilesRaw -match '^(j|ja|y|yes|1)$'

Write-Host "→ Dateien werden " -NoNewline
if ($includeFiles) {
    Write-Host "MIT" -ForegroundColor Magenta -NoNewline
} else {
    Write-Host "NICHT" -ForegroundColor DarkGray -NoNewline
}
Write-Host " ausgelesen." -ForegroundColor White
Write-Host ""

# ────────────────────────────────────────────────
# 4. Optional: maximale Tiefe
# ────────────────────────────────────────────────
Write-Host "Maximale Rekursionstiefe? (0 = unbegrenzt)" -ForegroundColor Yellow
Write-Host "Empfehlung bei sehr großen Strukturen: 4–8" -ForegroundColor Gray

$depthInput = Read-Host "Tiefe [Standard: 0]"
if ($depthInput -match '^\d+$') {
    $maxDepth = [int]$depthInput
} else {
    $maxDepth = 0
}

if ($maxDepth -gt 0) {
    Write-Host "→ Maximale Tiefe: $maxDepth Ebenen" -ForegroundColor Green
} else {
    Write-Host "→ Keine Tiefenbegrenzung" -ForegroundColor Green
}
Write-Host ""

# ────────────────────────────────────────────────
# Zusammenfassung & Bestätigung
# ────────────────────────────────────────────────
Write-Host "Zusammenfassung:" -ForegroundColor Cyan
Write-Host "  Startordner     : $rootPath"
Write-Host "  Ausgabedatei    : $outFile"
Write-Host "  Dateien         : $(if($includeFiles){"Ja"}else{"Nein"})"
Write-Host "  Max. Tiefe      : $(if($maxDepth -gt 0){$maxDepth}else{"unbegrenzt"})"
Write-Host ""

$confirm = Read-Host "Starten? (Enter = ja / beliebige Taste + Enter = abbrechen)"
if ($confirm -ne "") {
    Write-Host "Abgebrochen." -ForegroundColor Yellow
    exit 0
}

# ────────────────────────────────────────────────
# Ab hier die eigentliche Arbeit
# ────────────────────────────────────────────────

Write-Host "`nStarte Export ... (das kann je nach Größe einige Minuten dauern)" -ForegroundColor Cyan

function Get-FormattedAccessRule {
    param($Ace)
    [PSCustomObject]@{
        Identity         = $Ace.IdentityReference.ToString()
        Rights           = $Ace.FileSystemRights.ToString()  # Einfacher String, lesbar genug
        Access           = $Ace.AccessControlType.ToString()
        Inherited        = $Ace.IsInherited
        InheritanceFlags = $Ace.InheritanceFlags.ToString()
        PropagationFlags = $Ace.PropagationFlags.ToString()
    }
}

$results = [System.Collections.Generic.List[PSObject]]::new()

# Root-Element
$items = @((Get-Item $rootPath -ErrorAction SilentlyContinue))

# Rekursiv Ordner
$folderParams = @{
    Path        = $rootPath
    Directory   = $true
    Recurse     = $true
    ErrorAction = 'SilentlyContinue'
}

if ($maxDepth -gt 0) {
    $folderParams.Depth = $maxDepth
}

$items += Get-ChildItem @folderParams

if ($includeFiles) {
    $fileParams = $folderParams.Clone()
    $fileParams.Remove('Directory')
    $fileParams['File'] = $true
    $items += Get-ChildItem @fileParams
}

$totalCount = $items.Count
$counter    = 0

foreach ($item in $items) {
    $counter++
    Write-Progress -Activity "Lese Berechtigungen" -Status "$counter / $totalCount" -PercentComplete (($counter / $totalCount) * 100)

    try {
        $acl = Get-Acl -Path $item.FullName -ErrorAction Stop

        $rules = $acl.Access | ForEach-Object { Get-FormattedAccessRule $_ }

        $entry = [PSCustomObject]@{
            Path           = $item.FullName.Replace($rootPath, '').TrimStart('\')
            FullPath       = $item.FullName
            Type           = if ($item.PSIsContainer) { "Ordner" } else { "Datei" }
            Owner          = $acl.Owner
            ExplicitCount  = ($rules | Where-Object { -not $_.Inherited }).Count
            InheritedCount = ($rules | Where-Object { $_.Inherited }).Count
            DenyCount      = ($rules | Where-Object { $_.Access -eq 'Deny' }).Count
            TotalRules     = $rules.Count
            Rules          = $rules
        }

        $results.Add($entry)
    }
    catch {
        Write-Warning "Problem bei $($item.FullName): $($_.Exception.Message)"
    }
}

Write-Progress -Activity "Lese Berechtigungen" -Completed

# Export
$results | ConvertTo-Json -Depth 8 -Compress | Out-File -FilePath $outFile -Encoding UTF8 -Force

Write-Host ""
Write-Host "Export abgeschlossen!" -ForegroundColor Green
Write-Host "Datei: $outFile"
Write-Host "Anzahl Einträge: $($results.Count)"
Write-Host ""