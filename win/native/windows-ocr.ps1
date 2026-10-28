# Windows PowerShell 5.1, invoked without a console window by the main process.
# One JSON request on stdin, one JSON response on stdout. All processing is local.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$stream = $null
$bitmap = $null
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.DataWriter, Windows.Storage.Streams, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapTransform, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
    [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null

    $script:asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetGenericArguments().Count -eq 1 -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    function Await-WinRT($operation, [Type]$resultType) {
        $task = $script:asTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
        $task.GetAwaiter().GetResult()
    }
    $request = [Console]::In.ReadToEnd() | ConvertFrom-Json
    $languages = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object {
        @{ tag = $_.LanguageTag; name = $_.DisplayName }
    })
    if ($request.action -eq 'status') {
        @{ available = ($languages.Count -gt 0); languages = $languages; maxDimension = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension; engine = 'Windows.Media.Ocr' } | ConvertTo-Json -Depth 8 -Compress
        exit 0
    }
    if ($request.action -ne 'recognize') { throw 'Unsupported OCR action.' }
    if ($request.language) {
        $language = New-Object Windows.Globalization.Language([string]$request.language)
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
    } else {
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if ($null -eq $engine -and $languages.Count -gt 0) {
            $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language($languages[0].tag)))
        }
    }
    if ($null -eq $engine) { throw 'OCR_LANGUAGE_NOT_INSTALLED' }
    # Read through .NET, then decode a memory stream. StorageFile path access can
    # be restricted by host package identity even when the app has file access.
    $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
    $writer = New-Object Windows.Storage.Streams.DataWriter($stream)
    try {
        $writer.WriteBytes([System.IO.File]::ReadAllBytes([string]$request.path))
        Await-WinRT ($writer.StoreAsync()) ([uint32]) | Out-Null
        $writer.DetachStream() | Out-Null
    } finally { $writer.Dispose() }
    $stream.Seek(0)
    $decoder = Await-WinRT ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $maximum = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
    $scale = [Math]::Min(1.0, $maximum / [double][Math]::Max($decoder.PixelWidth, $decoder.PixelHeight))
    $transform = New-Object Windows.Graphics.Imaging.BitmapTransform
    $transform.ScaledWidth = [uint32][Math]::Max(1, [Math]::Floor($decoder.PixelWidth * $scale))
    $transform.ScaledHeight = [uint32][Math]::Max(1, [Math]::Floor($decoder.PixelHeight * $scale))
    $bitmap = Await-WinRT ($decoder.GetSoftwareBitmapAsync(
        [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
        [Windows.Graphics.Imaging.BitmapAlphaMode]::Ignore,
        $transform,
        [Windows.Graphics.Imaging.ExifOrientationMode]::IgnoreExifOrientation,
        [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage
    )) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $result = Await-WinRT ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
    $words = @()
    $lines = @()
    $lineIndex = 0
    foreach ($line in $result.Lines) {
        $lineWords = @()
        foreach ($word in $line.Words) {
            $entry = @{ text = $word.Text; x = $word.BoundingRect.X; y = $word.BoundingRect.Y; width = $word.BoundingRect.Width; height = $word.BoundingRect.Height; line = $lineIndex }
            $words += $entry
            $lineWords += $entry
        }
        $lines += @{ text = $line.Text; words = $lineWords }
        $lineIndex++
    }
    @{ text = ($lines | ForEach-Object { $_.text }) -join "`n"; words = $words; lines = $lines; width = $bitmap.PixelWidth; height = $bitmap.PixelHeight; language = $engine.RecognizerLanguage.LanguageTag; textAngle = $result.TextAngle; engine = 'Windows.Media.Ocr' } | ConvertTo-Json -Depth 12 -Compress
} catch {
    @{ error = [string]$_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
} finally {
    if ($null -ne $bitmap) { $bitmap.Dispose() }
    if ($null -ne $stream) { $stream.Dispose() }
}
