<#
================================================================================
 LogiSwitchApp.ps1  -  LogiSwitch 데스크톱 앱
================================================================================
 스크립트를 편집하지 않고 클릭만으로 설정하고 실행한다.
 설정은 %APPDATA%\LogiSwitch\config.json 에 저장된다.

 실행:  바로가기(LogiSwitch 시작.cmd) 를 더블클릭하거나
        powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitchApp.ps1
================================================================================
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Continue'

# ------------------------------------------------------------------- 설정 저장

$ConfigDir  = Join-Path $env:APPDATA 'LogiSwitch'
$ConfigPath = Join-Path $ConfigDir 'config.json'

function New-DefaultConfig {
    @{
        KeyboardInstanceId           = ''
        KeyboardNamePattern          = ''
        DetectMethod                 = 'Auto'
        DetectPropertyKey            = ''
        DetectPropertyConnectedValue = ''
        MouseDeviceIndex             = 1
        TargetHostIndex              = 1
        FeatureIndex                 = 0
        ForceHidPath                 = ''
        VendorId                     = 0x046D
        SoftwareId                   = 0x0D
        PollIntervalMs               = 500
        RearmDelayMs                 = 3000
        IgnoreShorterThanMs          = 0
    }
}

function Import-AppConfig {
    $cfg = New-DefaultConfig
    if (Test-Path $ConfigPath) {
        try {
            $j = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) {
                if ($null -ne $j.$k) { $cfg[$k] = $j.$k }
            }
        } catch { }
    }
    return $cfg
}

function Export-AppConfig {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        ($Config | ConvertTo-Json) | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch {
        Write-AppLog "설정 저장 실패: $($_.Exception.Message)"
    }
}

# 코어가 $Config 를 참조하므로 점 소싱 전에 준비해 둔다
$Config = Import-AppConfig
. "$PSScriptRoot\LogiSwitchCore.ps1"
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------- 상태

$script:Watching       = $false
$script:PrevConnected  = $null
$script:SuppressUntil  = [DateTime]::MinValue
$script:BtDevices      = @()

# ------------------------------------------------------------------------ UI

function New-Dot([System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $br = New-Object System.Drawing.SolidBrush $c
    $g.FillEllipse($br, 2, 2, 12, 12)
    $br.Dispose(); $g.Dispose()
    $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    return $ico
}

$IconOn  = New-Dot ([System.Drawing.Color]::FromArgb(46, 160, 67))
$IconOff = New-Dot ([System.Drawing.Color]::FromArgb(150, 150, 150))

$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'LogiSwitch'
$form.Size          = New-Object System.Drawing.Size(560, 640)
$form.StartPosition = 'CenterScreen'
$form.Icon          = $IconOff

function New-Label($text, $x, $y, $w, $h, $bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Left = $x; $l.Top = $y; $l.Width = $w; $l.Height = $h
    if ($bold) { $l.Font = New-Object System.Drawing.Font('Malgun Gothic', 10, [System.Drawing.FontStyle]::Bold) }
    else       { $l.Font = New-Object System.Drawing.Font('Malgun Gothic', 9) }
    $form.Controls.Add($l)
    return $l
}
function New-Btn($text, $x, $y, $w, $h) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Left = $x; $b.Top = $y; $b.Width = $w; $b.Height = $h
    $b.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
    $form.Controls.Add($b)
    return $b
}

New-Label '상태' 16 12 200 20 $true | Out-Null
$lblKb    = New-Label '키보드:  확인 중...'  16 40  500 20 $false
$lblMouse = New-Label '마우스:  확인 중...'  16 64  500 20 $false
$lblWatch = New-Label '감시:    중지됨'      16 88  500 20 $false

$btnWatch  = New-Btn '감시 시작'          16 118 160 34
$btnToPhone= New-Btn '지금 폰으로 보내기' 186 118 160 34
$btnToPc   = New-Btn '현재 호스트 읽기'   356 118 160 34

New-Label '설정' 16 168 200 20 $true | Out-Null

