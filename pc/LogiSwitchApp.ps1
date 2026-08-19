<#
================================================================================
 LogiSwitchApp.ps1  -  LogiSwitch 데스크톱 앱
================================================================================
 스크립트를 편집하지 않고 클릭만으로 설정하고 실행한다.
 설정은 %APPDATA%\LogiSwitch\config.json 에 저장된다.

 구조
 ----
 HID++ 통신과 PnP 조회는 전부 백그라운드 러너스페이스에서 돈다.
 UI 스레드는 공유 해시테이블을 읽어 화면만 갱신한다.
 마우스가 폰에 있을 때 HID 응답 대기가 700ms 걸리는데, 이걸 UI 스레드에서
 하면 창이 통째로 멈춘다.

 실행:  LogiSwitch 시작.cmd 더블클릭
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
        AutoWatch                    = $false
        ShowAllBtDevices             = $false
    }
}

function Import-AppConfig {
    $cfg = New-DefaultConfig
    if (Test-Path $ConfigPath) {
        try {
            $j = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($cfg.Keys)) { if ($null -ne $j.$k) { $cfg[$k] = $j.$k } }
        } catch { }
    }
    return $cfg
}

$Config = Import-AppConfig

function Export-AppConfig {
    try {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        ($Config | ConvertTo-Json) | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch { Add-UiLog "설정 저장 실패: $($_.Exception.Message)" }
}

# --------------------------------------------------------------- 공유 상태

$sync = [hashtable]::Synchronized(@{
    Config       = $Config          # 같은 객체를 공유하므로 UI 수정이 즉시 반영된다
    ScriptRoot   = $PSScriptRoot
    Stop         = $false
    Watching     = $false
    KbConnected  = $null            # $true / $false / $null(설정 안 됨)
    MouseHost    = $null            # 현재 호스트 인덱스, 없으면 $null (= 폰에 있음)
    MouseHostCnt = 0
    Log          = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    Requests     = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
    BtList       = $null            # 워커가 채워 넣는 장치 목록
    NeedSave     = $false           # 워커가 설정을 바꿨으니 UI 가 저장하라는 신호
    Busy         = ''
})

# --------------------------------------------------------------- 백그라운드

$worker = {
    $Config = $sync.Config
    . (Join-Path $sync.ScriptRoot 'LogiSwitchCore.ps1')
    $ErrorActionPreference = 'Continue'

    function W([string]$m) { $sync.Log.Enqueue(((Get-Date).ToString('HH:mm:ss') + '  ' + $m)) }

    function Read-MouseHostSafe {
        if ($Config.FeatureIndex -eq 0) { return $null }
        try {
            $path = Select-HidppPath
            if (-not $path) { return $null }
            return Get-CurrentHost -Path $path -DeviceIndex ([byte]$Config.MouseDeviceIndex) -FeatureIndex ([byte]$Config.FeatureIndex)
        } catch { return $null }
    }

    function Get-BtDeviceList {
        $all = @(Get-PnpDevice -ErrorAction SilentlyContinue |
                 Where-Object { $_.InstanceId -like 'BTH*' -and $_.FriendlyName })
        if (-not $Config.ShowAllBtDevices) {
            # 실제 페어링된 주변기기만. 라디오/열거자/서비스 노드를 걸러낸다.
            $real = @($all | Where-Object { $_.InstanceId -match '\\DEV_[0-9A-Fa-f]{12}' })
            if ($real.Count -gt 0) { $all = $real }
        }
        # 같은 이름이 여러 노드로 잡히면 BTHLE 를 우선한다
        $all | Sort-Object @{ Expression = { if ($_.InstanceId -like 'BTHLE*') { 0 } else { 1 } } }, FriendlyName |
            Group-Object FriendlyName | ForEach-Object { $_.Group[0] }
    }

    function Find-MouseWorker {
        W '마우스를 찾는 중...'
        $cands = @(Get-HidppCollections)
        if ($cands.Count -eq 0) {
            W '로지텍 HID++ 수신기를 찾지 못했습니다. Unifying/Bolt 동글을 꽂고 다시 시도하세요.'
            return
        }
        foreach ($c in $cands) {
            foreach ($idx in @(1, 2, 3, 4, 5, 6, 0xFF)) {
                $fi = 0
                try { $fi = Get-FeatureIndex -Path $c.Path -DeviceIndex ([byte]$idx) } catch { $fi = 0 }
                if ($fi -ne 0) {
                    $Config.MouseDeviceIndex = $idx
                    $Config.FeatureIndex     = $fi
                    $Config.ForceHidPath     = $c.Path
                    W ("마우스를 찾았습니다. 슬롯 $idx, feature 0x{0:X2}" -f $fi)
                    $sync.NeedSave = $true
                    return
                }
            }
        }
        W '마우스가 응답하지 않습니다. 마우스를 PC 채널로 켜고 다시 시도하세요.'
    }

    $prev  = $null
    $tick  = 0
    $mute  = [DateTime]::MinValue

    W '엔진을 시작했습니다.'
    $sync.BtList = @(Get-BtDeviceList)

    while (-not $sync.Stop) {
        try {
            # ---- UI 요청 처리 ----
            while ($sync.Requests.Count -gt 0) {
                $r = [string]$sync.Requests.Dequeue()
                switch ($r) {
                    'find'     { $sync.Busy = '마우스 찾는 중'; Find-MouseWorker; $sync.Busy = '' }
                    'reload'   { $sync.Busy = '장치 목록'; $sync.BtList = @(Get-BtDeviceList); W "블루투스 기기 $($sync.BtList.Count)개"; $sync.Busy = '' }
                    'redetect' { $script:DetectResolved = $null; $prev = $null }
                    'tophone'  {
                        try {
                            Send-ChangeHost -HostIndex $Config.TargetHostIndex
                            W "마우스를 폰(채널 $($Config.TargetHostIndex + 1))으로 보냈습니다."
                            $mute = (Get-Date).AddMilliseconds($Config.RearmDelayMs)
                        } catch { W "전송 실패: $($_.Exception.Message)" }
                    }
                    'readhost' {
                        $i = Read-MouseHostSafe
                        if ($null -eq $i) { W '마우스가 PC 에 없습니다 (폰에서 사용 중).' }
                        else { W "현재 채널 $($i.CurrentHost + 1) / 총 $($i.NbHost)개" }
                    }
                }
            }

            # ---- 키보드 상태 (매번) ----
            $kb = $null
            try { $kb = Test-KeyboardConnected } catch { $kb = $null }
            $sync.KbConnected = $kb

            # ---- 마우스 위치 (4번에 1번) ----
            if (($tick % 4) -eq 0) {
                $i = Read-MouseHostSafe
                if ($null -eq $i) { $sync.MouseHost = $null; $sync.MouseHostCnt = 0 }
                else { $sync.MouseHost = $i.CurrentHost; $sync.MouseHostCnt = $i.NbHost }
            }
            $tick++

            # ---- 감시: 키보드가 PC 에서 사라지면 마우스도 보낸다 ----
            if ($sync.Watching -and $null -ne $kb -and (Get-Date) -ge $mute) {
                if ($prev -eq $true -and $kb -eq $false) {
                    W '키보드가 폰으로 넘어갔습니다. 마우스를 따라 보냅니다.'
                    try {
                        Send-ChangeHost -HostIndex $Config.TargetHostIndex
                        W '전송 완료.'
                    } catch { W "전송 실패: $($_.Exception.Message)" }
                    $mute = (Get-Date).AddMilliseconds($Config.RearmDelayMs)
                }
                $prev = $kb
            } elseif ($null -ne $kb) {
                $prev = $kb
            }
        } catch {
            W "엔진 오류: $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 700
    }
    W '엔진을 종료했습니다.'
}

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'MTA'
$rs.ThreadOptions  = 'ReuseThread'
$rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $sync)
$psw = [powershell]::Create()
$psw.Runspace = $rs
[void]$psw.AddScript($worker)
$wHandle = $psw.BeginInvoke()

# ------------------------------------------------------------------------ UI

function New-Dot([System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $br = New-Object System.Drawing.SolidBrush $c
    $g.FillEllipse($br, 2, 2, 12, 12)
    $br.Dispose(); $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$IconOn  = New-Dot ([System.Drawing.Color]::FromArgb(46, 160, 67))
$IconOff = New-Dot ([System.Drawing.Color]::FromArgb(150, 150, 150))

$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'LogiSwitch'
$form.Size          = New-Object System.Drawing.Size(560, 660)
$form.StartPosition = 'CenterScreen'
$form.Icon          = $IconOff

function New-Label($text, $x, $y, $w, $h, $bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Left = $x; $l.Top = $y; $l.Width = $w; $l.Height = $h
    $l.Font = if ($bold) { New-Object System.Drawing.Font('Malgun Gothic', 10, [System.Drawing.FontStyle]::Bold) }
              else       { New-Object System.Drawing.Font('Malgun Gothic', 9) }
    $form.Controls.Add($l); $l
}
function New-Btn($text, $x, $y, $w, $h) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Left = $x; $b.Top = $y; $b.Width = $w; $b.Height = $h
    $b.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
    $form.Controls.Add($b); $b
}

New-Label '상태' 16 12 200 20 $true | Out-Null
$lblKb    = New-Label '키보드:  ...' 16 40  500 20 $false
$lblMouse = New-Label '마우스:  ...' 16 64  500 20 $false
$lblWatch = New-Label '감시:    중지됨' 16 88 500 20 $false

$btnWatch   = New-Btn '감시 시작'          16 118 160 34
$btnToPhone = New-Btn '지금 폰으로 보내기' 186 118 160 34
$btnReadHost= New-Btn '현재 채널 읽기'     356 118 160 34

New-Label '설정' 16 168 200 20 $true | Out-Null

New-Label '키보드' 16 198 60 20 $false | Out-Null
$cboKb = New-Object System.Windows.Forms.ComboBox
$cboKb.Left = 80; $cboKb.Top = 195; $cboKb.Width = 350
$cboKb.DropDownStyle = 'DropDownList'
$cboKb.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
$form.Controls.Add($cboKb)
$btnReload = New-Btn '새로고침' 440 194 76 26

$chkAllBt = New-Object System.Windows.Forms.CheckBox
$chkAllBt.Text = '블루투스 장치 전부 보기 (키보드가 목록에 없을 때)'
$chkAllBt.Left = 80; $chkAllBt.Top = 224; $chkAllBt.Width = 430
$chkAllBt.Font = New-Object System.Drawing.Font('Malgun Gothic', 8.5)
$form.Controls.Add($chkAllBt)

New-Label '폰 채널' 16 254 60 20 $false | Out-Null
$cboHost = New-Object System.Windows.Forms.ComboBox
$cboHost.Left = 80; $cboHost.Top = 251; $cboHost.Width = 120
$cboHost.DropDownStyle = 'DropDownList'
$cboHost.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
[void]$cboHost.Items.AddRange(@('1번', '2번', '3번'))
$form.Controls.Add($cboHost)

$btnFindMouse = New-Btn '마우스 자동 찾기' 210 250 150 26
$lblMouseCfg  = New-Label '' 370 254 180 20 $false

$chkStartup = New-Object System.Windows.Forms.CheckBox
$chkStartup.Text = 'Windows 시작 시 자동 실행'
$chkStartup.Left = 16; $chkStartup.Top = 286; $chkStartup.Width = 250
$chkStartup.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
$form.Controls.Add($chkStartup)

$chkAutoWatch = New-Object System.Windows.Forms.CheckBox
$chkAutoWatch.Text = '앱을 켜면 바로 감시 시작'
$chkAutoWatch.Left = 280; $chkAutoWatch.Top = 286; $chkAutoWatch.Width = 240
$chkAutoWatch.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
$form.Controls.Add($chkAutoWatch)

$btnTray = New-Btn '트레이로 숨기기' 16 314 160 28

New-Label '기록' 16 352 200 20 $true | Out-Null
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Left = 16; $txtLog.Top = 378; $txtLog.Width = 500; $txtLog.Height = 210
$txtLog.Multiline = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $IconOff
$tray.Text = 'LogiSwitch'
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('열기',   $null, { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$menu.Items.Add('끝내기', $null, { $form.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })

function Add-UiLog([string]$m) {
    if ($txtLog) { $txtLog.AppendText(((Get-Date).ToString('HH:mm:ss') + '  ' + $m + [Environment]::NewLine)) }
}

# ------------------------------------------------------------------ 동작

function Get-StartupLinkPath { Join-Path ([Environment]::GetFolderPath('Startup')) 'LogiSwitch.lnk' }

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
            Add-UiLog '시작프로그램에 등록했습니다.'
        } else {
            if (Test-Path $lnk) { Remove-Item $lnk -Force }
            Add-UiLog '시작프로그램에서 제거했습니다.'
        }
    } catch { Add-UiLog "시작프로그램 설정 실패: $($_.Exception.Message)" }
}

$script:BtDevices = @()
$script:ListStamp = -1

function Sync-BtCombo {
    if ($null -eq $sync.BtList) { return }
    if ($sync.BtList.Count -eq $script:ListStamp) { return }
    $script:ListStamp = $sync.BtList.Count
    $script:BtDevices = @($sync.BtList)
    $cboKb.Items.Clear()
    foreach ($d in $script:BtDevices) { [void]$cboKb.Items.Add([string]$d.FriendlyName) }
    for ($i = 0; $i -lt $script:BtDevices.Count; $i++) {
        if ($script:BtDevices[$i].InstanceId -eq $Config.KeyboardInstanceId) { $cboKb.SelectedIndex = $i; break }
    }
}

# UI 타이머는 공유 상태를 읽기만 한다. 절대 블로킹 작업을 하지 않는다.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.add_Tick({
    while ($sync.Log.Count -gt 0) {
        $line = [string]$sync.Log.Dequeue()
        $txtLog.AppendText($line + [Environment]::NewLine)
    }
    Sync-BtCombo

    # 워커가 자동 탐색으로 설정을 바꿨으면 여기서 파일에 쓴다.
    if ($sync.NeedSave) { $sync.NeedSave = $false; Export-AppConfig; Add-UiLog '설정을 저장했습니다.' }

    switch ($sync.KbConnected) {
        $true  { $lblKb.Text = '키보드:  ● PC 에 연결됨';            $lblKb.ForeColor = [System.Drawing.Color]::FromArgb(30,120,50) }
        $false { $lblKb.Text = '키보드:  ○ PC 에 없음 (폰 사용 중)'; $lblKb.ForeColor = [System.Drawing.Color]::FromArgb(170,90,0) }
        default{ $lblKb.Text = '키보드:  설정되지 않음';             $lblKb.ForeColor = [System.Drawing.Color]::Gray }
    }

    if ($null -ne $sync.MouseHost) {
        $lblMouse.Text = "마우스:  ● PC 에 연결됨  (채널 $([int]$sync.MouseHost + 1) / 총 $($sync.MouseHostCnt)개)"
        $lblMouse.ForeColor = [System.Drawing.Color]::FromArgb(30,120,50)
        if ($tray.Icon -ne $IconOn) { $tray.Icon = $IconOn; $tray.Text = 'LogiSwitch — 마우스 PC' }
    } else {
        $lblMouse.Text = '마우스:  ○ PC 에 없음 (폰 사용 중)'
        $lblMouse.ForeColor = [System.Drawing.Color]::FromArgb(170,90,0)
        if ($tray.Icon -ne $IconOff) { $tray.Icon = $IconOff; $tray.Text = 'LogiSwitch — 마우스 폰' }
    }

    if ($Config.FeatureIndex -ne 0 -and -not $lblMouseCfg.Text) {
        $lblMouseCfg.Text = ("슬롯 $($Config.MouseDeviceIndex) / 0x{0:X2}" -f $Config.FeatureIndex)
    }

    if ($sync.Watching) {
        $lblWatch.Text = '감시:    ● 실행 중' + $(if ($sync.Busy) { "   ($($sync.Busy))" } else { '' })
        $lblWatch.ForeColor = [System.Drawing.Color]::FromArgb(30,120,50)
    } else {
        $lblWatch.Text = '감시:    ○ 중지됨' + $(if ($sync.Busy) { "   ($($sync.Busy))" } else { '' })
        $lblWatch.ForeColor = [System.Drawing.Color]::Gray
    }
})

