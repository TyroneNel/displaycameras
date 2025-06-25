# PowerShell script to convert line endings to Unix format (LF)
# Define paths to exclude
$excludeDirs = @(
    "\.git\",
    "\node_modules\",
    "\.vs\",
    "\bin\",
    "\obj\"
)

# Define file extensions to exclude
$excludeExtensions = @(
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".svg", ".woff", ".woff2", ".ttf", ".eot",
    ".zip", ".7z", ".rar", ".tar", ".gz", ".dll", ".exe", ".pdb", ".suo", ".user", ".cache",
    ".snk", ".pfx", ".cer", ".p12", ".p7b", ".p7c", ".pem", ".crt", ".key", ".pfx", ".der"
)

# Define files to exclude by name
$excludeFiles = @(
    "fix_line_endings.ps1"
)

# Get all files recursively, excluding directories and files specified above
$files = Get-ChildItem -Path . -Recurse -File | Where-Object {
    $filePath = $_.FullName
    $fileName = $_.Name
    $fileExt = $_.Extension
    
    # Skip files in excluded directories
    $inExcludedDir = $excludeDirs | Where-Object { $filePath -match [regex]::Escape($_) }
    if ($inExcludedDir) { return $false }
    
    # Skip excluded extensions
    if ($excludeExtensions -contains $fileExt.ToLower()) { return $false }
    
    # Skip excluded file names
    if ($excludeFiles -contains $fileName) { return $false }
    
    return $true
}

$totalFiles = $files.Count
$convertedCount = 0
$skippedCount = 0

Write-Host "Checking $totalFiles files for Windows line endings..." -ForegroundColor Cyan

foreach ($file in $files) {
    try {
        # Read file content as raw text
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction Stop
        
        # Check if file contains Windows line endings
        if ($content -match "`r`n") {
            # Replace Windows line endings (CRLF) with Unix line endings (LF)
            $newContent = $content -replace "`r`n", "`n"
            
            # Preserve original encoding if possible
            $encoding = [System.Text.Encoding]::UTF8
            $fileBytes = [System.IO.File]::ReadAllBytes($file.FullName)
            
            # Try to detect encoding
            if ($fileBytes[0] -eq 0xEF -and $fileBytes[1] -eq 0xBB -and $fileBytes[2] -eq 0xBF) {
                $encoding = [System.Text.Encoding]::UTF8  # UTF-8 with BOM
            }
            elseif ($fileBytes[0] -eq 0xFF -and $fileBytes[1] -eq 0xFE) {
                $encoding = [System.Text.Encoding]::Unicode  # UTF-16 LE
            }
            elseif ($fileBytes[0] -eq 0xFE -and $fileBytes[1] -eq 0xFF) {
                $encoding = [System.Text.Encoding]::BigEndianUnicode  # UTF-16 BE
            }
            
            # Write the file with the same encoding
            [System.IO.File]::WriteAllText($file.FullName, $newContent, $encoding)
            Write-Host "Converted: $($file.FullName)" -ForegroundColor Green
            $convertedCount++
        }
    }
    catch [System.Exception] {
        Write-Host "Skipping (binary or error): $($file.FullName)" -ForegroundColor Yellow
        $skippedCount++
    }
}

# Summary
Write-Host "`nConversion complete!" -ForegroundColor Cyan
Write-Host "Total files processed: $totalFiles"
Write-Host "Files converted: $convertedCount" -ForegroundColor Green
Write-Host "Files skipped: $skippedCount" -ForegroundColor Yellow

if ($convertedCount -gt 0) {
    Write-Host "`nNote: $convertedCount files were converted to use Unix (LF) line endings." -ForegroundColor Cyan
} else {
    Write-Host "`nNo files needed conversion. All files already use Unix (LF) line endings." -ForegroundColor Green
}