New-Label '키보드' 16 198 60 20 $false | Out-Null
$cboKb = New-Object System.Windows.Forms.ComboBox
$cboKb.Left = 80; $cboKb.Top = 195; $cboKb.Width = 350
$cboKb.DropDownStyle = 'DropDownList'
$cboKb.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
$form.Controls.Add($cboKb)
$btnReload = New-Btn '새로고침' 440 194 76 26

New-Label '폰 채널' 16 232 60 20 $false | Out-Null
$cboHost = New-Object System.Windows.Forms.ComboBox
$cboHost.Left = 80; $cboHost.Top = 229; $cboHost.Width = 120
$cboHost.DropDownStyle = 'DropDownList'
$cboHost.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
[void]$cboHost.Items.AddRange(@('1번', '2번', '3번'))
$form.Controls.Add($cboHost)

$btnFindMouse = New-Btn '마우스 자동 찾기' 210 228 150 26
$lblMouseCfg  = New-Label '' 370 232 180 20 $false

$chkStartup = New-Object System.Windows.Forms.CheckBox
$chkStartup.Text = 'Windows 시작 시 자동 실행'
$chkStartup.Left = 16; $chkStartup.Top = 264; $chkStartup.Width = 300
$chkStartup.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
$form.Controls.Add($chkStartup)

$chkAutoWatch = New-Object System.Windows.Forms.CheckBox
$chkAutoWatch.Text = '앱을 켜면 바로 감시 시작'
$chkAutoWatch.Left = 16; $chkAutoWatch.Top = 290; $chkAutoWatch.Width = 300
$chkAutoWatch.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
$form.Controls.Add($chkAutoWatch)

