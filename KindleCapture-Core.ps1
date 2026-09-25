param(
    [ValidateRange(0, 2147483647)]
    [int]$MaxPages = 1500,

    [ValidateSet("Auto", "Right", "Left")]
    [string]$Direction = "Auto",

    [ValidateSet("Select", "Window")]
    [string]$CaptureMode = "Select",

    [ValidateSet("Turbo", "Balanced", "Safe")]
    [string]$SpeedMode = "Turbo",

    [ValidateSet("On", "Off")]
    [string]$OcrMode = "On",

    [string]$OcrLanguage = "ja",

    [ValidateRange(300, 30000)]
    [int]$DelayMilliseconds = 1500,

    [ValidateRange(-1, 5000)]
    [int]$RenderSettleMilliseconds = -1,

    [ValidateRange(1, 10)]
    [int]$DuplicateStopCount = 3,

    [ValidateRange(0.1, 50.0)]
    [double]$SimilarityThreshold = 1.0,

    [string]$OutputRoot = "",

    [string]$RebuildFolder = "",

    [switch]$NoOpenOutput,

    [ValidateRange(0, 2147483647)]
    [int]$TargetProcessId = 0,

    [long]$TargetWindowHandle = 0,

    [string]$StopSignalPath = "",

    [string]$CaptureProfilePath = "",

    [string]$RegionSelectionOutputPath = ""
)

$ErrorActionPreference = "Stop"
$script:ToolVersion = "2.4.2"
$script:SignatureColumns = 160
$script:SignatureRows = 120
$script:KindleCaptureJpegCodec = $null
$script:WinRtAsTaskMethod = $null
$script:LastPdfBuildStats = $null

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class KindleCaptureNative
{
    public delegate bool EnumWindowProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int X;
        public int Y;
        public uint MouseData;
        public uint Flags;
        public uint Time;
        public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION
    {
        [FieldOffset(0)]
        public KEYBDINPUT Keyboard;

        [FieldOffset(0)]
        public MOUSEINPUT Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint Type;
        public INPUTUNION Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint ImageSize;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ColorsUsed;
        public uint ColorsImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFO
    {
        public BITMAPINFOHEADER Header;
        public uint Colors;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowProc callback, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    private static extern uint GetPixel(IntPtr hDC, int x, int y);

    [DllImport("gdi32.dll")]
    private static extern int GetDIBits(
        IntPtr hDC,
        IntPtr bitmap,
        uint startScan,
        uint scanLines,
        [Out] byte[] bits,
        ref BITMAPINFO bitmapInfo,
        uint usage
    );

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleDC(IntPtr hDC);

    [DllImport("gdi32.dll")]
    private static extern IntPtr CreateCompatibleBitmap(IntPtr hDC, int width, int height);

    [DllImport("gdi32.dll")]
    private static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteDC(IntPtr hDC);

    [DllImport("gdi32.dll")]
    private static extern int SetStretchBltMode(IntPtr hDC, int mode);

    [DllImport("gdi32.dll")]
    private static extern bool SetBrushOrgEx(IntPtr hDC, int x, int y, IntPtr previousPoint);

    [DllImport("gdi32.dll")]
    private static extern bool StretchBlt(
        IntPtr destinationDc,
        int destinationX,
        int destinationY,
        int destinationWidth,
        int destinationHeight,
        IntPtr sourceDc,
        int sourceX,
        int sourceY,
        int sourceWidth,
        int sourceHeight,
        uint rasterOperation
    );

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, INPUT[] inputs, int inputSize);

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint executionState);

    public static bool SendVirtualKey(ushort virtualKey)
    {
        const uint InputKeyboard = 1;
        const uint KeyEventExtendedKey = 0x0001;
        const uint KeyEventKeyUp = 0x0002;

        INPUT[] inputs = new INPUT[2];
        inputs[0].Type = InputKeyboard;
        inputs[0].Data.Keyboard.VirtualKey = virtualKey;
        inputs[0].Data.Keyboard.Flags = KeyEventExtendedKey;
        inputs[1].Type = InputKeyboard;
        inputs[1].Data.Keyboard.VirtualKey = virtualKey;
        inputs[1].Data.Keyboard.Flags = KeyEventExtendedKey | KeyEventKeyUp;
        return SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) == 2;
    }

    public static bool SendLeftClick()
    {
        const uint InputMouse = 0;
        const uint MouseEventLeftDown = 0x0002;
        const uint MouseEventLeftUp = 0x0004;

        INPUT[] inputs = new INPUT[2];
        inputs[0].Type = InputMouse;
        inputs[0].Data.Mouse.Flags = MouseEventLeftDown;
        inputs[1].Type = InputMouse;
        inputs[1].Data.Mouse.Flags = MouseEventLeftUp;
        return SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) == 2;
    }

    public static bool EnableBestDpiAwareness()
    {
        try
        {
            // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
            if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return true;
        }
        catch (EntryPointNotFoundException)
        {
        }
        return SetProcessDPIAware();
    }

    public static byte[] CaptureScreenLuminance(int left, int top, int width, int height, int columns, int rows)
    {
        IntPtr screenDc = GetDC(IntPtr.Zero);
        if (screenDc == IntPtr.Zero)
            throw new InvalidOperationException("Could not access the screen for page-change detection.");

        IntPtr memoryDc = IntPtr.Zero;
        IntPtr thumbnail = IntPtr.Zero;
        IntPtr previousObject = IntPtr.Zero;
        try
        {
            memoryDc = CreateCompatibleDC(screenDc);
            thumbnail = CreateCompatibleBitmap(screenDc, columns, rows);
            if (memoryDc == IntPtr.Zero || thumbnail == IntPtr.Zero)
                throw new InvalidOperationException("Could not create the page-change detector.");

            previousObject = SelectObject(memoryDc, thumbnail);
            SetStretchBltMode(memoryDc, 4); // HALFTONE
            SetBrushOrgEx(memoryDc, 0, 0, IntPtr.Zero);
            if (!StretchBlt(memoryDc, 0, 0, columns, rows, screenDc, left, top, width, height, 0x00CC0020))
                throw new InvalidOperationException("Could not sample the screen for page-change detection.");

            SelectObject(memoryDc, previousObject);
            previousObject = IntPtr.Zero;

            BITMAPINFO bitmapInfo = new BITMAPINFO();
            bitmapInfo.Header.Size = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
            bitmapInfo.Header.Width = columns;
            bitmapInfo.Header.Height = -rows; // top-down pixels
            bitmapInfo.Header.Planes = 1;
            bitmapInfo.Header.BitCount = 32;
            bitmapInfo.Header.Compression = 0; // BI_RGB
            bitmapInfo.Header.ImageSize = (uint)(columns * rows * 4);
            byte[] pixels = new byte[columns * rows * 4];
            if (GetDIBits(memoryDc, thumbnail, 0, (uint)rows, pixels, ref bitmapInfo, 0) == 0)
                throw new InvalidOperationException("Could not read the page-change detector bitmap.");

            byte[] samples = new byte[columns * rows];
            for (int index = 0; index < samples.Length; index++)
            {
                int offset = index * 4;
                int blue = pixels[offset];
                int green = pixels[offset + 1];
                int red = pixels[offset + 2];
                samples[index] = (byte)((77 * red + 150 * green + 29 * blue + 128) >> 8);
            }
            return samples;
        }
        finally
        {
            if (previousObject != IntPtr.Zero)
                SelectObject(memoryDc, previousObject);
            if (thumbnail != IntPtr.Zero)
                DeleteObject(thumbnail);
            if (memoryDc != IntPtr.Zero)
                DeleteDC(memoryDc);
            ReleaseDC(IntPtr.Zero, screenDc);
        }
    }

    private static int EdgeState(int delta)
    {
        if (delta > 2) return 1;
        if (delta < -2) return -1;
        return 0;
    }

    public static double CompareLuminanceSignatures(byte[] first, byte[] second, int columns, int rows)
    {
        if (first == null || second == null || first.Length != second.Length || first.Length != columns * rows)
            throw new ArgumentException("Page signatures have incompatible dimensions.");

        double absoluteSum = 0;
        double squareSum = 0;
        int materiallyChanged = 0;
        for (int index = 0; index < first.Length; index++)
        {
            int difference = Math.Abs(first[index] - second[index]);
            absoluteSum += difference;
            squareSum += difference * difference;
            if (difference >= 4) materiallyChanged++;
        }

        int edgeCount = 0;
        int edgeMismatch = 0;
        for (int y = 0; y < rows; y++)
        {
            for (int x = 0; x < columns; x++)
            {
                int index = (y * columns) + x;
                if (x + 1 < columns)
                {
                    int firstEdge = EdgeState(first[index + 1] - first[index]);
                    int secondEdge = EdgeState(second[index + 1] - second[index]);
                    if (firstEdge != secondEdge) edgeMismatch++;
                    edgeCount++;
                }
                if (y + 1 < rows)
                {
                    int firstEdge = EdgeState(first[index + columns] - first[index]);
                    int secondEdge = EdgeState(second[index + columns] - second[index]);
                    if (firstEdge != secondEdge) edgeMismatch++;
                    edgeCount++;
                }
            }
        }

        double meanAbsolute = absoluteSum / first.Length;
        double rootMeanSquare = Math.Sqrt(squareSum / first.Length);
        double materialPercent = 100.0 * materiallyChanged / first.Length;
        double edgeMismatchPercent = edgeCount == 0 ? 0 : 100.0 * edgeMismatch / edgeCount;
        return meanAbsolute + (0.35 * rootMeanSquare) + (0.05 * materialPercent) + (0.03 * edgeMismatchPercent);
    }

    public static double[] GetLuminanceStatistics(byte[] signature)
    {
        if (signature == null || signature.Length == 0)
            throw new ArgumentException("The page signature is empty.");

        double sum = 0;
        for (int index = 0; index < signature.Length; index++) sum += signature[index];
        double mean = sum / signature.Length;
        double squareDeviation = 0;
        for (int index = 0; index < signature.Length; index++)
        {
            double delta = signature[index] - mean;
            squareDeviation += delta * delta;
        }
        return new double[] { mean, Math.Sqrt(squareDeviation / signature.Length) };
    }

    public static double GetLuminanceSharpness(byte[] signature, int columns, int rows)
    {
        if (signature == null || signature.Length != columns * rows || columns < 3 || rows < 3)
            throw new ArgumentException("The page signature has incompatible dimensions.");

        double squareSum = 0;
        int sampleCount = 0;
        for (int y = 1; y < rows - 1; y++)
        {
            for (int x = 1; x < columns - 1; x++)
            {
                int index = (y * columns) + x;
                int laplacian =
                    (4 * signature[index]) -
                    signature[index - 1] -
                    signature[index + 1] -
                    signature[index - columns] -
                    signature[index + columns];
                squareSum += laplacian * laplacian;
                sampleCount++;
            }
        }
        return sampleCount == 0 ? 0 : Math.Sqrt(squareSum / sampleCount);
    }
}
"@

[void][KindleCaptureNative]::EnableBestDpiAwareness()

function Read-IntWithDefault {
    param(
        [string]$Prompt,
        [int]$Default,
        [int]$Minimum,
        [int]$Maximum
    )

    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }

    $parsed = 0
    if (-not [int]::TryParse($value, [ref]$parsed) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "Enter a number from $Minimum to $Maximum."
    }
    return $parsed
}

