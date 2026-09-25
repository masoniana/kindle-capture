param([switch]$SmokeTest)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

$coreScript = Join-Path $PSScriptRoot "KindleCapture-Core.ps1"
if (-not (Test-Path -LiteralPath $coreScript)) {
    $coreScript = Join-Path $PSScriptRoot "KindleAutoCapture.ps1"
}
if (-not (Test-Path -LiteralPath $coreScript)) {
    [void][System.Windows.Forms.MessageBox]::Show(
        "Kindle Capture の内部ファイルが見つかりません。EXEを再度ダウンロードしてください。",
        "Kindle Capture",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}

$script:CaptureProcess = $null
$script:StopSignalPath = $null
$script:StandardLogPath = $null
$script:ErrorLogPath = $null
$script:LastLogText = ""
$script:CaptureProfilePath = $null
$script:CaptureProfileTargetHandle = 0

function New-GuiLabel {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 180,
        [int]$Height = 24
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point $X, $Y
    $label.Size = New-Object System.Drawing.Size $Width, $Height
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    return $label
}

function Read-SharedText {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.File]::Exists($Path)) {
        return ""
    }

    $stream = $null
    $reader = $null
    try {
        $stream = New-Object System.IO.FileStream (
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $reader = New-Object System.IO.StreamReader $stream, ([System.Text.Encoding]::UTF8), $true
        return $reader.ReadToEnd()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-VisibleWindowCandidates {
    return @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.MainWindowHandle -ne [IntPtr]::Zero -and
                $_.ProcessName -notmatch "^(cmd|powershell|pwsh|WindowsTerminal)$"
            } |
            ForEach-Object {
                $title = $_.MainWindowTitle
                if ([string]::IsNullOrWhiteSpace($title)) { $title = "(タイトルなし)" }
                [PSCustomObject]@{
                    Display = "{0} — {1}" -f $_.ProcessName, $title
                    ProcessName = $_.ProcessName
                    ProcessId = $_.Id
                    WindowHandle = $_.MainWindowHandle.ToInt64()
                    IsKindle = ($_.ProcessName -match "Kindle" -or $title -match "Kindle")
                }
            } |
            Sort-Object @{ Expression = { if ($_.IsKindle) { 0 } else { 1 } } }, ProcessName, Display
    )
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Kindle Capture 2.4.2"
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object System.Drawing.Size 860, 825
$form.MinimumSize = New-Object System.Drawing.Size 860, 825
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Font = New-Object System.Drawing.Font "Segoe UI", 9

$titleLabel = New-GuiLabel -Text "Kindle Capture" -X 20 -Y 14 -Width 420 -Height 34
$titleLabel.Font = New-Object System.Drawing.Font "Segoe UI", 18, ([System.Drawing.FontStyle]::Bold)
$form.Controls.Add($titleLabel)

$subtitleLabel = New-GuiLabel -Text "指定範囲をページごとに自動キャプチャし、高解像度化を確認して保存します" -X 22 -Y 48 -Width 760 -Height 24
$subtitleLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($subtitleLabel)

$form.Controls.Add((New-GuiLabel -Text "対象ウィンドウ" -X 22 -Y 82 -Width 110))
$targetCombo = New-Object System.Windows.Forms.ComboBox
$targetCombo.Location = New-Object System.Drawing.Point 135, 82
$targetCombo.Size = New-Object System.Drawing.Size 575, 26
$targetCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$targetCombo.DisplayMember = "Display"
$targetCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($targetCombo)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "再読込"
$refreshButton.Location = New-Object System.Drawing.Point 720, 80
$refreshButton.Size = New-Object System.Drawing.Size 105, 30
$refreshButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($refreshButton)

$settingsGroup = New-Object System.Windows.Forms.GroupBox
$settingsGroup.Text = "キャプチャ設定"
$settingsGroup.Location = New-Object System.Drawing.Point 20, 122
$settingsGroup.Size = New-Object System.Drawing.Size 805, 318
$settingsGroup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($settingsGroup)

$settingsGroup.Controls.Add((New-GuiLabel -Text "保存ページ数（0=最後まで）" -X 20 -Y 30 -Width 190))
$maxPagesControl = New-Object System.Windows.Forms.NumericUpDown
$maxPagesControl.Location = New-Object System.Drawing.Point 215, 32
$maxPagesControl.Size = New-Object System.Drawing.Size 150, 24
$maxPagesControl.Minimum = 0
$maxPagesControl.Maximum = 2147483647
$maxPagesControl.Value = 1500
$settingsGroup.Controls.Add($maxPagesControl)

$settingsGroup.Controls.Add((New-GuiLabel -Text "ページ送り方向" -X 20 -Y 72 -Width 190))
$directionCombo = New-Object System.Windows.Forms.ComboBox
$directionCombo.Location = New-Object System.Drawing.Point 215, 74
$directionCombo.Size = New-Object System.Drawing.Size 150, 24
$directionCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$directionCombo.Items.AddRange(@("Auto", "Right", "Left"))
$directionCombo.SelectedIndex = 0
$settingsGroup.Controls.Add($directionCombo)

$settingsGroup.Controls.Add((New-GuiLabel -Text "キャプチャ範囲" -X 20 -Y 114 -Width 190))
$captureModeCombo = New-Object System.Windows.Forms.ComboBox
$captureModeCombo.Location = New-Object System.Drawing.Point 215, 116
$captureModeCombo.Size = New-Object System.Drawing.Size 150, 24
$captureModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$captureModeCombo.DisplayMember = "Display"
[void]$captureModeCombo.Items.Add([PSCustomObject]@{ Display = "カーソル自動指定"; Value = "Select" })
[void]$captureModeCombo.Items.Add([PSCustomObject]@{ Display = "ウィンドウ全体"; Value = "Window" })
$captureModeCombo.SelectedIndex = 0
$settingsGroup.Controls.Add($captureModeCombo)

$settingsGroup.Controls.Add((New-GuiLabel -Text "速度モード" -X 20 -Y 156 -Width 190))
$speedModeCombo = New-Object System.Windows.Forms.ComboBox
$speedModeCombo.Location = New-Object System.Drawing.Point 215, 158
$speedModeCombo.Size = New-Object System.Drawing.Size 150, 24
$speedModeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$speedModeCombo.Items.AddRange(@("Turbo", "Balanced", "Safe"))
$speedModeCombo.SelectedIndex = 0
$settingsGroup.Controls.Add($speedModeCombo)

$settingsGroup.Controls.Add((New-GuiLabel -Text "ぼやけ防止待ち（ms）" -X 20 -Y 198 -Width 190))
$clarityControl = New-Object System.Windows.Forms.NumericUpDown
$clarityControl.Location = New-Object System.Drawing.Point 215, 200
$clarityControl.Size = New-Object System.Drawing.Size 150, 24
$clarityControl.Minimum = 0
$clarityControl.Maximum = 5000
$clarityControl.Increment = 50
$clarityControl.Value = 350
$settingsGroup.Controls.Add($clarityControl)

$settingsGroup.Controls.Add((New-GuiLabel -Text "ページ描画の最大待ち（ms）" -X 20 -Y 240 -Width 190))
$delayControl = New-Object System.Windows.Forms.NumericUpDown
$delayControl.Location = New-Object System.Drawing.Point 215, 242
$delayControl.Size = New-Object System.Drawing.Size 150, 24
$delayControl.Minimum = 300
$delayControl.Maximum = 30000
$delayControl.Increment = 100
$delayControl.Value = 1500
$settingsGroup.Controls.Add($delayControl)

$settingsGroup.Controls.Add((New-GuiLabel -Text "同一画面で停止する回数" -X 410 -Y 30 -Width 190))
$duplicateControl = New-Object System.Windows.Forms.NumericUpDown
$duplicateControl.Location = New-Object System.Drawing.Point 615, 32
$duplicateControl.Size = New-Object System.Drawing.Size 150, 24
$duplicateControl.Minimum = 1
$duplicateControl.Maximum = 10
$duplicateControl.Value = 3
$settingsGroup.Controls.Add($duplicateControl)

$settingsGroup.Controls.Add((New-GuiLabel -Text "類似判定しきい値" -X 410 -Y 72 -Width 190))
$similarityControl = New-Object System.Windows.Forms.NumericUpDown
$similarityControl.Location = New-Object System.Drawing.Point 615, 74
$similarityControl.Size = New-Object System.Drawing.Size 150, 24
$similarityControl.Minimum = [decimal]0.1
$similarityControl.Maximum = [decimal]50.0
$similarityControl.DecimalPlaces = 1
$similarityControl.Increment = [decimal]0.1
$similarityControl.Value = [decimal]1.0
$settingsGroup.Controls.Add($similarityControl)

$ocrCheck = New-Object System.Windows.Forms.CheckBox
$ocrCheck.Text = "PDFに透明OCRテキストを付ける"
$ocrCheck.Location = New-Object System.Drawing.Point 410, 116
$ocrCheck.Size = New-Object System.Drawing.Size 340, 26
$ocrCheck.Checked = $true
$settingsGroup.Controls.Add($ocrCheck)

$settingsGroup.Controls.Add((New-GuiLabel -Text "OCR言語" -X 410 -Y 156 -Width 190))
$ocrLanguageText = New-Object System.Windows.Forms.TextBox
$ocrLanguageText.Location = New-Object System.Drawing.Point 615, 158
$ocrLanguageText.Size = New-Object System.Drawing.Size 150, 24
$ocrLanguageText.Text = "ja"
$settingsGroup.Controls.Add($ocrLanguageText)

$qualityHint = New-GuiLabel -Text "ぼやける場合は 500～800msへ。0にすると輪郭確認を省略して最速になります。" -X 410 -Y 198 -Width 365 -Height 42
$qualityHint.ForeColor = [System.Drawing.Color]::DimGray
$settingsGroup.Controls.Add($qualityHint)

$selectRegionButton = New-Object System.Windows.Forms.Button
$selectRegionButton.Text = "画面部分を自動指定"
$selectRegionButton.Location = New-Object System.Drawing.Point 410, 246
$selectRegionButton.Size = New-Object System.Drawing.Size 145, 32
$settingsGroup.Controls.Add($selectRegionButton)

$selectedRegionLabel = New-GuiLabel -Text "未指定（開始時に自動指定できます）" -X 565 -Y 244 -Width 210 -Height 38
$selectedRegionLabel.ForeColor = [System.Drawing.Color]::DimGray
$settingsGroup.Controls.Add($selectedRegionLabel)

$areaHint = New-GuiLabel -Text "Kindle本文にカーソルを合わせてクリックすると、画面部分を枠に沿って自動指定します。" -X 20 -Y 286 -Width 760 -Height 26
$areaHint.ForeColor = [System.Drawing.Color]::DimGray
$settingsGroup.Controls.Add($areaHint)

$form.Controls.Add((New-GuiLabel -Text "保存先" -X 22 -Y 458 -Width 110))
$outputFolderText = New-Object System.Windows.Forms.TextBox
$outputFolderText.Location = New-Object System.Drawing.Point 135, 456
$outputFolderText.Size = New-Object System.Drawing.Size 575, 26
$documentsFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
$defaultOutputRoot = if ([string]::IsNullOrWhiteSpace($documentsFolder)) { $PSScriptRoot } else { Join-Path $documentsFolder "KindleCapture" }
$outputFolderText.Text = $defaultOutputRoot
$outputFolderText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($outputFolderText)

$browseOutputButton = New-Object System.Windows.Forms.Button
$browseOutputButton.Text = "参照…"
$browseOutputButton.Location = New-Object System.Drawing.Point 720, 454
$browseOutputButton.Size = New-Object System.Drawing.Size 105, 30
$browseOutputButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($browseOutputButton)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "キャプチャ開始"
$startButton.Location = New-Object System.Drawing.Point 20, 503
$startButton.Size = New-Object System.Drawing.Size 170, 38
$startButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$startButton.ForeColor = [System.Drawing.Color]::White
$startButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$form.Controls.Add($startButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "停止"
$stopButton.Location = New-Object System.Drawing.Point 202, 503
$stopButton.Size = New-Object System.Drawing.Size 100, 38
$stopButton.Enabled = $false
$form.Controls.Add($stopButton)

$rebuildButton = New-Object System.Windows.Forms.Button
$rebuildButton.Text = "画像からPDF再作成"
$rebuildButton.Location = New-Object System.Drawing.Point 314, 503
$rebuildButton.Size = New-Object System.Drawing.Size 170, 38
$form.Controls.Add($rebuildButton)

$statusLabel = New-GuiLabel -Text "待機中" -X 500 -Y 507 -Width 320 -Height 32
$statusLabel.Font = New-Object System.Drawing.Font "Segoe UI", 10, ([System.Drawing.FontStyle]::Bold)
$statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($statusLabel)

$logText = New-Object System.Windows.Forms.TextBox
$logText.Location = New-Object System.Drawing.Point 20, 552
$logText.Size = New-Object System.Drawing.Size 805, 225
$logText.Multiline = $true
$logText.ReadOnly = $true
$logText.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$logText.Font = New-Object System.Drawing.Font "Consolas", 9
$logText.BackColor = [System.Drawing.Color]::White
$logText.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($logText)

function Refresh-WindowList {
    $previousHandle = 0
    if ($null -ne $targetCombo.SelectedItem) {
        $previousHandle = $targetCombo.SelectedItem.WindowHandle
    }

    $targetCombo.BeginUpdate()
    try {
        $targetCombo.Items.Clear()
        $candidates = @(Get-VisibleWindowCandidates)
        foreach ($candidate in $candidates) {
            [void]$targetCombo.Items.Add($candidate)
        }
        if ($targetCombo.Items.Count -gt 0) {
            $selectedIndex = 0
            for ($index = 0; $index -lt $targetCombo.Items.Count; $index++) {
                if ($targetCombo.Items[$index].WindowHandle -eq $previousHandle) {
                    $selectedIndex = $index
                    break
                }
            }
            $targetCombo.SelectedIndex = $selectedIndex
        }
    }
    finally {
        $targetCombo.EndUpdate()
    }
}

function Set-RunningState {
    param([bool]$Running)
    $settingsGroup.Enabled = -not $Running
    $targetCombo.Enabled = -not $Running
    $refreshButton.Enabled = -not $Running
    $outputFolderText.Enabled = -not $Running
    $browseOutputButton.Enabled = -not $Running
    $startButton.Enabled = -not $Running
    $rebuildButton.Enabled = -not $Running
    $stopButton.Enabled = $Running
}

function Get-SelectedCaptureMode {
    if ($null -eq $captureModeCombo.SelectedItem) {
        return "Select"
    }
    return [string]$captureModeCombo.SelectedItem.Value
}

function Remove-CaptureProfile {
    $profilePath = $script:CaptureProfilePath
    $script:CaptureProfilePath = $null
    $script:CaptureProfileTargetHandle = 0

    if (-not [string]::IsNullOrWhiteSpace($profilePath)) {
        try {
            $resolvedProfilePath = [System.IO.Path]::GetFullPath($profilePath)
            $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
            $profileName = [System.IO.Path]::GetFileName($resolvedProfilePath)
            if ($resolvedProfilePath.StartsWith($temporaryRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
                $profileName -like "KindleCapture_region_*.json" -and
                [System.IO.File]::Exists($resolvedProfilePath)) {
                [System.IO.File]::Delete($resolvedProfilePath)
            }
        }
        catch {
            # A stale temporary profile is harmless and can be cleaned by Windows later.
        }
    }

    $selectedRegionLabel.Text = "未指定（開始時に自動指定できます）"
    $selectedRegionLabel.ForeColor = [System.Drawing.Color]::DimGray
}

function Update-CaptureModeControls {
    $isSelectMode = (Get-SelectedCaptureMode) -eq "Select"
    $selectRegionButton.Enabled = $isSelectMode -and ($null -eq $script:CaptureProcess -or $script:CaptureProcess.HasExited)
    if (-not $isSelectMode) {
        $selectedRegionLabel.Text = "ウィンドウ全体を使用"
        $selectedRegionLabel.ForeColor = [System.Drawing.Color]::DimGray
    }
    elseif (-not [string]::IsNullOrWhiteSpace($script:CaptureProfilePath)) {
        try {
            $profileData = Get-Content -LiteralPath $script:CaptureProfilePath -Raw | ConvertFrom-Json
            $selectedRegionLabel.Text = "指定済み：{0} x {1} px" -f $profileData.PixelRectangle.Width, $profileData.PixelRectangle.Height
            $selectedRegionLabel.ForeColor = [System.Drawing.Color]::ForestGreen
        }
        catch {
            Remove-CaptureProfile
        }
    }
    else {
        $selectedRegionLabel.Text = "未指定（開始時に自動指定できます）"
        $selectedRegionLabel.ForeColor = [System.Drawing.Color]::DimGray
    }
}

function Invoke-RegionSelection {
    if ($targetCombo.SelectedIndex -lt 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "対象のKindleウィンドウを選択してください。",
            "Kindle Capture",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        return $false
    }

    $target = $targetCombo.SelectedItem
    $selectionId = [Guid]::NewGuid().ToString("N")
    $temporaryRoot = [System.IO.Path]::GetTempPath()
    $newProfilePath = Join-Path $temporaryRoot "KindleCapture_region_$selectionId.json"
    $selectionLogPath = Join-Path $temporaryRoot "KindleCapture_region_$selectionId.log"
    $selectionErrorPath = Join-Path $temporaryRoot "KindleCapture_region_$selectionId.err"
    $selectionProcess = $null
    $selectionSucceeded = $false

    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", (Quote-ProcessArgument $coreScript),
        "-TargetProcessId", ([int]$target.ProcessId),
        "-TargetWindowHandle", ([long]$target.WindowHandle),
        "-RegionSelectionOutputPath", (Quote-ProcessArgument $newProfilePath)
    ) -join " "

    try {
        $selectRegionButton.Enabled = $false
        $startButton.Enabled = $false
        $targetCombo.Enabled = $false
        $refreshButton.Enabled = $false
        $statusLabel.Text = "Kindle本文にカーソルを合わせ、緑の自動検出枠をクリックしてください"
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()

        $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $selectionProcess = Start-Process `
            -FilePath $powershellPath `
            -ArgumentList $arguments `
            -WindowStyle Hidden `
            -RedirectStandardOutput $selectionLogPath `
            -RedirectStandardError $selectionErrorPath `
            -Wait `
            -PassThru

        $selectionOutput = Read-SharedText -Path $selectionLogPath
        $selectionError = Read-SharedText -Path $selectionErrorPath
        if (-not [System.IO.File]::Exists($newProfilePath)) {
            if (($selectionOutput + $selectionError) -match "selection was cancelled") {
                $statusLabel.Text = "範囲指定をキャンセルしました"
                return $false
            }

            $details = $selectionError.Trim()
            $trimmedOutput = $selectionOutput.Trim()
            if ([string]::IsNullOrWhiteSpace($details) -and
                -not [string]::IsNullOrWhiteSpace($trimmedOutput) -and
                $trimmedOutput -notmatch "(?im)^\s*Selected area:\s*\d+\s*x\s*\d+\s*pixels\.\s*$") {
                $details = $trimmedOutput
            }
            if ([string]::IsNullOrWhiteSpace($details)) {
                $details = "キャプチャ範囲の設定を保存できませんでした。もう一度指定してください。"
            }
            throw $details
        }

        $profileData = Get-Content -LiteralPath $newProfilePath -Raw | ConvertFrom-Json
        if ([int]$profileData.TargetProcessId -ne [int]$target.ProcessId -or
            [long]$profileData.TargetWindowHandle -ne [long]$target.WindowHandle -or
            [int]$profileData.PixelRectangle.Width -lt 100 -or
            [int]$profileData.PixelRectangle.Height -lt 100) {
            throw "保存されたキャプチャ範囲が対象ウィンドウと一致しません。"
        }

        Remove-CaptureProfile
        $script:CaptureProfilePath = $newProfilePath
        $script:CaptureProfileTargetHandle = [long]$target.WindowHandle
        $selectionSucceeded = $true
        $selectedRegionLabel.Text = "指定済み：{0} x {1} px" -f $profileData.PixelRectangle.Width, $profileData.PixelRectangle.Height
        $selectedRegionLabel.ForeColor = [System.Drawing.Color]::ForestGreen
        $statusLabel.Text = "キャプチャ範囲を指定しました"
        return $true
    }
    catch {
        $statusLabel.Text = "範囲指定に失敗しました"
        [void][System.Windows.Forms.MessageBox]::Show(
            $_.Exception.Message,
            "Kindle Capture",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return $false
    }
    finally {
        if ($null -ne $selectionProcess) {
            $selectionProcess.Dispose()
        }
        foreach ($path in @($selectionLogPath, $selectionErrorPath)) {
            if ([System.IO.File]::Exists($path)) {
                try { [System.IO.File]::Delete($path) } catch { }
            }
        }
        if (-not $selectionSucceeded -and [System.IO.File]::Exists($newProfilePath)) {
            try { [System.IO.File]::Delete($newProfilePath) } catch { }
        }
        $targetCombo.Enabled = $true
        $refreshButton.Enabled = $true
        $startButton.Enabled = $true
        Update-CaptureModeControls
        $form.TopMost = $true
        [void]$form.Activate()
        $form.BringToFront()
        [System.Windows.Forms.Application]::DoEvents()
        $form.TopMost = $false
    }
}

function Update-LogView {
    $standardText = Read-SharedText -Path $script:StandardLogPath
    $errorText = Read-SharedText -Path $script:ErrorLogPath
    $combined = $standardText
    if (-not [string]::IsNullOrWhiteSpace($errorText)) {
        $combined += "`r`n[エラー出力]`r`n$errorText"
    }
    if ($combined -ne $script:LastLogText) {
        $script:LastLogText = $combined
        $logText.Text = $combined
        $logText.SelectionStart = $logText.TextLength
        $logText.ScrollToCaret()
    }
}

$refreshButton.Add_Click({ Refresh-WindowList })
$browseOutputButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "キャプチャ画像とPDFを保存するフォルダーを選択してください。"
    $dialog.ShowNewFolderButton = $true
    if ([System.IO.Directory]::Exists($outputFolderText.Text)) {
        $dialog.SelectedPath = [System.IO.Path]::GetFullPath($outputFolderText.Text)
    }
    try {
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $outputFolderText.Text = $dialog.SelectedPath
        }
    }
    finally {
        $dialog.Dispose()
    }
})
$targetCombo.Add_SelectedIndexChanged({
    if (-not [string]::IsNullOrWhiteSpace($script:CaptureProfilePath) -and
        ($null -eq $targetCombo.SelectedItem -or [long]$targetCombo.SelectedItem.WindowHandle -ne $script:CaptureProfileTargetHandle)) {
        Remove-CaptureProfile
    }
})
$captureModeCombo.Add_SelectedIndexChanged({ Update-CaptureModeControls })
$selectRegionButton.Add_Click({ [void](Invoke-RegionSelection) })
$ocrCheck.Add_CheckedChanged({ $ocrLanguageText.Enabled = $ocrCheck.Checked })
$speedModeCombo.Add_SelectedIndexChanged({
    switch ([string]$speedModeCombo.SelectedItem) {
        "Balanced" { $clarityControl.Value = 550 }
        "Safe" { $clarityControl.Value = 900 }
        default { $clarityControl.Value = 350 }
    }
})

$rebuildButton.Add_Click({
    if ($ocrCheck.Checked -and [string]::IsNullOrWhiteSpace($ocrLanguageText.Text)) {
        [void][System.Windows.Forms.MessageBox]::Show("OCR言語を入力してください。日本語は ja です。", "Kindle Capture")
        return
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "page_*.jpg が保存されている captures フォルダーを選択してください。"
    $dialog.ShowNewFolderButton = $false
    if ([System.IO.Directory]::Exists($outputFolderText.Text)) {
        $dialog.SelectedPath = [System.IO.Path]::GetFullPath($outputFolderText.Text)
    }
    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }
        $rebuildFolder = $dialog.SelectedPath
    }
    finally {
        $dialog.Dispose()
    }

    if (@(Get-ChildItem -LiteralPath $rebuildFolder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^page_\d+\.(jpg|jpeg|png)$" }).Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "選択したフォルダーに page_*.jpg / jpeg / png がありません。",
            "Kindle Capture",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $runId = [Guid]::NewGuid().ToString("N")
    $temporaryRoot = [System.IO.Path]::GetTempPath()
    $script:StopSignalPath = Join-Path $temporaryRoot "KindleCapture_$runId.stop"
    $script:StandardLogPath = Join-Path $temporaryRoot "KindleCapture_$runId.log"
    $script:ErrorLogPath = Join-Path $temporaryRoot "KindleCapture_$runId.err"
    foreach ($path in @($script:StopSignalPath, $script:StandardLogPath, $script:ErrorLogPath)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }

    $ocrMode = if ($ocrCheck.Checked) { "On" } else { "Off" }
    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", (Quote-ProcessArgument $coreScript),
        "-RebuildFolder", (Quote-ProcessArgument $rebuildFolder),
        "-OcrMode", $ocrMode,
        "-OcrLanguage", (Quote-ProcessArgument $ocrLanguageText.Text.Trim()),
        "-StopSignalPath", (Quote-ProcessArgument $script:StopSignalPath)
    ) -join " "

    try {
        $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $script:CaptureProcess = Start-Process `
            -FilePath $powershellPath `
            -ArgumentList $arguments `
            -WindowStyle Hidden `
            -RedirectStandardOutput $script:StandardLogPath `
            -RedirectStandardError $script:ErrorLogPath `
            -PassThru
        $script:LastLogText = ""
        $logText.Clear()
        $statusLabel.Text = "PDF再作成中"
        Set-RunningState -Running $true
    }
    catch {
        $script:CaptureProcess = $null
        Set-RunningState -Running $false
        $statusLabel.Text = "起動失敗"
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Kindle Capture", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

$startButton.Add_Click({
    if ($targetCombo.SelectedIndex -lt 0) {
        [void][System.Windows.Forms.MessageBox]::Show("対象のKindleウィンドウを選択してください。", "Kindle Capture")
        return
    }
    if ($ocrCheck.Checked -and [string]::IsNullOrWhiteSpace($ocrLanguageText.Text)) {
        [void][System.Windows.Forms.MessageBox]::Show("OCR言語を入力してください。日本語は ja です。", "Kindle Capture")
        return
    }

    try {
        $outputRootText = $outputFolderText.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($outputRootText)) {
            $outputRootText = $defaultOutputRoot
        }
        $outputRoot = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($outputRootText))
        if ([System.IO.File]::Exists($outputRoot)) {
            throw "保存先にはファイルではなくフォルダーを指定してください。"
        }
        $outputFolderText.Text = $outputRoot
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "保存先を確認してください。`r`n`r`n$($_.Exception.Message)",
            "Kindle Capture",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        return
    }

    $target = $targetCombo.SelectedItem
    $captureMode = Get-SelectedCaptureMode
    if ($captureMode -eq "Select" -and
        ([string]::IsNullOrWhiteSpace($script:CaptureProfilePath) -or
         -not [System.IO.File]::Exists($script:CaptureProfilePath) -or
         $script:CaptureProfileTargetHandle -ne [long]$target.WindowHandle)) {
        if (-not (Invoke-RegionSelection)) {
            return
        }
    }

    $runId = [Guid]::NewGuid().ToString("N")
    $temporaryRoot = [System.IO.Path]::GetTempPath()
    $script:StopSignalPath = Join-Path $temporaryRoot "KindleCapture_$runId.stop"
    $script:StandardLogPath = Join-Path $temporaryRoot "KindleCapture_$runId.log"
    $script:ErrorLogPath = Join-Path $temporaryRoot "KindleCapture_$runId.err"
    foreach ($path in @($script:StopSignalPath, $script:StandardLogPath, $script:ErrorLogPath)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }

    $ocrMode = if ($ocrCheck.Checked) { "On" } else { "Off" }
    $similarityText = $similarityControl.Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", (Quote-ProcessArgument $coreScript),
        "-MaxPages", ([int]$maxPagesControl.Value),
        "-Direction", ([string]$directionCombo.SelectedItem),
        "-CaptureMode", $captureMode,
        "-SpeedMode", ([string]$speedModeCombo.SelectedItem),
        "-OcrMode", $ocrMode,
        "-OcrLanguage", (Quote-ProcessArgument $ocrLanguageText.Text.Trim()),
        "-OutputRoot", (Quote-ProcessArgument $outputRoot),
        "-DelayMilliseconds", ([int]$delayControl.Value),
        "-RenderSettleMilliseconds", ([int]$clarityControl.Value),
        "-DuplicateStopCount", ([int]$duplicateControl.Value),
        "-SimilarityThreshold", $similarityText,
        "-TargetProcessId", ([int]$target.ProcessId),
        "-TargetWindowHandle", ([long]$target.WindowHandle),
        "-StopSignalPath", (Quote-ProcessArgument $script:StopSignalPath)
    )
    if ($captureMode -eq "Select") {
        $arguments += @("-CaptureProfilePath", (Quote-ProcessArgument $script:CaptureProfilePath))
    }
    $arguments = $arguments -join " "

    try {
        $powershellPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $script:CaptureProcess = Start-Process `
            -FilePath $powershellPath `
            -ArgumentList $arguments `
            -WindowStyle Hidden `
            -RedirectStandardOutput $script:StandardLogPath `
            -RedirectStandardError $script:ErrorLogPath `
            -PassThru
        $script:LastLogText = ""
        $logText.Clear()
        $statusLabel.Text = "キャプチャ中 — Kindleを操作しないでください"
        Set-RunningState -Running $true
    }
    catch {
        $script:CaptureProcess = $null
        Set-RunningState -Running $false
        $statusLabel.Text = "起動失敗"
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Kindle Capture", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

$stopButton.Add_Click({
    if ($null -ne $script:CaptureProcess -and -not $script:CaptureProcess.HasExited) {
        [System.IO.File]::WriteAllText($script:StopSignalPath, [DateTime]::Now.ToString("o"))
        $statusLabel.Text = "停止要求を送信しました…"
        $stopButton.Enabled = $false
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    Update-LogView
    if ($null -ne $script:CaptureProcess -and $script:CaptureProcess.HasExited) {
        $exitCode = $script:CaptureProcess.ExitCode
        Update-LogView
        if ($exitCode -eq 0) {
            $statusLabel.Text = "完了"
        }
        else {
            $statusLabel.Text = "エラー終了 — ログを確認してください"
        }
        Set-RunningState -Running $false
        $script:CaptureProcess.Dispose()
        $script:CaptureProcess = $null
    }
})
$timer.Start()

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($null -ne $script:CaptureProcess -and -not $script:CaptureProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "実行中の処理を停止して設定画面を閉じますか？",
            "Kindle Capture",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }
        try { [System.IO.File]::WriteAllText($script:StopSignalPath, [DateTime]::Now.ToString("o")) } catch { }
    }
})

Refresh-WindowList
Update-CaptureModeControls
if ($SmokeTest) {
    foreach ($parent in @($form, $settingsGroup)) {
        foreach ($control in $parent.Controls) {
            if ($control.Left -lt 0 -or $control.Top -lt 0 -or $control.Right -gt $parent.ClientSize.Width -or $control.Bottom -gt $parent.ClientSize.Height) {
                throw ("GUI control is outside its parent: {0} ({1})" -f $control.Name, $control.Text)
            }
        }
    }
    if ($targetCombo.Items.Count -eq 0) { throw "The GUI could not enumerate any visible windows." }
    $kindleCandidateCount = @($targetCombo.Items | Where-Object { $_.IsKindle }).Count
    if ($kindleCandidateCount -gt 0 -and -not $targetCombo.SelectedItem.IsKindle) {
        throw "A Kindle window exists but was not selected first."
    }
    if ([string]::IsNullOrWhiteSpace($outputFolderText.Text) -or -not [System.IO.Path]::IsPathRooted($outputFolderText.Text)) {
        throw "The GUI output folder is not initialized to an absolute path."
    }
    Write-Output ("GUI smoke test OK: windows={0}, clarity={1}, speed={2}, output={3}" -f $targetCombo.Items.Count, $clarityControl.Value, $speedModeCombo.SelectedItem, $outputFolderText.Text)
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()
    return
}

[void]$form.ShowDialog()
$timer.Stop()
$timer.Dispose()
$form.Dispose()

if ($null -eq $script:CaptureProcess -or $script:CaptureProcess.HasExited) {
    foreach ($path in @($script:StopSignalPath, $script:StandardLogPath, $script:ErrorLogPath)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            try { Remove-Item -LiteralPath $path -Force } catch { }
        }
    }
    Remove-CaptureProfile
}