New-Label '기록' 16 324 200 20 $true | Out-Null
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Left = 16; $txtLog.Top = 350; $txtLog.Width = 500; $txtLog.Height = 230
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $IconOff
$tray.Text = 'LogiSwitch'
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('열기',  $null, { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$menu.Items.Add('끝내기', $null, { $script:Quitting = $true; $form.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

function Write-AppLog([string]$m) {
    $line = "{0}  {1}" -f (Get-Date).ToString('HH:mm:ss'), $m
    if ($txtLog) { $txtLog.AppendText($line + [Environment]::NewLine) }
}

# ------------------------------------------------------------------ 동작

function Get-StartupLinkPath {
    Join-Path ([Environment]::GetFolderPath('Startup')) 'LogiSwitch.lnk'
}

function Set-Startup([bool]$enable) {
    $lnk = Get-StartupLinkPath
    try {
        if ($enable) {
            $ws = New-Object -ComObject WScript.Shell
            $s = $ws.CreateShortcut($lnk)
            $s.TargetPath = (Join-Path $PSHOME 'powershell.exe')
            $s.Arguments  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            $s.WorkingDirectory = $PSScriptRoot
            $s.Save()
            Write-AppLog '시작프로그램에 등록했습니다.'
        } else {
            if (Test-Path $lnk) { Remove-Item $lnk -Force }
            Write-AppLog '시작프로그램에서 제거했습니다.'
        }
    } catch {
        Write-AppLog "시작프로그램 설정 실패: $($_.Exception.Message)"
    }
}

function Update-BtList {
    $cboKb.Items.Clear()
    $script:BtDevices = @(
        Get-PnpDevice -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like 'BTH*' -and $_.FriendlyName } |
            Sort-Object FriendlyName
    )
    foreach ($d in $script:BtDevices) {
        [void]$cboKb.Items.Add("$($d.FriendlyName)")
    }
    $i = 0
    foreach ($d in $script:BtDevices) {
        if ($d.InstanceId -eq $Config.KeyboardInstanceId) { $cboKb.SelectedIndex = $i; break }
        $i++
    }
    Write-AppLog "블루투스 장치 $($script:BtDevices.Count)개를 찾았습니다."
}

function Find-Mouse {
    Write-AppLog '마우스를 찾는 중...'
    $cands = @(Get-HidppCollections)
    if ($cands.Count -eq 0) {
        Write-AppLog '로지텍 HID++ 수신기를 찾지 못했습니다. Unifying/Bolt 동글이 꽂혀 있는지 확인하세요.'
        return $false
    }
    foreach ($c in $cands) {
        foreach ($idx in @(1, 2, 3, 4, 5, 6, 0xFF)) {
            $fi = 0
            try { $fi = Get-FeatureIndex -Path $c.Path -DeviceIndex ([byte]$idx) } catch { $fi = 0 }
            if ($fi -ne 0) {
                $Config.MouseDeviceIndex = $idx
                $Config.FeatureIndex     = $fi
                $Config.ForceHidPath     = $c.Path
                Export-AppConfig
                Write-AppLog ("마우스를 찾았습니다. 슬롯 $idx, feature 0x{0:X2}" -f $fi)
                $lblMouseCfg.Text = ("슬롯 $idx / 0x{0:X2}" -f $fi)
                return $true
            }
        }
    }
    Write-AppLog '마우스가 응답하지 않습니다. 마우스를 PC 채널로 켜고 다시 시도하세요.'
    return $false
}

function Read-MouseHost {
    # 마우스가 PC 쪽에 있어야 응답한다. 무응답이면 폰에 있다는 뜻이다.
    $path = Select-HidppPath
    if (-not $path) { return $null }
    if ($Config.FeatureIndex -eq 0) { return $null }
    try {
        return Get-CurrentHost -Path $path -DeviceIndex ([byte]$Config.MouseDeviceIndex) -FeatureIndex ([byte]$Config.FeatureIndex)
    } catch { return $null }
}

function Send-ToPhone {
    try {
        Send-ChangeHost -HostIndex $Config.TargetHostIndex
        Write-AppLog "마우스를 폰(채널 $($Config.TargetHostIndex + 1))으로 보냈습니다."
        $script:SuppressUntil = (Get-Date).AddMilliseconds($Config.RearmDelayMs)
    } catch {
        Write-AppLog "전송 실패: $($_.Exception.Message)"
    }
}

function Update-Status {
    # 키보드
    $kbOk = $null
    try { $kbOk = Test-KeyboardConnected } catch { }
    if ($null -eq $kbOk) {
        $lblKb.Text = '키보드:  설정되지 않음'
        $lblKb.ForeColor = [System.Drawing.Color]::Gray
    } elseif ($kbOk) {
        $lblKb.Text = '키보드:  ● PC 에 연결됨'
        $lblKb.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 50)
    } else {
        $lblKb.Text = '키보드:  ○ PC 에 없음 (폰 사용 중)'
        $lblKb.ForeColor = [System.Drawing.Color]::FromArgb(170, 90, 0)
    }

    # 마우스
    $info = Read-MouseHost
    if ($null -ne $info) {
        $lblMouse.Text = "마우스:  ● PC 에 연결됨  (현재 채널 $($info.CurrentHost + 1) / 총 $($info.NbHost)개)"
        $lblMouse.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 50)
        $tray.Icon = $IconOn
        $tray.Text = 'LogiSwitch — 마우스 PC'
    } else {
        $lblMouse.Text = '마우스:  ○ PC 에 없음 (폰 사용 중)'
        $lblMouse.ForeColor = [System.Drawing.Color]::FromArgb(170, 90, 0)
        $tray.Icon = $IconOff
        $tray.Text = 'LogiSwitch — 마우스 폰'
    }

    if ($script:Watching) {
        $lblWatch.Text = '감시:    ● 실행 중'
        $lblWatch.ForeColor = [System.Drawing.Color]::FromArgb(30, 120, 50)
    } else {
        $lblWatch.Text = '감시:    ○ 중지됨'
        $lblWatch.ForeColor = [System.Drawing.Color]::Gray
    }
    return $kbOk
}

# 폴링: 키보드가 PC 에서 사라지는 순간 마우스를 폰으로 밀어낸다
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.add_Tick({
    $kbOk = Update-Status
    if (-not $script:Watching) { return }
    if ($null -eq $kbOk) { return }
    if ((Get-Date) -lt $script:SuppressUntil) { $script:PrevConnected = $kbOk; return }

    if ($script:PrevConnected -eq $true -and $kbOk -eq $false) {
        Write-AppLog '키보드가 폰으로 넘어갔습니다. 마우스를 따라 보냅니다.'
        Send-ToPhone
    }
    $script:PrevConnected = $kbOk
})

# ------------------------------------------------------------------ 이벤트

$btnWatch.add_Click({
    $script:Watching = -not $script:Watching
    if ($script:Watching) {
        if (-not $Config.KeyboardInstanceId) {
            Write-AppLog '먼저 키보드를 선택하세요.'
            $script:Watching = $false
            return
        }
        if ($Config.FeatureIndex -eq 0) {
            Write-AppLog '먼저 [마우스 자동 찾기] 를 눌러주세요.'
            $script:Watching = $false
            return
        }
        $script:PrevConnected = $null
        $btnWatch.Text = '감시 중지'
        Write-AppLog '감시를 시작했습니다. Fn+2 로 키보드를 폰에 넘기면 마우스가 따라갑니다.'
    } else {
        $btnWatch.Text = '감시 시작'
        Write-AppLog '감시를 중지했습니다.'
    }
    Update-Status | Out-Null
})

$btnToPhone.add_Click({ Send-ToPhone })

$btnToPc.add_Click({
    $info = Read-MouseHost
    if ($null -eq $info) { Write-AppLog '마우스가 PC 에 없어 읽을 수 없습니다 (폰 사용 중).' }
    else { Write-AppLog "현재 채널 $($info.CurrentHost + 1), 총 $($info.NbHost)개" }
})

$btnReload.add_Click({ Update-BtList })

$cboKb.add_SelectedIndexChanged({
    $i = $cboKb.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:BtDevices.Count) {
        $Config.KeyboardInstanceId = $script:BtDevices[$i].InstanceId
        $script:DetectResolved = $null   # 판별 방식을 다시 고르게 한다
        Export-AppConfig
        Write-AppLog "키보드: $($script:BtDevices[$i].FriendlyName)"
    }
})