function Test-AbortKey {
    if (-not [string]::IsNullOrWhiteSpace($StopSignalPath) -and [System.IO.File]::Exists($StopSignalPath)) {
        return $true
    }
    # F12 virtual-key code
    return (([int][KindleCaptureNative]::GetAsyncKeyState(0x7B) -band 0x8000) -ne 0)
}

function Wait-WithAbort {
    param([int]$Milliseconds)

    $remaining = $Milliseconds
    while ($remaining -gt 0) {
        if (Test-AbortKey) {
            return $true
        }
        $slice = [Math]::Min(50, $remaining)
        Start-Sleep -Milliseconds $slice
        $remaining -= $slice
    }
    return $false
}

function Wait-ForAbortKeyRelease {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-AbortKey) -and $watch.ElapsedMilliseconds -lt 3000) {
        Start-Sleep -Milliseconds 50
    }
}

function Get-WindowTitle {
    param([IntPtr]$Handle)

    $builder = New-Object System.Text.StringBuilder 1024
    [void][KindleCaptureNative]::GetWindowText($Handle, $builder, $builder.Capacity)
    return $builder.ToString()
}

function Select-TargetWindow {
    $visibleWindows = @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.MainWindowHandle -ne [IntPtr]::Zero -and
                $_.ProcessName -notmatch "^(cmd|powershell|pwsh|WindowsTerminal)$"
            } |
            ForEach-Object {
                [PSCustomObject]@{
                    ProcessName = $_.ProcessName
                    ProcessId = $_.Id
                    Title = $_.MainWindowTitle
                    Handle = [IntPtr]$_.MainWindowHandle
                }
            } |
            Sort-Object ProcessName, Title
    )

    if ($visibleWindows.Count -eq 0) {
        throw "No selectable application windows were found. Open a book in Kindle and try again."
    }

    $kindleProcessWindows = @(
        $visibleWindows | Where-Object { $_.ProcessName -match "Kindle" }
    )

    if ($kindleProcessWindows.Count -gt 0) {
        $kindleWindows = $kindleProcessWindows
    }
    else {
        $kindleWindows = @(
            $visibleWindows | Where-Object { $_.Title -match "Kindle" }
        )
    }

    if ($kindleWindows.Count -gt 0) {
        $choices = $kindleWindows
        Write-Host ""
        Write-Host "Kindle window candidates:"
    }
    else {
        $choices = $visibleWindows
        Write-Host ""
        Write-Host "A Kindle window was not detected automatically."
        Write-Host "Choose the reading window from the visible-window list:"
    }

    for ($index = 0; $index -lt $choices.Count; $index++) {
        $title = $choices[$index].Title
        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = "(untitled)"
        }
        Write-Host ("  [{0}] {1} - {2}" -f ($index + 1), $choices[$index].ProcessName, $title)
    }

    $selectionText = Read-Host "Select the Kindle reading window [1]"
    if ([string]::IsNullOrWhiteSpace($selectionText)) {
        $selection = 1
    }
    else {
        $selection = 0
        if (-not [int]::TryParse($selectionText, [ref]$selection)) {
            throw "Enter a window number from the list."
        }
    }

    if ($selection -lt 1 -or $selection -gt $choices.Count) {
        throw "The selected window number is outside the list."
    }

    return $choices[$selection - 1]
}

function Get-RequestedTargetWindow {
    param(
        [int]$ProcessId,
        [long]$WindowHandle
    )

    if ($ProcessId -le 0 -or $WindowHandle -eq 0) {
        throw "Both TargetProcessId and TargetWindowHandle are required for non-interactive window selection."
    }

    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    $handle = [IntPtr]$WindowHandle
    Assert-TargetWindow -Handle $handle -ExpectedProcessId $ProcessId
    $title = Get-WindowTitle -Handle $handle
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = $process.MainWindowTitle
    }

    return [PSCustomObject]@{
        ProcessName = $process.ProcessName
        ProcessId = $process.Id
        Title = $title
        Handle = $handle
    }
}

function Get-ClientScreenRectangle {
    param([IntPtr]$Handle)

    $rect = New-Object KindleCaptureNative+RECT
    if (-not [KindleCaptureNative]::GetClientRect($Handle, [ref]$rect)) {
        throw "Could not read the target window size."
    }

    $origin = New-Object KindleCaptureNative+POINT
    $origin.X = 0
    $origin.Y = 0
    if (-not [KindleCaptureNative]::ClientToScreen($Handle, [ref]$origin)) {
        throw "Could not locate the target window."
    }

    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 100 -or $height -lt 100) {
        throw "The target window is minimized or too small."
    }

    return New-Object System.Drawing.Rectangle $origin.X, $origin.Y, $width, $height
}

function Assert-TargetWindow {
    param(
        [IntPtr]$Handle,
        [int]$ExpectedProcessId
    )

    if (-not [KindleCaptureNative]::IsWindow($Handle)) {
        throw "The selected Kindle window no longer exists. Captured images have been kept."
    }
    if (-not [KindleCaptureNative]::IsWindowVisible($Handle)) {
        throw "The selected Kindle window is no longer visible. Restore it and run again."
    }

    [uint32]$actualProcessId = 0
    [void][KindleCaptureNative]::GetWindowThreadProcessId($Handle, [ref]$actualProcessId)
    if ($actualProcessId -ne [uint32]$ExpectedProcessId) {
        throw "The selected window handle was reused by another process. Capture stopped to prevent screenshots of the wrong app."
    }
}

function New-CaptureProfile {
    param(
        [System.Drawing.Rectangle]$ClientRectangle,
        [System.Drawing.Rectangle]$CaptureRectangle
    )

    return [PSCustomObject]@{
        X = ($CaptureRectangle.Left - $ClientRectangle.Left) / [double]$ClientRectangle.Width
        Y = ($CaptureRectangle.Top - $ClientRectangle.Top) / [double]$ClientRectangle.Height
        Width = $CaptureRectangle.Width / [double]$ClientRectangle.Width
        Height = $CaptureRectangle.Height / [double]$ClientRectangle.Height
    }
}

function Import-CaptureProfile {
    param(
        [string]$Path,
        [int]$ExpectedProcessId,
        [long]$ExpectedWindowHandle
    )

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($resolvedPath)) {
        throw "The selected-area profile does not exist: $resolvedPath"
    }

    $data = Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
    if ([int]$data.TargetProcessId -ne $ExpectedProcessId -or [long]$data.TargetWindowHandle -ne $ExpectedWindowHandle) {
        throw "The selected-area profile belongs to a different window. Select the area again."
    }
    if ($null -eq $data.CaptureProfile) {
        throw "The selected-area profile is incomplete. Select the area again."
    }

    $profile = $data.CaptureProfile
    $values = @([double]$profile.X, [double]$profile.Y, [double]$profile.Width, [double]$profile.Height)
    foreach ($value in $values) {
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) {
            throw "The selected-area profile contains an invalid number."
        }
    }
    if ($profile.X -lt 0 -or $profile.Y -lt 0 -or $profile.Width -le 0 -or $profile.Height -le 0 -or
        $profile.X -gt 1 -or $profile.Y -gt 1 -or $profile.Width -gt 1 -or $profile.Height -gt 1 -or
        ($profile.X + $profile.Width) -gt 1.001 -or ($profile.Y + $profile.Height) -gt 1.001) {
        throw "The selected-area profile is outside the target window. Select the area again."
    }

    return [PSCustomObject]@{
        X = [double]$profile.X
        Y = [double]$profile.Y
        Width = [double]$profile.Width
        Height = [double]$profile.Height
    }
}

function Resolve-CaptureRectangle {
    param(
        [IntPtr]$Handle,
        $Profile
    )

    $clientRectangle = Get-ClientScreenRectangle -Handle $Handle
    $left = $clientRectangle.Left + [int][Math]::Round($Profile.X * $clientRectangle.Width)
    $top = $clientRectangle.Top + [int][Math]::Round($Profile.Y * $clientRectangle.Height)
    $width = [int][Math]::Round($Profile.Width * $clientRectangle.Width)
    $height = [int][Math]::Round($Profile.Height * $clientRectangle.Height)

    $left = [Math]::Max($clientRectangle.Left, [Math]::Min($left, $clientRectangle.Right - 1))
    $top = [Math]::Max($clientRectangle.Top, [Math]::Min($top, $clientRectangle.Bottom - 1))
    $width = [Math]::Min($width, $clientRectangle.Right - $left)
    $height = [Math]::Min($height, $clientRectangle.Bottom - $top)
    if ($width -lt 100 -or $height -lt 100) {
        throw "The Kindle window became too small for the selected capture area."
    }

    return New-Object System.Drawing.Rectangle $left, $top, $width, $height
}

function Focus-TargetWindow {
    param(
        [IntPtr]$Handle,
        [System.Drawing.Rectangle]$CaptureRectangle,
        [int]$ExpectedProcessId = 0,
        [switch]$ClickPage
    )

    if ($ExpectedProcessId -gt 0) {
        Ensure-TargetWindowForeground -Handle $Handle -ExpectedProcessId $ExpectedProcessId
    }
    else {
        if ([KindleCaptureNative]::IsIconic($Handle)) {
            [void][KindleCaptureNative]::ShowWindow($Handle, 9)
            Start-Sleep -Milliseconds 400
        }
        if (-not [KindleCaptureNative]::SetForegroundWindow($Handle)) {
            Write-Host "Warning: Windows did not confirm foreground activation."
        }
        Start-Sleep -Milliseconds 350
    }

    if ($ClickPage) {
        $clickX = $CaptureRectangle.Left + [int]($CaptureRectangle.Width / 2)
        $clickY = $CaptureRectangle.Top + [int]($CaptureRectangle.Height * 0.70)
        if (-not [KindleCaptureNative]::SetCursorPos($clickX, $clickY)) {
            throw "Windows could not position the pointer inside the selected Kindle page."
        }
        if (-not [KindleCaptureNative]::SendLeftClick()) {
            throw "Windows blocked the Kindle focus click. Make sure Kindle is not running as administrator."
        }
        Start-Sleep -Milliseconds 350
    }
}