# ------------------------------------------------------------------ 이벤트

$btnWatch.add_Click({
    if (-not $sync.Watching) {
        if (-not $Config.KeyboardInstanceId) { Add-UiLog '먼저 키보드를 선택하세요.'; return }
        if ($Config.FeatureIndex -eq 0)      { Add-UiLog '먼저 [마우스 자동 찾기] 를 누르세요.'; return }
        $sync.Watching = $true
        $btnWatch.Text = '감시 중지'
        Add-UiLog '감시를 시작했습니다. Fn+2 로 키보드를 폰에 넘기면 마우스가 따라갑니다.'
    } else {
        $sync.Watching = $false
        $btnWatch.Text = '감시 시작'
        Add-UiLog '감시를 중지했습니다.'
    }
})

$btnToPhone.add_Click({ $sync.Requests.Enqueue('tophone') })
$btnReadHost.add_Click({ $sync.Requests.Enqueue('readhost') })
$btnReload.add_Click({ $script:ListStamp = -1; $sync.Requests.Enqueue('reload') })
$btnFindMouse.add_Click({ $sync.Requests.Enqueue('find') })

$cboKb.add_SelectedIndexChanged({
    $i = $cboKb.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:BtDevices.Count) {
        $Config.KeyboardInstanceId = [string]$script:BtDevices[$i].InstanceId
        $sync.Requests.Enqueue('redetect')
        Export-AppConfig
        Add-UiLog "키보드: $($script:BtDevices[$i].FriendlyName)"
    }
})