$cboHost.add_SelectedIndexChanged({
    if ($cboHost.SelectedIndex -ge 0) {
        $Config.TargetHostIndex = $cboHost.SelectedIndex
        Export-AppConfig
    }
})

$btnFindMouse.add_Click({ [void](Find-Mouse) })

$chkStartup.add_Click({ Set-Startup ($chkStartup.Checked) })

$chkAutoWatch.add_Click({
    $Config['AutoWatch'] = $chkAutoWatch.Checked
    Export-AppConfig
})

# 닫기 = 트레이로 최소화 (끝내기는 트레이 메뉴에서)
$script:Quitting = $false
$form.add_FormClosing({
    param($s, $e)
    if (-not $script:Quitting) {
        $e.Cancel = $true
        $form.Hide()
        $tray.ShowBalloonTip(2000, 'LogiSwitch', '트레이에서 계속 실행 중입니다.', 'Info')
    } else {
        $timer.Stop()
        $tray.Visible = $false
    }
})

# ------------------------------------------------------------------ 시작

$form.add_Shown({
    Write-AppLog 'LogiSwitch 를 시작했습니다.'
    Update-BtList
    if ($Config.TargetHostIndex -ge 0 -and $Config.TargetHostIndex -le 2) {
        $cboHost.SelectedIndex = $Config.TargetHostIndex
    }
    if ($Config.FeatureIndex -ne 0) {
        $lblMouseCfg.Text = ("슬롯 $($Config.MouseDeviceIndex) / 0x{0:X2}" -f $Config.FeatureIndex)
    }
    $chkStartup.Checked   = Test-Path (Get-StartupLinkPath)
    $chkAutoWatch.Checked = [bool]$Config['AutoWatch']

    $timer.Start()

    if ($chkAutoWatch.Checked -and $Config.KeyboardInstanceId -and $Config.FeatureIndex -ne 0) {
        $script:Watching = $true
        $btnWatch.Text = '감시 중지'
        Write-AppLog '설정에 따라 감시를 자동으로 시작했습니다.'
    }
})

[void]$form.ShowDialog()
$tray.Visible = $false