function Ensure-TargetWindowForeground {
    param(
        [IntPtr]$Handle,
        [int]$ExpectedProcessId
    )

    Assert-TargetWindow -Handle $Handle -ExpectedProcessId $ExpectedProcessId

    if ([KindleCaptureNative]::IsIconic($Handle)) {
        [void][KindleCaptureNative]::ShowWindow($Handle, 9)
        Start-Sleep -Milliseconds 150
    }

    if ([KindleCaptureNative]::GetForegroundWindow() -ne $Handle) {
        if (-not [KindleCaptureNative]::SetForegroundWindow($Handle)) {
            Write-Host "Warning: Windows did not confirm foreground activation."
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ([KindleCaptureNative]::GetForegroundWindow() -ne $Handle -and $watch.ElapsedMilliseconds -lt 1000) {
            if (Test-AbortKey) {
                throw "Stopped by F12."
            }
            Start-Sleep -Milliseconds 50
            [void][KindleCaptureNative]::SetForegroundWindow($Handle)
        }
        if ([KindleCaptureNative]::GetForegroundWindow() -ne $Handle) {
            throw "Windows would not activate the selected Kindle window. Capture stopped instead of photographing another app."
        }
    }
}

function Send-PageTurnKey {
    param(
        [ValidateSet("Right", "Left")]
        [string]$Direction,
        [IntPtr]$Handle,
        [int]$ExpectedProcessId
    )

    Ensure-TargetWindowForeground -Handle $Handle -ExpectedProcessId $ExpectedProcessId
    foreach ($virtualKey in @(0x10, 0x11, 0x12, 0x5B, 0x5C)) {
        if ((([int][KindleCaptureNative]::GetAsyncKeyState($virtualKey)) -band 0x8000) -ne 0) {
            throw "A modifier key is being held down. Release Shift/Ctrl/Alt/Windows keys and run again."
        }
    }

    [uint16]$pageKey = if ($Direction -eq "Left") { 0x25 } else { 0x27 }
    if (-not [KindleCaptureNative]::SendVirtualKey($pageKey)) {
        throw "Windows blocked the page-turn keystroke. Make sure Kindle is not running as administrator."
    }
}

function Get-AutoCaptureRectangles {
    param(
        [IntPtr]$Handle,
        [System.Drawing.Rectangle]$ClientRectangle
    )

    $minimumWidth = [Math]::Max(160, [int][Math]::Round($ClientRectangle.Width * 0.20))
    $minimumHeight = [Math]::Max(160, [int][Math]::Round($ClientRectangle.Height * 0.25))
    $clientArea = [int64]$ClientRectangle.Width * [int64]$ClientRectangle.Height
    $seen = @{}
    $candidates = New-Object System.Collections.ArrayList

    $callback = [KindleCaptureNative+EnumWindowProc]{
        param([IntPtr]$ChildHandle, [IntPtr]$Unused)

        if (-not [KindleCaptureNative]::IsWindowVisible($ChildHandle)) {
            return $true
        }

        $nativeRectangle = New-Object KindleCaptureNative+RECT
        if (-not [KindleCaptureNative]::GetWindowRect($ChildHandle, [ref]$nativeRectangle)) {
            return $true
        }

        $left = [Math]::Max($ClientRectangle.Left, $nativeRectangle.Left)
        $top = [Math]::Max($ClientRectangle.Top, $nativeRectangle.Top)
        $right = [Math]::Min($ClientRectangle.Right, $nativeRectangle.Right)
        $bottom = [Math]::Min($ClientRectangle.Bottom, $nativeRectangle.Bottom)
        $width = $right - $left
        $height = $bottom - $top
        $area = [int64]$width * [int64]$height

        if ($width -ge $minimumWidth -and $height -ge $minimumHeight -and $area -le $clientArea) {
            $key = "{0},{1},{2},{3}" -f $left, $top, $width, $height
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $rectangle = New-Object System.Drawing.Rectangle $left, $top, $width, $height
                [void]$candidates.Add($rectangle)
            }
        }
        return $true
    }

    [void][KindleCaptureNative]::EnumChildWindows($Handle, $callback, [IntPtr]::Zero)
    return @(
        $candidates |
            Sort-Object @{ Expression = { [int64]$_.Width * [int64]$_.Height } }, Width, Height
    )
}

function Find-AutoCaptureRectangle {
    param(
        [System.Drawing.Point]$ScreenPoint,
        [object[]]$Candidates,
        [System.Drawing.Rectangle]$FallbackRectangle
    )

    foreach ($candidate in $Candidates) {
        if ($candidate.Contains($ScreenPoint)) {
            return $candidate
        }
    }
    return $FallbackRectangle
}

function Select-CaptureRectangle {
    param([IntPtr]$Handle)

    $clientRectangle = Get-ClientScreenRectangle -Handle $Handle

    while ($true) {
        Focus-TargetWindow -Handle $Handle -CaptureRectangle $clientRectangle
        $captureCandidates = @(Get-AutoCaptureRectangles -Handle $Handle -ClientRectangle $clientRectangle)

        $state = @{
            Candidate = $clientRectangle
            Result = $null
        }

        $form = New-Object System.Windows.Forms.Form
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
        $form.Bounds = $clientRectangle
        $form.TopMost = $true
        $form.ShowInTaskbar = $false
        $form.BackColor = [System.Drawing.Color]::Black
        $form.Opacity = 0.28
        $form.Cursor = [System.Windows.Forms.Cursors]::Hand
        $form.KeyPreview = $true
        $form.Text = "Auto-select Kindle capture area"

        $updateCandidate = {
            param([System.Drawing.Point]$ScreenPoint)
            $next = Find-AutoCaptureRectangle -ScreenPoint $ScreenPoint -Candidates $captureCandidates -FallbackRectangle $clientRectangle
            if ($state.Candidate.Left -ne $next.Left -or
                $state.Candidate.Top -ne $next.Top -or
                $state.Candidate.Width -ne $next.Width -or
                $state.Candidate.Height -ne $next.Height) {
                $state.Candidate = $next
                $form.Invalidate()
            }
        }

        $form.Add_MouseMove({
            param($sender, $eventArgs)
            $screenPoint = New-Object System.Drawing.Point (
                $clientRectangle.Left + $eventArgs.X
            ), (
                $clientRectangle.Top + $eventArgs.Y
            )
            & $updateCandidate $screenPoint
        })

        $form.Add_MouseDown({
            param($sender, $eventArgs)
            if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left) {
                return
            }
            $state.Result = $state.Candidate
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        })

        $form.Add_Paint({
            param($sender, $eventArgs)
            $font = New-Object System.Drawing.Font "Segoe UI", 14, ([System.Drawing.FontStyle]::Bold)
            $detailFont = New-Object System.Drawing.Font "Segoe UI", 11, ([System.Drawing.FontStyle]::Regular)
            $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Lime), 4
            $highlightBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(75, 0, 255, 0))
            try {
                $eventArgs.Graphics.DrawString(
                    "Point at the Kindle page and click the highlighted area. Esc cancels.",
                    $font,
                    $brush,
                    20,
                    20
                )
                $candidateRectangle = New-Object System.Drawing.Rectangle (
                    $state.Candidate.Left - $clientRectangle.Left
                ), (
                    $state.Candidate.Top - $clientRectangle.Top
                ), $state.Candidate.Width, $state.Candidate.Height
                $eventArgs.Graphics.FillRectangle($highlightBrush, $candidateRectangle)
                $eventArgs.Graphics.DrawRectangle($pen, $candidateRectangle)
                $eventArgs.Graphics.DrawString(
                    ("Detected: {0} x {1} pixels" -f $state.Candidate.Width, $state.Candidate.Height),
                    $detailFont,
                    $brush,
                    20,
                    53
                )
            }
            finally {
                $font.Dispose()
                $detailFont.Dispose()
                $brush.Dispose()
                $pen.Dispose()
                $highlightBrush.Dispose()
            }
        })

        $form.Add_KeyDown({
            param($sender, $eventArgs)
            if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
                $form.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
                $form.Close()
            }
        })

        $form.Add_Shown({
            $form.Activate()
            & $updateCandidate ([System.Windows.Forms.Cursor]::Position)
        })
        $dialogResult = $form.ShowDialog()
        $form.Dispose()

        if ($dialogResult -ne [System.Windows.Forms.DialogResult]::OK -or $null -eq $state.Result) {
            return $null
        }

        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("Use this automatically detected Kindle area? {0} x {1} pixels" -f $state.Result.Width, $state.Result.Height),
            "Confirm detected capture area",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            return $state.Result
        }
    }
}

function Capture-ScreenRectangle {
    param([System.Drawing.Rectangle]$Rectangle)

    $bitmap = New-Object System.Drawing.Bitmap $Rectangle.Width, $Rectangle.Height, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen(
            $Rectangle.Left,
            $Rectangle.Top,
            0,
            0,
            $Rectangle.Size,
            [System.Drawing.CopyPixelOperation]::SourceCopy
        )
    }
    finally {
        $graphics.Dispose()
    }
    return $bitmap
}

function Get-ImageSignature {
    param([System.Drawing.Bitmap]$Bitmap)

    $small = New-Object System.Drawing.Bitmap $script:SignatureColumns, $script:SignatureRows, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $graphics = [System.Drawing.Graphics]::FromImage($small)
    try {
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($Bitmap, 0, 0, $script:SignatureColumns, $script:SignatureRows)
    }
    finally {
        $graphics.Dispose()
    }

    try {
        $signature = New-Object 'byte[]' ($script:SignatureColumns * $script:SignatureRows)
        for ($y = 0; $y -lt $script:SignatureRows; $y++) {
            for ($x = 0; $x -lt $script:SignatureColumns; $x++) {
                $color = $small.GetPixel($x, $y)
                $luminance = [int]((77 * $color.R + 150 * $color.G + 29 * $color.B + 128) -shr 8)
                $signature[($y * $script:SignatureColumns) + $x] = [byte]$luminance
            }
        }
        return $signature
    }
    finally {
        $small.Dispose()
    }
}

function Compare-ImageSignatures {
    param($First, $Second)

    return [KindleCaptureNative]::CompareLuminanceSignatures(
        $First,
        $Second,
        $script:SignatureColumns,
        $script:SignatureRows
    )
}

function Get-CaptureSignature {
    param([System.Drawing.Rectangle]$Rectangle)

    return [KindleCaptureNative]::CaptureScreenLuminance(
        $Rectangle.Left,
        $Rectangle.Top,
        $Rectangle.Width,
        $Rectangle.Height,
        $script:SignatureColumns,
        $script:SignatureRows
    )
}

function Get-SignatureStatistics {
    param([byte[]]$Signature)

    $values = [KindleCaptureNative]::GetLuminanceStatistics($Signature)
    return [PSCustomObject]@{
        Mean = $values[0]
        StandardDeviation = $values[1]
    }
}

function Get-SignatureSharpness {
    param([byte[]]$Signature)

    return [KindleCaptureNative]::GetLuminanceSharpness(
        $Signature,
        $script:SignatureColumns,
        $script:SignatureRows
    )
}

