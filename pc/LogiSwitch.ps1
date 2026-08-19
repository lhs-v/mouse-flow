<#
================================================================================
 LogiSwitch.ps1  -  Logitech HID++ ChangeHost (feature 0x1814) helper
================================================================================
 독거미 키보드가 블루투스에서 끊기면(= Fn+2 로 폰으로 넘어가면)
 MX Vertical 도 자동으로 같은 방향으로 넘겨준다.

 외부 실행파일(hidapitester 등) 불필요. 순수 PowerShell + Win32 HID API.
 관리자 권한 불필요.

 사용법
 ------
   .\LogiSwitch.ps1 -ListBluetooth      블루투스 기기 InstanceId 목록 (키보드 ID 찾기)
   .\LogiSwitch.ps1 -Discover           HID++ 콜렉션 / 기기 인덱스 / FeatureIndex 탐색
   .\LogiSwitch.ps1 -MonitorKeyboard    키보드 연결 상태 실시간 표시 (Fn+1/2 눌러보며 검증)
   .\LogiSwitch.ps1 -SwitchTo 1         마우스를 즉시 채널 2(=인덱스 1)로 전환
   .\LogiSwitch.ps1 -Watch              감시 데몬 (실사용 모드)

 실행 정책에 막히면:
   powershell -ExecutionPolicy Bypass -File .\LogiSwitch.ps1 -Discover
================================================================================
#>

[CmdletBinding(DefaultParameterSetName = 'Watch')]
param(
    [Parameter(ParameterSetName = 'ListBluetooth')][switch] $ListBluetooth,
    [Parameter(ParameterSetName = 'FindSignal')]   [switch] $FindSignal,
    [Parameter(ParameterSetName = 'Discover')]     [switch] $Discover,
    [Parameter(ParameterSetName = 'Monitor')]      [switch] $MonitorKeyboard,
    [Parameter(ParameterSetName = 'SwitchTo')]     [int]    $SwitchTo = -1,
    [Parameter(ParameterSetName = 'Watch')]        [switch] $Watch
)

# ==============================================================================
#  설정  --  회사 PC 에서 이 블록만 채우면 됩니다
# ==============================================================================
$Config = @{

    # [1] 독거미 키보드의 블루투스 InstanceId
    #     .\LogiSwitch.ps1 -ListBluetooth 로 확인해서 통째로 붙여넣기.
    #     예: 'BTHLE\DEV_A1B2C3D4E5F6\7&1A2B3C4D&0&A1B2C3D4E5F6'
    KeyboardInstanceId = ''

    # [1-b] InstanceId 를 못 찾겠으면 이름 일부로 대체 가능 (위를 비워두고 여기에)
    #       예: 'AULA' 또는 'Keyboard K'
    KeyboardNamePattern = ''

    # [1-c] 연결 해제를 무엇으로 판단할지.
    #   'Auto'     : BtConnected -> ChildHid -> Status 순으로 가능한 것을 자동 선택 (권장)
    #   'Status'   : PnP Status 가 OK 인지  ※ BLE 기기는 끊겨도 OK 라 대개 안 먹힌다
    #   'BtConnected' : 블루투스 연결 상태 속성
    #   'ChildHid' : 이 기기의 하위 HID 노드가 존재하는지
    #   'Property' : 아래 두 값으로 직접 지정 (-FindSignal 결과를 넣는다)
    DetectMethod = 'Auto'
    DetectPropertyKey = ''
    DetectPropertyConnectedValue = ''

    # [2] 마우스가 리시버에 물린 슬롯 번호 (1~6). -Discover 가 알려줍니다.
    MouseDeviceIndex = 1

    # [3] 마우스를 보낼 대상 호스트. 0-based!
    #     0 = Easy-Switch 채널 1, 1 = 채널 2, 2 = 채널 3
    #     PC 가 채널1, 폰이 채널2 라면 1 을 넣습니다.
    TargetHostIndex = 1

    # [4] 0x1814 의 feature index. 0 이면 실행 시 자동 조회.
    #     -Discover 가 찾아준 값을 넣어두면 전환이 더 빨라집니다.
    FeatureIndex = 0

    # [5] 특정 HID 콜렉션을 강제하려면 경로를 넣습니다. 비우면 자동 선택.
    ForceHidPath = ''

    # ---- 잘 안 건드려도 되는 값 ----
    VendorId       = 0x046D   # Logitech
    SoftwareId     = 0x0D     # HID++ software id (1~15)
    PollIntervalMs = 500      # 키보드 상태 확인 주기
    RearmDelayMs   = 3000     # 전환 후 재무장까지 대기 (오발 방지)
    IgnoreShorterThanMs = 0   # 이보다 짧은 끊김은 무시 (0 = 비활성)
}
# ==============================================================================