$cboHost.add_SelectedIndexChanged({
    if ($cboHost.SelectedIndex -ge 0) { $Config.TargetHostIndex = $cboHost.SelectedIndex; Export-AppConfig }
})

$chkAllBt.add_Click({
    $Config.ShowAllBtDevices = $chkAllBt.Checked
    Export-AppConfig
    $script:ListStamp = -1
    $sync.Requests.Enqueue('reload')
})

$chkStartup.add_Click({ Set-Startup ($chkStartup.Checked) })
$chkAutoWatch.add_Click({ $Config.AutoWatch = $chkAutoWatch.Checked; Export-AppConfig })

$btnTray.add_Click({
    $form.Hide()
    $tray.ShowBalloonTip(3000, 'LogiSwitch', '트레이에서 계속 실행 중입니다. 아이콘이 안 보이면 시계 옆 ^ 를 눌러보세요.', 'Info')
})

# 닫기는 진짜 종료. 숨기려면 [트레이로 숨기기] 를 쓴다.
$form.add_FormClosing({
    $timer.Stop()
    $sync.Stop = $true
    $tray.Visible = $false
})

# ------------------------------------------------------------------ 시작

$form.add_Shown({
    Add-UiLog 'LogiSwitch 를 시작했습니다.'
    if ($Config.TargetHostIndex -ge 0 -and $Config.TargetHostIndex -le 2) { $cboHost.SelectedIndex = $Config.TargetHostIndex }
    if ($Config.FeatureIndex -ne 0) { $lblMouseCfg.Text = ("슬롯 $($Config.MouseDeviceIndex) / 0x{0:X2}" -f $Config.FeatureIndex) }
    $chkStartup.Checked   = Test-Path (Get-StartupLinkPath)
    $chkAutoWatch.Checked = [bool]$Config.AutoWatch
    $chkAllBt.Checked     = [bool]$Config.ShowAllBtDevices
    $timer.Start()

    if ($chkAutoWatch.Checked -and $Config.KeyboardInstanceId -and $Config.FeatureIndex -ne 0) {
        $sync.Watching = $true
        $btnWatch.Text = '감시 중지'
        Add-UiLog '설정에 따라 감시를 자동으로 시작했습니다.'
    }
})

# ShowDialog 는 폼을 Hide() 하면 루프가 끝나 앱이 통째로 종료된다.
# Application.Run 은 폼이 '닫힐' 때만 끝나므로 트레이 숨김이 가능하다.
[System.Windows.Forms.Application]::Run($form)

# 정리
$sync.Stop = $true
$tray.Visible = $false
try { $psw.Stop() } catch { }
try { $rs.Close() }  catch { }