function Wait-ForRenderClarity {
    param(
        [System.Drawing.Rectangle]$Rectangle,
        [byte[]]$InitialSignature,
        [int]$MinimumWait,
        [int]$PollInterval,
        [int]$StableSamples,
        [double]$StableThreshold = 0.35,
        [double]$SharpnessTolerance = 0.015
    )

    $initialSharpness = Get-SignatureSharpness -Signature $InitialSignature
    if ($MinimumWait -le 0) {
        return [PSCustomObject]@{
            Aborted = $false
            TimedOut = $false
            ElapsedMilliseconds = 0
            Signature = $InitialSignature
            Sharpness = $initialSharpness
        }
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $maximumWait = $MinimumWait + [Math]::Max(300, $MinimumWait)
    $lastSignature = $InitialSignature
    $lastSharpness = $initialSharpness
    $peakSharpness = $initialSharpness
    $sharpnessStableCount = 0
    $currentSignature = $InitialSignature
    $currentSharpness = $initialSharpness

    while ($watch.ElapsedMilliseconds -lt $maximumWait) {
        $remaining = $maximumWait - [int]$watch.ElapsedMilliseconds
        $waitTime = [Math]::Min($PollInterval, [Math]::Max(1, $remaining))
        if (Wait-WithAbort -Milliseconds $waitTime) {
            $watch.Stop()
            return [PSCustomObject]@{
                Aborted = $true
                TimedOut = $false
                ElapsedMilliseconds = $watch.ElapsedMilliseconds
                Signature = $currentSignature
                Sharpness = $currentSharpness
            }
        }

        $currentSignature = Get-CaptureSignature -Rectangle $Rectangle
        $currentSharpness = Get-SignatureSharpness -Signature $currentSignature
        $movement = Compare-ImageSignatures -First $lastSignature -Second $currentSignature
        if ($currentSharpness -gt $peakSharpness) {
            $peakSharpness = $currentSharpness
        }

        $sharpnessScale = [Math]::Max(1.0, [Math]::Max([Math]::Abs($lastSharpness), [Math]::Abs($peakSharpness)))
        $sharpnessChange = [Math]::Abs($currentSharpness - $lastSharpness) / $sharpnessScale
        $nearPeak = $currentSharpness -ge ($peakSharpness * (1.0 - $SharpnessTolerance))
        if ($watch.ElapsedMilliseconds -lt $MinimumWait) {
            $sharpnessStableCount = 0
        }
        elseif ($movement -le $StableThreshold -and $sharpnessChange -le $SharpnessTolerance -and $nearPeak) {
            $sharpnessStableCount++
        }
        else {
            $sharpnessStableCount = 0
        }

        $lastSignature = $currentSignature
        $lastSharpness = $currentSharpness
        if ($watch.ElapsedMilliseconds -ge $MinimumWait -and $sharpnessStableCount -ge $StableSamples) {
            $watch.Stop()
            return [PSCustomObject]@{
                Aborted = $false
                TimedOut = $false
                ElapsedMilliseconds = $watch.ElapsedMilliseconds
                Signature = $currentSignature
                Sharpness = $currentSharpness
            }
        }
    }

    $watch.Stop()
    return [PSCustomObject]@{
        Aborted = $false
        TimedOut = $true
        ElapsedMilliseconds = $watch.ElapsedMilliseconds
        Signature = $currentSignature
        Sharpness = $currentSharpness
    }
}

function Wait-ForPageReady {
    param(
        [System.Drawing.Rectangle]$Rectangle,
        $PreviousSignature,
        [int]$MaximumWait,
        [int]$PollInterval,
        [int]$StableSamples,
        [double]$ChangeThreshold,
        [int]$RenderSettleMilliseconds = 0,
        [double]$StableThreshold = 0.35
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $changed = $false
    $stableCount = 0
    $lastSignature = $PreviousSignature
    $currentSignature = $PreviousSignature

    while ($watch.ElapsedMilliseconds -lt $MaximumWait) {
        $remaining = $MaximumWait - [int]$watch.ElapsedMilliseconds
        $waitTime = [Math]::Min($PollInterval, [Math]::Max(1, $remaining))
        if (Wait-WithAbort -Milliseconds $waitTime) {
            $watch.Stop()
            return [PSCustomObject]@{
                Aborted = $true
                Changed = $changed
                TimedOut = $false
                ElapsedMilliseconds = $watch.ElapsedMilliseconds
                Signature = $currentSignature
                Sharpness = Get-SignatureSharpness -Signature $currentSignature
                ClarityMilliseconds = 0
                ClarityTimedOut = $false
            }
        }

        $currentSignature = Get-CaptureSignature -Rectangle $Rectangle
        if (-not $changed) {
            $differenceFromPrevious = Compare-ImageSignatures -First $PreviousSignature -Second $currentSignature
            if ($differenceFromPrevious -ge $ChangeThreshold) {
                $changed = $true
                $stableCount = 0
                $lastSignature = $currentSignature
            }
            continue
        }

        $movement = Compare-ImageSignatures -First $lastSignature -Second $currentSignature
        if ($movement -le $StableThreshold) {
            $stableCount++
        }
        else {
            $stableCount = 0
        }
        $lastSignature = $currentSignature

        if ($stableCount -ge $StableSamples) {
            $clarityResult = Wait-ForRenderClarity -Rectangle $Rectangle -InitialSignature $currentSignature -MinimumWait $RenderSettleMilliseconds -PollInterval $PollInterval -StableSamples $StableSamples -StableThreshold $StableThreshold
            if ($clarityResult.Aborted) {
                $watch.Stop()
                return [PSCustomObject]@{
                    Aborted = $true
                    Changed = $true
                    TimedOut = $false
                    ElapsedMilliseconds = $watch.ElapsedMilliseconds
                    Signature = $clarityResult.Signature
                    Sharpness = $clarityResult.Sharpness
                    ClarityMilliseconds = $clarityResult.ElapsedMilliseconds
                    ClarityTimedOut = $false
                }
            }
            $watch.Stop()
            return [PSCustomObject]@{
                Aborted = $false
                Changed = $true
                TimedOut = $false
                ElapsedMilliseconds = $watch.ElapsedMilliseconds
                Signature = $clarityResult.Signature
                Sharpness = $clarityResult.Sharpness
                ClarityMilliseconds = $clarityResult.ElapsedMilliseconds
                ClarityTimedOut = $clarityResult.TimedOut
            }
        }
    }

    $clarityMilliseconds = 0
    $clarityTimedOut = $false
    $finalSharpness = Get-SignatureSharpness -Signature $currentSignature
    if ($changed -and $RenderSettleMilliseconds -gt 0) {
        $clarityResult = Wait-ForRenderClarity -Rectangle $Rectangle -InitialSignature $currentSignature -MinimumWait $RenderSettleMilliseconds -PollInterval $PollInterval -StableSamples $StableSamples -StableThreshold $StableThreshold
        $currentSignature = $clarityResult.Signature
        $finalSharpness = $clarityResult.Sharpness
        $clarityMilliseconds = $clarityResult.ElapsedMilliseconds
        $clarityTimedOut = $clarityResult.TimedOut
        if ($clarityResult.Aborted) {
            $watch.Stop()
            return [PSCustomObject]@{
                Aborted = $true
                Changed = $true
                TimedOut = $false
                ElapsedMilliseconds = $watch.ElapsedMilliseconds
                Signature = $currentSignature
                Sharpness = $finalSharpness
                ClarityMilliseconds = $clarityMilliseconds
                ClarityTimedOut = $false
            }
        }
    }

    $watch.Stop()
    return [PSCustomObject]@{
        Aborted = $false
        Changed = $changed
        TimedOut = $true
        ElapsedMilliseconds = $watch.ElapsedMilliseconds
        Signature = $currentSignature
        Sharpness = $finalSharpness
        ClarityMilliseconds = $clarityMilliseconds
        ClarityTimedOut = $clarityTimedOut
    }
}

function Detect-PageTurnDirection {
    param(
        [IntPtr]$Handle,
        [int]$ExpectedProcessId,
        [System.Drawing.Rectangle]$CaptureRectangle,
        [int]$Delay,
        [double]$Threshold,
        [int]$PollInterval,
        [int]$StableSamples,
        [int]$RenderSettleMilliseconds
    )

    $detectionThreshold = [Math]::Max(1.5, $Threshold * 1.5)
    Focus-TargetWindow -Handle $Handle -CaptureRectangle $CaptureRectangle -ExpectedProcessId $ExpectedProcessId -ClickPage
    if (Wait-WithAbort -Milliseconds 800) { throw "Stopped by F12." }
    $initial = Get-CaptureSignature -Rectangle $CaptureRectangle

    Write-Host "Testing the Right arrow..."
    Send-PageTurnKey -Direction "Right" -Handle $Handle -ExpectedProcessId $ExpectedProcessId
    $rightWait = Wait-ForPageReady -Rectangle $CaptureRectangle -PreviousSignature $initial -MaximumWait $Delay -PollInterval $PollInterval -StableSamples $StableSamples -ChangeThreshold $detectionThreshold -RenderSettleMilliseconds $RenderSettleMilliseconds
    if ($rightWait.Aborted) { throw "Stopped by F12." }
    $afterRight = $rightWait.Signature
    $rightDifference = Compare-ImageSignatures -First $initial -Second $afterRight

    if ($rightDifference -ge $detectionThreshold) {
        Write-Host ("Right arrow changed the page (difference {0:N1})." -f $rightDifference)
        Send-PageTurnKey -Direction "Left" -Handle $Handle -ExpectedProcessId $ExpectedProcessId
        $restoreWait = Wait-ForPageReady -Rectangle $CaptureRectangle -PreviousSignature $afterRight -MaximumWait $Delay -PollInterval $PollInterval -StableSamples $StableSamples -ChangeThreshold $detectionThreshold -RenderSettleMilliseconds $RenderSettleMilliseconds
        if ($restoreWait.Aborted) { throw "Stopped by F12." }
        $restoreDifference = Compare-ImageSignatures -First $initial -Second $restoreWait.Signature
        if ($restoreDifference -ge $detectionThreshold) {
            throw ("The Right arrow changed the page, but the Left arrow did not restore the starting page (difference {0:N1}). Choose the direction manually to avoid skipping a page." -f $restoreDifference)
        }
        return "Right"
    }

    Write-Host ("Right arrow did not change the page enough (difference {0:N1})." -f $rightDifference)
    Send-PageTurnKey -Direction "Left" -Handle $Handle -ExpectedProcessId $ExpectedProcessId
    $leftWait = Wait-ForPageReady -Rectangle $CaptureRectangle -PreviousSignature $initial -MaximumWait $Delay -PollInterval $PollInterval -StableSamples $StableSamples -ChangeThreshold $detectionThreshold -RenderSettleMilliseconds $RenderSettleMilliseconds
    if ($leftWait.Aborted) { throw "Stopped by F12." }
    $afterLeft = $leftWait.Signature
    $leftDifference = Compare-ImageSignatures -First $initial -Second $afterLeft

    if ($leftDifference -ge $detectionThreshold) {
        Write-Host ("Left arrow changed the page (difference {0:N1})." -f $leftDifference)
        Send-PageTurnKey -Direction "Right" -Handle $Handle -ExpectedProcessId $ExpectedProcessId
        $restoreWait = Wait-ForPageReady -Rectangle $CaptureRectangle -PreviousSignature $afterLeft -MaximumWait $Delay -PollInterval $PollInterval -StableSamples $StableSamples -ChangeThreshold $detectionThreshold -RenderSettleMilliseconds $RenderSettleMilliseconds
        if ($restoreWait.Aborted) { throw "Stopped by F12." }
        $restoreDifference = Compare-ImageSignatures -First $initial -Second $restoreWait.Signature
        if ($restoreDifference -ge $detectionThreshold) {
            throw ("The Left arrow changed the page, but the Right arrow did not restore the starting page (difference {0:N1}). Choose the direction manually to avoid skipping a page." -f $restoreDifference)
        }
        return "Left"
    }

    throw ("Could not detect the page-turn direction. Right difference={0:N1}, Left difference={1:N1}. Click inside the book, start at the first page, or choose the direction manually." -f $rightDifference, $leftDifference)
}

function Assert-FreeDiskSpace {
    param(
        [string]$OutputDirectory,
        [int]$PageLimit
    )

    $pagesForEstimate = if ($PageLimit -eq 0) { 1500 } else { $PageLimit }
    # Reserve room for both the captured JPEGs and the final JPEG-backed PDF.
    $estimatedBytes = [int64]$pagesForEstimate * 2MB
    $fullPath = [System.IO.Path]::GetFullPath($OutputDirectory)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if ($root -match "^[A-Za-z]:\\$") {
        $drive = New-Object System.IO.DriveInfo $root
        Write-Host ("Disk check: {0:N1} GB free; about {1:N1} GB estimated for {2} pages." -f ($drive.AvailableFreeSpace / 1GB), ($estimatedBytes / 1GB), $pagesForEstimate)
        if ($drive.AvailableFreeSpace -lt $estimatedBytes) {
            throw "There may not be enough free disk space for the requested capture count."
        }
    }
    else {
        Write-Host ("Disk check: free-space reporting is unavailable for '{0}'. About {1:N1} GB is estimated for {2} pages." -f $root, ($estimatedBytes / 1GB), $pagesForEstimate) -ForegroundColor Yellow
    }
}

function Resolve-CaptureOutputRoot {
    param([string]$Path)

    $candidate = $Path
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $PSScriptRoot
    }
    else {
        $candidate = [Environment]::ExpandEnvironmentVariables($candidate.Trim())
    }

    $fullPath = [System.IO.Path]::GetFullPath($candidate)
    if ([System.IO.File]::Exists($fullPath)) {
        throw "The output location points to a file instead of a folder: $fullPath"
    }
    if (-not [System.IO.Directory]::Exists($fullPath)) {
        [void][System.IO.Directory]::CreateDirectory($fullPath)
    }

    $probePath = Join-Path $fullPath (".kindle_capture_write_test_{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    try {
        [System.IO.File]::WriteAllText($probePath, "")
    }
    catch {
        throw "The output folder is not writable: $fullPath"
    }
    finally {
        if ([System.IO.File]::Exists($probePath)) {
            try { [System.IO.File]::Delete($probePath) } catch { }
        }
    }

    return $fullPath
}

function New-CaptureOutputDirectory {
    param(
        [string]$Root,
        [string]$Timestamp
    )

    for ($suffix = 0; $suffix -lt 1000; $suffix++) {
        $folderName = if ($suffix -eq 0) {
            "captures_$Timestamp"
        }
        else {
            "captures_{0}_{1:D2}" -f $Timestamp, $suffix
        }
        $candidate = Join-Path $Root $folderName
        if (-not [System.IO.Directory]::Exists($candidate) -and -not [System.IO.File]::Exists($candidate)) {
            [void][System.IO.Directory]::CreateDirectory($candidate)
            return $candidate
        }
    }

    throw "Could not create a unique capture folder under: $Root"
}

function Save-CaptureManifest {
    param(
        [string]$Path,
        $Session
    )

    $json = $Session | ConvertTo-Json -Depth 6
    $finalPath = [System.IO.Path]::GetFullPath($Path)
    $temporaryPath = "$finalPath.tmp"
    $backupPath = "$finalPath.previous"
    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            (New-Object System.Text.UTF8Encoding $false)
        )
        if (Test-Path -LiteralPath $finalPath) {
            if (Test-Path -LiteralPath $backupPath) {
                Remove-Item -LiteralPath $backupPath -Force
            }
            [System.IO.File]::Replace($temporaryPath, $finalPath, $backupPath, $true)
            if (Test-Path -LiteralPath $backupPath) {
                try { Remove-Item -LiteralPath $backupPath -Force } catch { }
            }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $finalPath)
        }
    }
    catch {
        if (Test-Path -LiteralPath $temporaryPath) {
            try { Remove-Item -LiteralPath $temporaryPath -Force } catch { }
        }
        throw
    }
}