$ErrorActionPreference = 'Stop'
# 공용 엔진 (Add-Type, HID++, 감지 로직)
. "$PSScriptRoot\LogiSwitchCore.ps1"

# --------------------------------------------------------------------- modes

if ($ListBluetooth) {
    Write-Head '블루투스 기기 목록 — 독거미 키보드를 찾아 InstanceId 를 복사하세요'
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'BTH*' } |
        Sort-Object Status, FriendlyName |
        Select-Object Status, Class, FriendlyName, InstanceId |
        Format-List
    Write-Host '  힌트: 키보드를 PC 채널(Fn+1)로 둔 상태에서 Status 가 OK 인 항목이 대상입니다.' -ForegroundColor Yellow
    Write-Host '        BTHLE\ 로 시작하는 항목을 우선 사용하세요.' -ForegroundColor Yellow
    return
}

if ($FindSignal) {
    # 연결 해제를 무엇으로 감지할지 추측하지 않고, 실제로 무엇이 바뀌는지 직접 찾아낸다.
    function Get-PnpSnapshot {
        $h = @{}
        Get-PnpDevice -ErrorAction SilentlyContinue | ForEach-Object {
            $h[$_.InstanceId] = "Status=$($_.Status) Present=$($_.Present)"
        }
        return $h
    }
    function Get-PropSnapshot {
        param([string]$InstanceId)
        $h = @{}
        if (-not $InstanceId) { return $h }
        try {
            Get-PnpDeviceProperty -InstanceId $InstanceId -ErrorAction SilentlyContinue | ForEach-Object {
                $h[$_.KeyName] = ($_.Data -join ',')
            }
        } catch { }
        return $h
    }

    $kb = $null
    try { $kb = Get-KeyboardDevice } catch { }
    $kbId = if ($kb) { $kb.InstanceId } else { '' }

    Write-Head '연결 해제 신호 찾기'
    if ($kbId) {
        Write-Host "  대상 키보드: $($kb.FriendlyName)" -ForegroundColor Cyan
        Write-Host "              $kbId" -ForegroundColor DarkGray
    } else {
        Write-Host '  키보드가 설정되지 않았습니다. 전체 장치 변화만 비교합니다.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '  [1단계] 키보드를 PC 채널(Fn+1)로 두고 연결된 상태로 만드세요.' -ForegroundColor Yellow
    Read-Host  '         준비되면 Enter'
    $snapA = Get-PnpSnapshot
    $propA = Get-PropSnapshot -InstanceId $kbId
    Write-Host "  기준 스냅샷 저장 (장치 $($snapA.Count)개, 속성 $($propA.Count)개)" -ForegroundColor Green

    Write-Host ''
    Write-Host '  [2단계] 이제 Fn+2 로 폰으로 넘기세요. 폰에 연결된 것을 확인하고 오세요.' -ForegroundColor Yellow
    Read-Host  '         넘어갔으면 Enter'
    Start-Sleep -Milliseconds 800
    $snapB = Get-PnpSnapshot
    $propB = Get-PropSnapshot -InstanceId $kbId

    Write-Head '결과: 바뀐 것들'
    $hits = 0

    foreach ($id in $snapA.Keys) {
        if (-not $snapB.ContainsKey($id)) {
            Write-Host "  [장치 사라짐] $id" -ForegroundColor Green
            Write-Host "      연결 시: $($snapA[$id])" -ForegroundColor DarkGray
            $hits++
        } elseif ($snapA[$id] -ne $snapB[$id]) {
            Write-Host "  [상태 변화] $id" -ForegroundColor Green
            Write-Host "      연결: $($snapA[$id])   ->   해제: $($snapB[$id])" -ForegroundColor DarkGray
            $hits++
        }
    }
    foreach ($id in $snapB.Keys) {
        if (-not $snapA.ContainsKey($id)) {
            Write-Host "  [장치 생김] $id" -ForegroundColor DarkYellow
            $hits++
        }
    }

    foreach ($k in $propA.Keys) {
        $a = $propA[$k]
        $b = if ($propB.ContainsKey($k)) { $propB[$k] } else { '(없음)' }
        if ($a -ne $b) {
            Write-Host "  [속성 변화] $k" -ForegroundColor Green
            Write-Host "      연결: '$a'   ->   해제: '$b'" -ForegroundColor DarkGray
            Write-Host "      => DetectMethod='Property'; DetectPropertyKey='$k'; DetectPropertyConnectedValue='$a'" -ForegroundColor Yellow
            $hits++
        }
    }

    Write-Host ''
    if ($hits -eq 0) {
        Write-Host '  아무 변화도 감지되지 않았습니다.' -ForegroundColor Red
        Write-Host '  키보드가 실제로 폰으로 넘어간 게 맞는지, 2단계에서 충분히 기다렸는지 확인하세요.' -ForegroundColor Yellow
        Write-Host '  그래도 변화가 없다면 Windows 가 이 키보드의 링크 해제를 노출하지 않는 것입니다.' -ForegroundColor Yellow
    } else {
        Write-Host "  변화 $hits 건 발견. 위 [속성 변화] 줄의 설정을 \$Config 에 넣으면 됩니다." -ForegroundColor Cyan
        Write-Host '  [장치 사라짐] 만 있고 속성 변화가 없다면 DetectMethod = ''ChildHid'' 를 쓰세요.' -ForegroundColor Cyan
    }
    return
}

if ($Discover) {
    Write-Head '1) 로지텍 벤더 HID 콜렉션'
    $all = Get-LogitechVendorCollections
    if (-not $all) {
        Write-Host '  로지텍 벤더 HID 콜렉션이 하나도 없습니다.' -ForegroundColor Red
        Write-Host '  -> Unifying/Bolt 리시버가 꽂혀 있지 않거나, 마우스가 블루투스로 연결되어 있습니다.' -ForegroundColor Red
        Write-Host '     이 경우 PC 쪽 자동 전환은 불가능합니다 (폰 앱 경로만 가능).' -ForegroundColor Red
        return
    }

    $cands = @(Get-HidppCollections)
    $candPaths = @($cands | ForEach-Object { $_.Path })

    $all | ForEach-Object {
        $isCand = $candPaths -contains $_.Path
        $mark  = if ($isCand) { 'HID++ 후보' } else { '제외 (HID++ 리포트 크기 아님)' }
        $color = if ($isCand) { 'Green' } else { 'DarkGray' }
        Write-Host ("  PID=0x{0:X4}  UsagePage=0x{1:X4} Usage=0x{2:X4}  in={3} out={4}   {5}" -f `
                    $_.Pid, $_.UsagePage, $_.Usage, $_.InLen, $_.OutLen, $mark) -ForegroundColor $color
        Write-Host ("      $($_.Path)") -ForegroundColor DarkGray
    }

    if ($cands.Count -eq 0) {
        Write-Host ''
        Write-Host '  HID++ 콜렉션이 없습니다. 위 기기들은 전부 다른 벤더 프로토콜입니다.' -ForegroundColor Red
        Write-Host '  (HID++ 는 출력 리포트가 정확히 20바이트 또는 7바이트입니다.)' -ForegroundColor Yellow
        Write-Host '  -> MX Vertical 의 Unifying/Bolt 리시버를 꽂고 다시 실행하세요.' -ForegroundColor Yellow
        return
    }

    Write-Head '2) 장치 슬롯 탐색 (콜렉션 x 슬롯 1~6, 0xFF)'
    $found = @()
    $usedPath = $null

    foreach ($c in $cands) {
        Write-Host ("  콜렉션 UsagePage=0x{0:X4} out={1}" -f $c.UsagePage, $c.OutLen) -ForegroundColor Cyan
        foreach ($idx in @(1, 2, 3, 4, 5, 6, 0xFF)) {
            try { $fi = Get-FeatureIndex -Path $c.Path -DeviceIndex ([byte]$idx) } catch { $fi = 0 }
            $label = if ($idx -eq 0xFF) { '0xFF(직결)' } else { "슬롯 $idx" }
            if ($fi -ne 0) {
                $info = $null
                try { $info = Get-CurrentHost -Path $c.Path -DeviceIndex ([byte]$idx) -FeatureIndex ([byte]$fi) } catch { }
                $cur = if ($info) { "현재 호스트 $($info.CurrentHost) / 총 $($info.NbHost)개" } else { '호스트 조회 실패' }
                Write-Host ("    [$label]  ChangeHost 지원  featureIndex=0x{0:X2}   $cur" -f $fi) -ForegroundColor Green
                $found += [pscustomobject]@{ Index = $idx; Feature = $fi; Path = $c.Path }
                if (-not $usedPath) { $usedPath = $c.Path }
            } else {
                Write-Host "    [$label]  응답 없음" -ForegroundColor DarkGray
            }
        }
        if ($found.Count -gt 0) { break }
    }

    Write-Head '3) 설정에 넣을 값'
    if ($found.Count -eq 0) {
        Write-Host '  ChangeHost 를 지원하는 장치를 찾지 못했습니다.' -ForegroundColor Red
        Write-Host '  마우스가 리시버 채널로 켜져 있는지 확인하고 다시 실행하세요.' -ForegroundColor Yellow
    } else {
        $f = $found[0]
        Write-Host ("    MouseDeviceIndex = {0}" -f $f.Index) -ForegroundColor Yellow
        Write-Host ("    FeatureIndex     = 0x{0:X2}" -f $f.Feature) -ForegroundColor Yellow
        if ($found.Count -gt 1) {
            Write-Host ''
            Write-Host '  여러 개 발견 — 키보드도 리시버에 물려 있을 수 있습니다.' -ForegroundColor DarkYellow
            Write-Host '  각 슬롯으로 -SwitchTo 를 시험해서 마우스가 반응하는 쪽을 고르세요.' -ForegroundColor DarkYellow
        }
    }
    return
}

if ($MonitorKeyboard) {
    Write-Head '키보드 연결 상태 모니터 — Fn+1 / Fn+2 를 눌러보세요 (Ctrl+C 종료)'

    $kb = $null
    try { $kb = Get-KeyboardDevice } catch { Write-Host $_.Exception.Message -ForegroundColor Red; return }
    if ($null -eq $kb) { Write-Host '  키보드 장치를 찾지 못했습니다. InstanceId 를 확인하세요.' -ForegroundColor Red; return }

    $method = Resolve-DetectMethod
    Write-Host "  대상: $($kb.FriendlyName)" -ForegroundColor Cyan
    Write-Host "  판별 방식: $method" -ForegroundColor Cyan
    if ($method -eq 'Status') {
        Write-Host '  주의: Status 방식은 BLE 기기에서 대개 변하지 않습니다.' -ForegroundColor Yellow
        Write-Host '        상태가 안 바뀌면 -FindSignal 로 실제 신호를 찾으세요.' -ForegroundColor Yellow
    }
    Write-Host ''

    # 원시값을 같이 보여줘야 "왜 안 바뀌는지" 를 눈으로 확인할 수 있다.
    $last = $null
    while ($true) {
        try { $now = Test-KeyboardConnected } catch { Write-Host $_.Exception.Message -ForegroundColor Red; return }

        $raw = switch ($method) {
            'BtConnected' { "btConnected=$(Get-DeviceProp -InstanceId $kb.InstanceId -KeyName $script:PK_BT_CONNECTED)" }
            'ChildHid'    { "childHid=$(Get-ChildHidCount -InstanceId $kb.InstanceId)" }
            'Property'    { "prop=$((Get-DeviceProp -InstanceId $kb.InstanceId -KeyName $Config.DetectPropertyKey) -join ',')" }
            default       { "status=$((Get-KeyboardDevice).Status)" }
        }

        if ($now -ne $last) {
            $stamp = (Get-Date).ToString('HH:mm:ss.fff')
            if ($now) { Write-Host "  [$stamp]  연결됨   (PC 채널)        $raw"   -ForegroundColor Green }
            else      { Write-Host "  [$stamp]  끊김     (폰으로 넘어감)  $raw" -ForegroundColor Magenta }
            $last = $now
        }
        Start-Sleep -Milliseconds $Config.PollIntervalMs
    }
}

if ($PSCmdlet.ParameterSetName -eq 'SwitchTo') {
    if ($SwitchTo -lt 0 -or $SwitchTo -gt 2) { throw '-SwitchTo 는 0, 1, 2 중 하나여야 합니다 (0-based 호스트 인덱스).' }
    Write-Head "즉시 전환 -> 호스트 $SwitchTo (Easy-Switch 채널 $($SwitchTo + 1))"
    try {
        Send-ChangeHost -HostIndex $SwitchTo
    } catch {
        Write-Host ("  실패: " + $_.Exception.Message) -ForegroundColor Red
        Write-Host '  -> .\LogiSwitch.ps1 -Discover 로 상태를 먼저 확인하세요.' -ForegroundColor Yellow
    }
    return
}

# ---------------------------------------------------------------- Watch mode
Write-Head '감시 시작 — 키보드가 끊기면 마우스를 따라 보냅니다 (Ctrl+C 종료)'
Write-Host ("  대상 호스트: {0} (채널 {1})   폴링: {2}ms" -f $Config.TargetHostIndex, ($Config.TargetHostIndex + 1), $Config.PollIntervalMs)

try { $prev = Test-KeyboardConnected } catch { Write-Host $_.Exception.Message -ForegroundColor Red; return }
Write-Host ("  초기 상태: " + $(if ($prev) { '연결됨' } else { '끊김' }))
$lastDisconnectTick = 0

while ($true) {
    Start-Sleep -Milliseconds $Config.PollIntervalMs

    try { $now = Test-KeyboardConnected } catch { continue }

    if ($prev -and -not $now) {
        # 끊김 엣지 감지
        $lastDisconnectTick = [Environment]::TickCount
        $stamp = (Get-Date).ToString('HH:mm:ss')
        Write-Host "  [$stamp] 키보드 끊김 감지" -ForegroundColor Magenta

        if ($Config.IgnoreShorterThanMs -gt 0) {
            Start-Sleep -Milliseconds $Config.IgnoreShorterThanMs
            try { $still = Test-KeyboardConnected } catch { $still = $false }
            if ($still) {
                Write-Host '        (짧은 끊김이라 무시)' -ForegroundColor DarkGray
                $prev = $true
                continue
            }
        }

        try {
            Send-ChangeHost -HostIndex $Config.TargetHostIndex
        } catch {
            Write-Host ("        전송 실패: " + $_.Exception.Message) -ForegroundColor Red
        }

        Start-Sleep -Milliseconds $Config.RearmDelayMs
        try { $now = Test-KeyboardConnected } catch { $now = $false }
    }

    $prev = $now
}
