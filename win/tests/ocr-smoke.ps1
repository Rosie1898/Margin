param([Parameter(Mandatory = $true)][string]$OutputPath)
# Generates a synthetic scan only. No user document is read by the smoke test.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$bitmap = New-Object System.Drawing.Bitmap(1400, 500)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$font = New-Object System.Drawing.Font('Arial', 38, [System.Drawing.FontStyle]::Regular)
$chineseFont = New-Object System.Drawing.Font('Microsoft YaHei', 34, [System.Drawing.FontStyle]::Regular)
try {
    $graphics.Clear([System.Drawing.Color]::White)
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.DrawString('Margin local OCR 2026', $font, [System.Drawing.Brushes]::Black, 45, 60)
    $graphics.DrawString('Reading stays on this computer.', $font, [System.Drawing.Brushes]::Black, 45, 155)
    $chinese = -join @([char]0x672c, [char]0x5730, [char]0x6587, [char]0x5b57, [char]0x8bc6, [char]0x522b)
    $graphics.DrawString($chinese, $chineseFont, [System.Drawing.Brushes]::Black, 45, 270)
    $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
} finally {
    $chineseFont.Dispose()
    $font.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
}