function Save-JpegBitmap {
    param(
        [System.Drawing.Bitmap]$Bitmap,
        [string]$Path,
        [ValidateRange(40, 100)]
        [int]$Quality
    )

    if ($null -eq $script:KindleCaptureJpegCodec) {
        $script:KindleCaptureJpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
            Where-Object { $_.MimeType -eq "image/jpeg" } |
            Select-Object -First 1
        if ($null -eq $script:KindleCaptureJpegCodec) {
            throw "The Windows JPEG encoder is unavailable."
        }
    }

    $finalPath = [System.IO.Path]::GetFullPath($Path)
    $temporaryPath = "$finalPath.partial"
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }

    $encoderParameters = New-Object System.Drawing.Imaging.EncoderParameters 1
    $qualityParameter = New-Object System.Drawing.Imaging.EncoderParameter (
        [System.Drawing.Imaging.Encoder]::Quality,
        [long]$Quality
    )
    try {
        $encoderParameters.Param[0] = $qualityParameter
        $Bitmap.Save($temporaryPath, $script:KindleCaptureJpegCodec, $encoderParameters)
        if (Test-Path -LiteralPath $finalPath) {
            throw "The JPEG output already exists: $finalPath"
        }
        [System.IO.File]::Move($temporaryPath, $finalPath)
    }
    catch {
        if (Test-Path -LiteralPath $temporaryPath) {
            try { Remove-Item -LiteralPath $temporaryPath -Force } catch { }
        }
        throw
    }
    finally {
        $qualityParameter.Dispose()
        $encoderParameters.Dispose()
    }
}

function Initialize-WindowsOcr {
    param([string]$LanguageTag)

    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.FileAccessMode, Windows.Storage, ContentType = WindowsRuntime]
    $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
    $null = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]

    $language = New-Object Windows.Globalization.Language $LanguageTag
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
    if ($null -eq $engine) {
        $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })
        throw ("Windows OCR language '{0}' is unavailable. Available: {1}" -f $LanguageTag, ($available -join ", "))
    }
    return $engine
}

function Wait-WinRtOperation {
    param(
        $Operation,
        [Type]$ResultType
    )

    if ($null -eq $script:WinRtAsTaskMethod) {
        $script:WinRtAsTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq "AsTask" -and
                $_.IsGenericMethodDefinition -and
                $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq "IAsyncOperation``1"
            } |
            Select-Object -First 1
        if ($null -eq $script:WinRtAsTaskMethod) {
            throw "Could not locate the Windows OCR async adapter."
        }
    }

    $task = $script:WinRtAsTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    [void]$task.Wait(-1)
    return $task.Result
}

function Get-WindowsOcrLines {
    param(
        $Engine,
        [string]$ImagePath,
        [string]$LanguageTag,
        [int]$SourceWidth,
        [int]$SourceHeight
    )

    $sourcePath = [System.IO.Path]::GetFullPath($ImagePath)
    $ocrPath = $sourcePath
    $temporaryPath = $null
    $coordinateScaleX = 1.0
    $coordinateScaleY = 1.0
    $sourceImage = $null
    $resizedImage = $null
    $resizeGraphics = $null
    $resizeCompleted = $false

    $maximumDimension = [Windows.Media.Ocr.OcrEngine]::MaxImageDimension
    $largestDimension = [Math]::Max($SourceWidth, $SourceHeight)
    if ($largestDimension -gt $maximumDimension) {
        try {
            $sourceImage = [System.Drawing.Image]::FromFile($sourcePath)
            $resizeScale = $maximumDimension / [double]$largestDimension
            $resizedWidth = [Math]::Max(1, [int][Math]::Floor($sourceImage.Width * $resizeScale))
            $resizedHeight = [Math]::Max(1, [int][Math]::Floor($sourceImage.Height * $resizeScale))
            $coordinateScaleX = $sourceImage.Width / [double]$resizedWidth
            $coordinateScaleY = $sourceImage.Height / [double]$resizedHeight
            $resizedImage = New-Object System.Drawing.Bitmap $resizedWidth, $resizedHeight, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            $resizeGraphics = [System.Drawing.Graphics]::FromImage($resizedImage)
            $resizeGraphics.Clear([System.Drawing.Color]::White)
            $resizeGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $resizeGraphics.DrawImage($sourceImage, 0, 0, $resizedWidth, $resizedHeight)
            $temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) ("KindleAutoCapture_OCR_{0}.jpg" -f ([Guid]::NewGuid().ToString("N")))
            Save-JpegBitmap -Bitmap $resizedImage -Path $temporaryPath -Quality 92
            $ocrPath = $temporaryPath
            $resizeCompleted = $true
        }
        finally {
            if ($null -ne $resizeGraphics) { $resizeGraphics.Dispose() }
            if ($null -ne $resizedImage) { $resizedImage.Dispose() }
            if ($null -ne $sourceImage) { $sourceImage.Dispose() }
            if (-not $resizeCompleted -and $null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
                try { Remove-Item -LiteralPath $temporaryPath -Force } catch { }
            }
        }
    }

    $randomAccessStream = $null
    $softwareBitmap = $null
    try {
        $storageFile = Wait-WinRtOperation -Operation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ocrPath)) -ResultType ([Windows.Storage.StorageFile])
        $randomAccessStream = Wait-WinRtOperation -Operation ($storageFile.OpenAsync([Windows.Storage.FileAccessMode]::Read)) -ResultType ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Wait-WinRtOperation -Operation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($randomAccessStream)) -ResultType ([Windows.Graphics.Imaging.BitmapDecoder])
        $softwareBitmap = Wait-WinRtOperation -Operation ($decoder.GetSoftwareBitmapAsync()) -ResultType ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Wait-WinRtOperation -Operation ($Engine.RecognizeAsync($softwareBitmap)) -ResultType ([Windows.Media.Ocr.OcrResult])

        $isCjkLanguage = $LanguageTag -match "^(ja|zh|ko)(-|$)"
        foreach ($line in $result.Lines) {
            $words = @($line.Words)
            if ($words.Count -eq 0) {
                continue
            }

            if ($isCjkLanguage) {
                $textBuilder = New-Object System.Text.StringBuilder
                $previousWord = $null
                foreach ($word in $words) {
                    if ($null -ne $previousWord) {
                        $horizontalGap = $word.BoundingRect.X - ($previousWord.BoundingRect.X + $previousWord.BoundingRect.Width)
                        $spaceThreshold = [Math]::Max(4.0, [Math]::Min($word.BoundingRect.Height, $previousWord.BoundingRect.Height) * 0.45)
                        $previousIsAscii = $previousWord.Text -match "^[\x21-\x7E]+$"
                        $currentIsAscii = $word.Text -match "^[\x21-\x7E]+$"
                        if ($previousIsAscii -and $currentIsAscii -and $horizontalGap -gt $spaceThreshold) {
                            [void]$textBuilder.Append(" ")
                        }
                    }
                    [void]$textBuilder.Append($word.Text)
                    $previousWord = $word
                }
                $text = $textBuilder.ToString()
            }
            else {
                $text = (($words | ForEach-Object { $_.Text }) -join " ")
            }
            $left = ($words | ForEach-Object { $_.BoundingRect.X } | Measure-Object -Minimum).Minimum
            $top = ($words | ForEach-Object { $_.BoundingRect.Y } | Measure-Object -Minimum).Minimum
            $right = ($words | ForEach-Object { $_.BoundingRect.X + $_.BoundingRect.Width } | Measure-Object -Maximum).Maximum
            $bottom = ($words | ForEach-Object { $_.BoundingRect.Y + $_.BoundingRect.Height } | Measure-Object -Maximum).Maximum

            [PSCustomObject]@{
                Text = $text
                X = $left * $coordinateScaleX
                Y = $top * $coordinateScaleY
                Width = ($right - $left) * $coordinateScaleX
                Height = ($bottom - $top) * $coordinateScaleY
            }
        }
    }
    finally {
        if ($null -ne $softwareBitmap) { $softwareBitmap.Dispose() }
        if ($null -ne $randomAccessStream) { $randomAccessStream.Dispose() }
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            try { Remove-Item -LiteralPath $temporaryPath -Force } catch { }
        }
    }
}

function ConvertTo-PdfUnicodeHex {
    param([string]$Text)

    $cleanText = $Text -replace "[\x00-\x08\x0B\x0C\x0E-\x1F]", ""
    $bytes = [System.Text.Encoding]::BigEndianUnicode.GetBytes($cleanText)
    return (($bytes | ForEach-Object { $_.ToString("X2") }) -join "")
}

function New-ImagePdf {
    param(
        [string[]]$ImagePaths,
        [string]$OutputPath,
        $OcrEngine = $null,
        [string]$OcrLanguageTag = "ja",
        [ValidateRange(40, 100)]
        [int]$JpegQuality = 88
    )

    if ($ImagePaths.Count -eq 0) {
        throw "No images were supplied for PDF creation."
    }

    $script:LastPdfBuildStats = $null

    $useOcr = $null -ne $OcrEngine
    $baseObjectCount = 2 + ($ImagePaths.Count * 3)
    if ($useOcr) {
        $fontObject = $baseObjectCount + 1
        $cidFontObject = $baseObjectCount + 2
        $toUnicodeObject = $baseObjectCount + 3
        $infoObject = $baseObjectCount + 4
        $objectCount = $baseObjectCount + 4
    }
    else {
        $infoObject = $baseObjectCount + 1
        $objectCount = $baseObjectCount + 1
    }
    $offsets = New-Object 'long[]' ($objectCount + 1)
    $ascii = [System.Text.Encoding]::ASCII
    $stream = $null
    $writer = $null
    $ocrPageCount = 0
    $ocrLineCount = 0
    $finalOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $workingOutputPath = "$finalOutputPath.partial"
    if (Test-Path -LiteralPath $workingOutputPath) {
        Remove-Item -LiteralPath $workingOutputPath -Force
    }

    try {
        $stream = New-Object System.IO.FileStream (
            $workingOutputPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $writer = New-Object System.IO.BinaryWriter $stream, $ascii, $true

        function Write-PdfAscii {
            param([string]$Text)
            $writer.Write($ascii.GetBytes($Text))
        }

        function Start-PdfObject {
            param([int]$ObjectNumber)
            $offsets[$ObjectNumber] = $stream.Position
            Write-PdfAscii "$ObjectNumber 0 obj`n"
        }

        Write-PdfAscii "%PDF-1.4`n"

        Start-PdfObject 1
        $languageEntry = if ($useOcr) {
            $safeLanguage = $OcrLanguageTag -replace "[^A-Za-z0-9-]", ""
            " /Lang ($safeLanguage)"
        }
        else {
            ""
        }
        Write-PdfAscii ("<< /Type /Catalog /Pages 2 0 R{0} >>`nendobj`n" -f $languageEntry)

        $pageReferences = New-Object System.Collections.Generic.List[string]
        for ($index = 0; $index -lt $ImagePaths.Count; $index++) {
            $pageObject = 3 + ($index * 3)
            $pageReferences.Add("$pageObject 0 R")
        }

        Start-PdfObject 2
        Write-PdfAscii ("<< /Type /Pages /Count {0} /Kids [{1}] >>`nendobj`n" -f $ImagePaths.Count, ($pageReferences -join " "))

        $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
            Where-Object { $_.MimeType -eq "image/jpeg" } |
            Select-Object -First 1
        if ($null -eq $jpegCodec) {
            throw "The Windows JPEG encoder is unavailable."
        }

        for ($index = 0; $index -lt $ImagePaths.Count; $index++) {
            if (Test-AbortKey) {
                throw "Stopped by F12 during PDF/OCR creation. Captured images were kept and can be rebuilt later."
            }
            $pageObject = 3 + ($index * 3)
            $imageObject = $pageObject + 1
            $contentObject = $pageObject + 2
            $image = $null
            $jpegStream = $null
            $encoderParameters = $null
            $qualityParameter = $null
            $ocrLines = @()

            try {
                $image = [System.Drawing.Image]::FromFile($ImagePaths[$index])
                $imageWidth = $image.Width
                $imageHeight = $image.Height

                if ($imageWidth -ge $imageHeight) {
                    $pageWidth = 842.0
                    $pageHeight = 595.0
                }
                else {
                    $pageWidth = 595.0
                    $pageHeight = 842.0
                }

                $scale = [Math]::Min($pageWidth / $imageWidth, $pageHeight / $imageHeight)
                $drawWidth = $imageWidth * $scale
                $drawHeight = $imageHeight * $scale
                $drawX = ($pageWidth - $drawWidth) / 2.0
                $drawY = ($pageHeight - $drawHeight) / 2.0

                $extension = [System.IO.Path]::GetExtension($ImagePaths[$index])
                if ($extension -match "^\.(jpg|jpeg)$") {
                    # Turbo path: captured JPEG bytes can be embedded as-is.
                    $jpegBytes = [System.IO.File]::ReadAllBytes($ImagePaths[$index])
                }
                else {
                    $jpegStream = New-Object System.IO.MemoryStream
                    $encoderParameters = New-Object System.Drawing.Imaging.EncoderParameters 1
                    $qualityParameter = New-Object System.Drawing.Imaging.EncoderParameter (
                        [System.Drawing.Imaging.Encoder]::Quality,
                        [long]$JpegQuality
                    )
                    $encoderParameters.Param[0] = $qualityParameter
                    $image.Save($jpegStream, $jpegCodec, $encoderParameters)
                    $jpegBytes = $jpegStream.ToArray()
                }

                if ($useOcr) {
                    try {
                        $ocrLines = @(Get-WindowsOcrLines -Engine $OcrEngine -ImagePath $ImagePaths[$index] -LanguageTag $OcrLanguageTag -SourceWidth $imageWidth -SourceHeight $imageHeight)
                        if ($ocrLines.Count -gt 0) {
                            $ocrPageCount++
                            $ocrLineCount += $ocrLines.Count
                        }
                    }
                    catch {
                        Write-Host ("Warning: OCR failed on page {0}: {1}" -f ($index + 1), $_.Exception.Message) -ForegroundColor Yellow
                        $ocrLines = @()
                    }
                }

                Start-PdfObject $pageObject
                $fontResource = if ($useOcr) { " /Font << /F0 $fontObject 0 R >>" } else { "" }
                Write-PdfAscii ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {0:F2} {1:F2}] /Resources << /XObject << /Im0 {2} 0 R >>{4} >> /Contents {3} 0 R >>`nendobj`n" -f $pageWidth, $pageHeight, $imageObject, $contentObject, $fontResource)

                Start-PdfObject $imageObject
                Write-PdfAscii ("<< /Type /XObject /Subtype /Image /Width {0} /Height {1} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {2} >>`nstream`n" -f $imageWidth, $imageHeight, $jpegBytes.Length)
                $writer.Write($jpegBytes)
                Write-PdfAscii "`nendstream`nendobj`n"

                $contentBuilder = New-Object System.Text.StringBuilder
                [void]$contentBuilder.Append(("q {0:F3} 0 0 {1:F3} {2:F3} {3:F3} cm /Im0 Do Q`n" -f $drawWidth, $drawHeight, $drawX, $drawY))
                foreach ($ocrLine in $ocrLines) {
                    if ([string]::IsNullOrWhiteSpace($ocrLine.Text)) {
                        continue
                    }

                    $textHex = ConvertTo-PdfUnicodeHex -Text $ocrLine.Text
                    if ([string]::IsNullOrWhiteSpace($textHex)) {
                        continue
                    }

                    $textX = $drawX + ($ocrLine.X * $scale)
                    $textY = $drawY + (($imageHeight - $ocrLine.Y - $ocrLine.Height) * $scale)
                    $fontSize = [Math]::Max(1.0, $ocrLine.Height * $scale)
                    $characterCount = [Math]::Max(1, [System.Globalization.StringInfo]::ParseCombiningCharacters($ocrLine.Text).Count)
                    $estimatedWidth = [Math]::Max(1.0, $characterCount * $fontSize)
                    $horizontalScale = [Math]::Min(1000.0, [Math]::Max(10.0, (($ocrLine.Width * $scale) / $estimatedWidth) * 100.0))
                    [void]$contentBuilder.Append(("/Span << /ActualText <FEFF{0}> >> BDC`nBT /F0 {1:F3} Tf 3 Tr {2:F3} Tz 1 0 0 1 {3:F3} {4:F3} Tm <{0}> Tj ET`nEMC`n" -f $textHex, $fontSize, $horizontalScale, $textX, $textY))
                }

                $content = $contentBuilder.ToString()
                $contentBytes = $ascii.GetBytes($content)
                Start-PdfObject $contentObject
                Write-PdfAscii ("<< /Length {0} >>`nstream`n" -f $contentBytes.Length)
                $writer.Write($contentBytes)
                Write-PdfAscii "endstream`nendobj`n"

                $progressInterval = if ($useOcr) { 10 } else { 50 }
                if ((($index + 1) % $progressInterval) -eq 0 -or ($index + 1) -eq $ImagePaths.Count) {
                    $progressLabel = if ($useOcr) { "PDF/OCR" } else { "PDF" }
                    Write-Host ("{0}: added {1}/{2} pages." -f $progressLabel, ($index + 1), $ImagePaths.Count)
                }
            }
            finally {
                if ($null -ne $qualityParameter) { $qualityParameter.Dispose() }
                if ($null -ne $encoderParameters) { $encoderParameters.Dispose() }
                if ($null -ne $jpegStream) { $jpegStream.Dispose() }
                if ($null -ne $image) { $image.Dispose() }
            }
        }

        if ($useOcr) {
            Start-PdfObject $fontObject
            Write-PdfAscii ("<< /Type /Font /Subtype /Type0 /BaseFont /KindleOCR /Encoding /Identity-H /DescendantFonts [{0} 0 R] /ToUnicode {1} 0 R >>`nendobj`n" -f $cidFontObject, $toUnicodeObject)

            Start-PdfObject $cidFontObject
            Write-PdfAscii "<< /Type /Font /Subtype /CIDFontType2 /BaseFont /KindleOCR /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /DW 1000 /CIDToGIDMap /Identity /FontDescriptor << /Type /FontDescriptor /FontName /KindleOCR /Flags 4 /FontBBox [0 -250 1000 1000] /ItalicAngle 0 /Ascent 880 /Descent -120 /CapHeight 700 /StemV 80 >> >>`nendobj`n"

            $toUnicodeCMap = "/CIDInit /ProcSet findresource begin`n12 dict begin`nbegincmap`n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def`n/CMapName /Adobe-Identity-UCS def`n/CMapType 2 def`n1 begincodespacerange`n<0000> <FFFF>`nendcodespacerange`n1 beginbfrange`n<0000> <FFFF> <0000>`nendbfrange`nendcmap`nCMapName currentdict /CMap defineresource pop`nend`nend`n"
            $toUnicodeBytes = $ascii.GetBytes($toUnicodeCMap)
            Start-PdfObject $toUnicodeObject
            Write-PdfAscii ("<< /Length {0} >>`nstream`n" -f $toUnicodeBytes.Length)
            $writer.Write($toUnicodeBytes)
            Write-PdfAscii "endstream`nendobj`n"

            Write-Host ("OCR: added transparent text to {0}/{1} pages ({2} lines)." -f $ocrPageCount, $ImagePaths.Count, $ocrLineCount)
        }

        Start-PdfObject $infoObject
        $creationDate = "D:{0}Z" -f ([DateTime]::UtcNow.ToString("yyyyMMddHHmmss"))
        Write-PdfAscii ("<< /Producer (KindleAutoCapture {0}) /Creator (KindleAutoCapture) /CreationDate ({1}) >>`nendobj`n" -f $script:ToolVersion, $creationDate)

        $xrefPosition = $stream.Position
        Write-PdfAscii "xref`n0 $($objectCount + 1)`n"
        Write-PdfAscii "0000000000 65535 f `n"
        for ($objectNumber = 1; $objectNumber -le $objectCount; $objectNumber++) {
            Write-PdfAscii (("{0:D10} 00000 n `n" -f $offsets[$objectNumber]))
        }
        Write-PdfAscii ("trailer`n<< /Size {0} /Root 1 0 R /Info {2} 0 R >>`nstartxref`n{1}`n%%EOF`n" -f ($objectCount + 1), $xrefPosition, $infoObject)

        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream.Dispose()
        $stream = $null

        if (Test-Path -LiteralPath $finalOutputPath) {
            $backupPath = "$finalOutputPath.previous"
            if (Test-Path -LiteralPath $backupPath) {
                Remove-Item -LiteralPath $backupPath -Force
            }
            [System.IO.File]::Replace($workingOutputPath, $finalOutputPath, $backupPath, $true)
            if (Test-Path -LiteralPath $backupPath) {
                try {
                    Remove-Item -LiteralPath $backupPath -Force
                }
                catch {
                    Write-Warning ("The PDF was replaced successfully, but its temporary backup could not be removed: {0}" -f $backupPath)
                }
            }
        }
        else {
            [System.IO.File]::Move($workingOutputPath, $finalOutputPath)
        }
    }
    catch {
        if ($null -ne $writer) { $writer.Dispose(); $writer = $null }
        if ($null -ne $stream) { $stream.Dispose(); $stream = $null }
        if (Test-Path -LiteralPath $workingOutputPath) {
            Remove-Item -LiteralPath $workingOutputPath -Force
        }
        throw
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $script:LastPdfBuildStats = [PSCustomObject]@{
        Pages = $ImagePaths.Count
        OcrPages = $ocrPageCount
        OcrLines = $ocrLineCount
        Searchable = $useOcr -and $ocrPageCount -gt 0
    }
    return $finalOutputPath
}

$session = $null
$manifestPath = $null
$sleepPreventionEnabled = $false
$outputDirectory = $null

try {
    if (-not [string]::IsNullOrWhiteSpace($RegionSelectionOutputPath)) {
        $selectionTarget = Get-RequestedTargetWindow -ProcessId $TargetProcessId -WindowHandle $TargetWindowHandle
        Ensure-TargetWindowForeground -Handle $selectionTarget.Handle -ExpectedProcessId $selectionTarget.ProcessId
        $selectionRectangle = Select-CaptureRectangle -Handle $selectionTarget.Handle
        if ($null -eq $selectionRectangle) {
            throw "Capture-area selection was cancelled."
        }

        $selectionClientRectangle = Get-ClientScreenRectangle -Handle $selectionTarget.Handle
        $selectionProfile = New-CaptureProfile -ClientRectangle $selectionClientRectangle -CaptureRectangle $selectionRectangle
        $selectionResult = [ordered]@{
            ToolVersion = $script:ToolVersion
            CreatedAt = [DateTime]::Now.ToString("o")
            TargetProcessId = $selectionTarget.ProcessId
            TargetWindowHandle = $selectionTarget.Handle.ToInt64()
            TargetTitle = $selectionTarget.Title
            PixelRectangle = [ordered]@{
                Left = $selectionRectangle.Left
                Top = $selectionRectangle.Top
                Width = $selectionRectangle.Width
                Height = $selectionRectangle.Height
            }
            CaptureProfile = $selectionProfile
        }
        Save-CaptureManifest -Path $RegionSelectionOutputPath -Session $selectionResult
        Write-Host ("Selected area: {0} x {1} pixels." -f $selectionRectangle.Width, $selectionRectangle.Height)
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($RebuildFolder)) {
        $resolvedRebuildFolder = [System.IO.Path]::GetFullPath($RebuildFolder)
        if (-not [System.IO.Directory]::Exists($resolvedRebuildFolder)) {
            throw "The rebuild folder does not exist: $resolvedRebuildFolder"
        }

        if (-not $PSBoundParameters.ContainsKey("OcrMode")) {
            $ocrInput = Read-Host "Add searchable transparent OCR text to the rebuilt PDF? Y/N [Y]"
            if ($ocrInput -match "^[Nn]") { $OcrMode = "Off" } else { $OcrMode = "On" }
        }

        $ocrEngine = $null
        if ($OcrMode -eq "On") {
            try {
                $ocrEngine = Initialize-WindowsOcr -LanguageTag $OcrLanguage
                Write-Host ("OCR: Windows OCR language '{0}' is ready." -f $ocrEngine.RecognizerLanguage.LanguageTag)
            }
            catch {
                Write-Host ("Warning: transparent OCR text is unavailable: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }

        $rebuildImages = @(
            Get-ChildItem -LiteralPath $resolvedRebuildFolder -File |
                Where-Object { $_.Extension -match "^\.(jpg|jpeg|png)$" -and $_.Name -match "^page_\d+" } |
                Sort-Object @{ Expression = { [int64]([regex]::Match($_.BaseName, "^page_(\d+)").Groups[1].Value) } }, Name |
                ForEach-Object { $_.FullName }
        )
        if ($rebuildImages.Count -eq 0) {
            throw "No page_*.jpg, page_*.jpeg, or page_*.png files were found in the rebuild folder."
        }

        $rebuildStamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $rebuildPdfPath = Join-Path $resolvedRebuildFolder ("KindleCapture_Rebuilt_{0}.pdf" -f $rebuildStamp)
        Write-Host ("Rebuilding a PDF from {0} image(s)..." -f $rebuildImages.Count)
        Wait-ForAbortKeyRelease
        [void](New-ImagePdf -ImagePaths $rebuildImages -OutputPath $rebuildPdfPath -OcrEngine $ocrEngine -OcrLanguageTag $OcrLanguage)
        Write-Host "PDF: $rebuildPdfPath"
        if (-not $NoOpenOutput) {
            Start-Process explorer.exe -ArgumentList $resolvedRebuildFolder
        }
        return
    }

    if (-not $PSBoundParameters.ContainsKey("MaxPages")) {
        $MaxPages = Read-IntWithDefault -Prompt "Capture limit (0=until the last page, or enter any page count)" -Default $MaxPages -Minimum 0 -Maximum 2147483647
    }

    if (-not $PSBoundParameters.ContainsKey("Direction")) {
        $directionInput = Read-Host "Page-turn direction: A=Auto, R=Right, L=Left [A]"
        if ($directionInput -match "^[Ll]") {
            $Direction = "Left"
        }
        elseif ($directionInput -match "^[Rr]") {
            $Direction = "Right"
        }
        else {
            $Direction = "Auto"
        }
    }

    if (-not $PSBoundParameters.ContainsKey("CaptureMode")) {
        $captureModeInput = Read-Host "Capture area: A=Auto-detect the Kindle page under the pointer, W=Whole Kindle window [A]"
        if ($captureModeInput -match "^[Ww]") {
            $CaptureMode = "Window"
        }
        else {
            $CaptureMode = "Select"
        }
    }

    if (-not $PSBoundParameters.ContainsKey("SpeedMode")) {
        $speedModeInput = Read-Host "Speed: T=Turbo, B=Balanced, S=Safe [T]"
        if ($speedModeInput -match "^[Ss]") {
            $SpeedMode = "Safe"
        }
        elseif ($speedModeInput -match "^[Bb]") {
            $SpeedMode = "Balanced"
        }
        else {
            $SpeedMode = "Turbo"
        }
    }

    switch ($SpeedMode) {
        "Turbo" {
            $pollInterval = 45
            $stableSamples = 2
            $jpegQuality = 89
            $defaultRenderSettleMilliseconds = 350
        }
        "Balanced" {
            $pollInterval = 75
            $stableSamples = 3
            $jpegQuality = 92
            $defaultRenderSettleMilliseconds = 550
        }
        "Safe" {
            $pollInterval = 120
            $stableSamples = 4
            $jpegQuality = 94
            $defaultRenderSettleMilliseconds = 900
        }
    }

    if (-not $PSBoundParameters.ContainsKey("RenderSettleMilliseconds")) {
        $RenderSettleMilliseconds = Read-IntWithDefault -Prompt "High-resolution settling check after each page turn (0=off, milliseconds)" -Default $defaultRenderSettleMilliseconds -Minimum 0 -Maximum 5000
    }
    elseif ($RenderSettleMilliseconds -lt 0) {
        $RenderSettleMilliseconds = $defaultRenderSettleMilliseconds
    }

    if (-not $PSBoundParameters.ContainsKey("OcrMode")) {
        $ocrInput = Read-Host "Add searchable transparent OCR text to the PDF? Y/N [Y]"
        if ($ocrInput -match "^[Nn]") {
            $OcrMode = "Off"
        }
        else {
            $OcrMode = "On"
        }
    }

    if (-not $PSBoundParameters.ContainsKey("DelayMilliseconds")) {
        $DelayMilliseconds = Read-IntWithDefault -Prompt "Maximum wait for page rendering (milliseconds)" -Default $DelayMilliseconds -Minimum 300 -Maximum 30000
    }

    $resolvedOutputRoot = Resolve-CaptureOutputRoot -Path $OutputRoot
    Write-Host "Output root: $resolvedOutputRoot"

    $ocrEngine = $null
    if ($OcrMode -eq "On") {
        try {
            $ocrEngine = Initialize-WindowsOcr -LanguageTag $OcrLanguage
            Write-Host ("OCR: Windows OCR language '{0}' is ready." -f $ocrEngine.RecognizerLanguage.LanguageTag)
        }
        catch {
            Write-Host ("Warning: transparent OCR text is unavailable: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            Write-Host "The capture will continue and an image-only PDF will be created."
            $OcrMode = "Off"
        }
    }

    Write-Host ""
    Write-Host "Open the first page in Kindle and hide the toolbar."
    Write-Host "Press F12 at any time to stop."
    Write-Host ""

    if ($TargetProcessId -gt 0 -or $TargetWindowHandle -ne 0) {
        $targetWindow = Get-RequestedTargetWindow -ProcessId $TargetProcessId -WindowHandle $TargetWindowHandle
    }
    else {
        $targetWindow = Select-TargetWindow
    }
    $targetHandle = $targetWindow.Handle
    $targetProcessId = $targetWindow.ProcessId
    $targetTitle = $targetWindow.Title
    Write-Host "Selected target: $($targetWindow.ProcessName) - $targetTitle"

    $clientRectangle = Get-ClientScreenRectangle -Handle $targetHandle
    if ($CaptureMode -eq "Select") {
        if (-not [string]::IsNullOrWhiteSpace($CaptureProfilePath)) {
            $captureProfile = Import-CaptureProfile -Path $CaptureProfilePath -ExpectedProcessId $targetProcessId -ExpectedWindowHandle ($targetHandle.ToInt64())
            $captureRectangle = Resolve-CaptureRectangle -Handle $targetHandle -Profile $captureProfile
            Write-Host "Using the area selected in the GUI."
        }
        else {
            Write-Host "Point at the book page and click the automatically highlighted area."
            $captureRectangle = Select-CaptureRectangle -Handle $targetHandle
            if ($null -eq $captureRectangle) {
                throw "Capture-area selection was cancelled."
            }
            $captureProfile = New-CaptureProfile -ClientRectangle $clientRectangle -CaptureRectangle $captureRectangle
        }
    }
    else {
        $captureRectangle = $clientRectangle
        $captureProfile = New-CaptureProfile -ClientRectangle $clientRectangle -CaptureRectangle $captureRectangle
    }

    Write-Host ("Capture area: {0} x {1} at ({2}, {3})" -f $captureRectangle.Width, $captureRectangle.Height, $captureRectangle.Left, $captureRectangle.Top)
    Write-Host ("Speed mode: {0} (poll {1} ms, maximum render wait {2} ms, clarity settle {3} ms)" -f $SpeedMode, $pollInterval, $DelayMilliseconds, $RenderSettleMilliseconds)

    if ($Direction -eq "Auto") {
        Write-Host "Detecting page-turn direction. Start from the first page for reliable detection."
        $Direction = Detect-PageTurnDirection -Handle $targetHandle -ExpectedProcessId $targetProcessId -CaptureRectangle $captureRectangle -Delay $DelayMilliseconds -Threshold $SimilarityThreshold -PollInterval $pollInterval -StableSamples $stableSamples -RenderSettleMilliseconds $RenderSettleMilliseconds
    }

    Write-Host "Page-turn direction: $Direction"

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $outputDirectory = New-CaptureOutputDirectory -Root $resolvedOutputRoot -Timestamp $stamp
    Assert-FreeDiskSpace -OutputDirectory $outputDirectory -PageLimit $MaxPages
    Write-Host "Output folder: $outputDirectory"

    $manifestPath = Join-Path $outputDirectory "capture-session.json"
    $session = [ordered]@{
        ToolVersion = $script:ToolVersion
        StartedAt = [DateTime]::Now.ToString("o")
        UpdatedAt = [DateTime]::Now.ToString("o")
        Status = "Capturing"
        TargetProcess = $targetWindow.ProcessName
        TargetProcessId = $targetProcessId
        TargetTitle = $targetTitle
        Direction = $Direction
        CaptureMode = $CaptureMode
        SpeedMode = $SpeedMode
        RenderSettleMilliseconds = $RenderSettleMilliseconds
        OcrMode = $OcrMode
        OcrLanguage = $OcrLanguage
        OutputRoot = $resolvedOutputRoot
        OutputDirectory = $outputDirectory
        PageLimit = $MaxPages
        SavedPages = 0
        OcrPages = 0
        OcrLines = 0
        CaptureProfile = $captureProfile
        PdfPath = $null
        Error = $null
    }
    Save-CaptureManifest -Path $manifestPath -Session $session

    # PowerShell treats 0x80000003 as a negative Int32, so pass the unsigned value explicitly.
    $executionStateResult = [KindleCaptureNative]::SetThreadExecutionState([uint32]2147483651)
    $sleepPreventionEnabled = $executionStateResult -ne 0
    if (-not $sleepPreventionEnabled) {
        Write-Host "Warning: Windows did not enable sleep prevention." -ForegroundColor Yellow
    }

    Focus-TargetWindow -Handle $targetHandle -CaptureRectangle $captureRectangle -ExpectedProcessId $targetProcessId -ClickPage

    for ($seconds = 3; $seconds -ge 1; $seconds--) {
        Write-Host -NoNewline "`rStarting capture in $seconds second(s)... "
        Start-Sleep -Seconds 1
    }
    Write-Host ""

    $pageTurnDirection = if ($Direction -eq "Left") { "Left" } else { "Right" }
    $previousSignature = $null
    $duplicateCount = 0
    $savedCount = 0
    $imageFiles = New-Object System.Collections.Generic.List[string]
    $captureWatch = [System.Diagnostics.Stopwatch]::StartNew()

    $attempt = 0
    while (($MaxPages -eq 0) -or ($savedCount -lt $MaxPages)) {
        $attempt++
        if (Test-AbortKey) {
            Write-Host "F12 detected. Stopping."
            break
        }

        $captureRectangle = Resolve-CaptureRectangle -Handle $targetHandle -Profile $captureProfile
        Ensure-TargetWindowForeground -Handle $targetHandle -ExpectedProcessId $targetProcessId

        $bitmap = Capture-ScreenRectangle -Rectangle $captureRectangle
        try {
            $currentSignature = Get-CaptureSignature -Rectangle $captureRectangle
            if ($null -ne $previousSignature) {
                $difference = Compare-ImageSignatures -First $previousSignature -Second $currentSignature
            }
            else {
                $difference = [double]::PositiveInfinity
            }

            if ($difference -lt $SimilarityThreshold) {
                $duplicateCount++
                Write-Host ("Similar screen detected ({0}/{1}, difference {2:N1})." -f $duplicateCount, $DuplicateStopCount, $difference)
                if ($duplicateCount -ge $DuplicateStopCount) {
                    Write-Host "The page no longer changes. Stopping automatically."
                    break
                }
            }
            else {
                $duplicateCount = 0
                $savedCount++
                $fileName = "page_{0:D5}.jpg" -f $savedCount
                $filePath = Join-Path $outputDirectory $fileName
                Save-JpegBitmap -Bitmap $bitmap -Path $filePath -Quality $jpegQuality
                $imageFiles.Add($filePath)
                Write-Host ("Saved {0} (difference {1:N1})" -f $fileName, $difference)
                $previousSignature = $currentSignature
                $session.SavedPages = $savedCount
                $session.UpdatedAt = [DateTime]::Now.ToString("o")
                if (($savedCount % 10) -eq 0 -or $savedCount -eq 1) {
                    Save-CaptureManifest -Path $manifestPath -Session $session
                }
                if ($savedCount -eq 1) {
                    $statistics = Get-SignatureStatistics -Signature $currentSignature
                    Write-Host ("Capture check: brightness {0:N1}, contrast {1:N1}." -f $statistics.Mean, $statistics.StandardDeviation)
                    if ($statistics.StandardDeviation -lt 3.0 -or $statistics.Mean -lt 3.0 -or $statistics.Mean -gt 252.0) {
                        Write-Host "Warning: the first capture is nearly blank or uniform. Check the selected region before relying on the result." -ForegroundColor Yellow
                    }
                }
            }
        }
        finally {
            $bitmap.Dispose()
        }

        if ($MaxPages -gt 0 -and $savedCount -ge $MaxPages) {
            Write-Host "Reached the requested number of saved pages."
            break
        }

        Send-PageTurnKey -Direction $pageTurnDirection -Handle $targetHandle -ExpectedProcessId $targetProcessId
        $pageWait = Wait-ForPageReady -Rectangle $captureRectangle -PreviousSignature $previousSignature -MaximumWait $DelayMilliseconds -PollInterval $pollInterval -StableSamples $stableSamples -ChangeThreshold $SimilarityThreshold -RenderSettleMilliseconds $RenderSettleMilliseconds
        if ($pageWait.Aborted) {
            Write-Host "F12 detected. Stopping."
            break
        }
        if ($pageWait.Changed -and -not $pageWait.TimedOut) {
            Write-Host ("Page ready in {0} ms (clarity {1} ms, sharpness {2:N2})." -f $pageWait.ElapsedMilliseconds, $pageWait.ClarityMilliseconds, $pageWait.Sharpness)
            if ($pageWait.ClarityTimedOut) {
                Write-Host "Warning: the clarity check reached its extension limit. Increase the clarity-settle value if the saved page is still soft." -ForegroundColor Yellow
            }
        }
    }

    $captureWatch.Stop()
    Write-Host ""
    Write-Host "Finished. Saved $savedCount image(s)."
    if ($savedCount -gt 0) {
        Write-Host ("Capture time: {0:N1} seconds ({1:N2} seconds/page)." -f $captureWatch.Elapsed.TotalSeconds, ($captureWatch.Elapsed.TotalSeconds / $savedCount))
    }
    Write-Host "Output: $outputDirectory"
    if ($savedCount -gt 0) {
        $session.Status = "BuildingPdf"
        $session.SavedPages = $savedCount
        $session.UpdatedAt = [DateTime]::Now.ToString("o")
        Save-CaptureManifest -Path $manifestPath -Session $session
        $pdfPath = Join-Path $outputDirectory ("KindleCapture_{0}.pdf" -f $stamp)
        if ($null -ne $ocrEngine) {
            Write-Host "Creating a searchable PDF (JPEG passthrough + transparent OCR text)..."
        }
        else {
            Write-Host "Creating a fast image PDF (JPEG passthrough)..."
        }
        $pdfWatch = [System.Diagnostics.Stopwatch]::StartNew()
        Wait-ForAbortKeyRelease
        [void](New-ImagePdf -ImagePaths $imageFiles.ToArray() -OutputPath $pdfPath -OcrEngine $ocrEngine -OcrLanguageTag $OcrLanguage)
        $pdfWatch.Stop()
        Write-Host ("PDF build time: {0:N1} seconds." -f $pdfWatch.Elapsed.TotalSeconds)
        Write-Host "PDF: $pdfPath"
        $session.Status = "Complete"
        $session.PdfPath = $pdfPath
        if ($null -ne $script:LastPdfBuildStats) {
            $session.OcrPages = $script:LastPdfBuildStats.OcrPages
            $session.OcrLines = $script:LastPdfBuildStats.OcrLines
        }
        $session.UpdatedAt = [DateTime]::Now.ToString("o")
        Save-CaptureManifest -Path $manifestPath -Session $session
        if (-not $NoOpenOutput) {
            Start-Process explorer.exe -ArgumentList $outputDirectory
        }
    }
    elseif ($null -ne $session) {
        $session.Status = "NoPages"
        $session.UpdatedAt = [DateTime]::Now.ToString("o")
        Save-CaptureManifest -Path $manifestPath -Session $session
    }
}
catch {
    $capturedError = $_.Exception
    if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and (Test-Path -LiteralPath $outputDirectory)) {
        try {
            $errorLogPath = Join-Path $outputDirectory "capture-error.txt"
            [System.IO.File]::WriteAllText(
                $errorLogPath,
                $capturedError.ToString(),
                (New-Object System.Text.UTF8Encoding $false)
            )
        }
        catch {
            # The console error remains available if writing the diagnostic file fails.
        }
    }
    if ($null -ne $session -and -not [string]::IsNullOrWhiteSpace($manifestPath)) {
        try {
            $session.Status = "Error"
            $session.Error = $capturedError.Message
            $session.UpdatedAt = [DateTime]::Now.ToString("o")
            Save-CaptureManifest -Path $manifestPath -Session $session
        }
        catch {
            # Preserve the original failure even if the diagnostic manifest cannot be updated.
        }
    }
    Write-Host ""
    Write-Host "Error: $($capturedError.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if ($sleepPreventionEnabled) {
        [void][KindleCaptureNative]::SetThreadExecutionState([uint32]2147483648)
    }
    if (-not [string]::IsNullOrWhiteSpace($StopSignalPath) -and [System.IO.File]::Exists($StopSignalPath)) {
        try { Remove-Item -LiteralPath $StopSignalPath -Force } catch { }
    }
}

