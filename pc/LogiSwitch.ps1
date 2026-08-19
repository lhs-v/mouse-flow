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

# ------------------------------------------------------------------ Win32 HID
if (-not ('LogiHid' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public class LogiHidDev {
    public string Path;
    public ushort Vid;
    public ushort Pid;
    public ushort UsagePage;
    public ushort Usage;
    public int InLen;
    public int OutLen;
}

public static class LogiHid {

    const uint DIGCF_PRESENT = 0x02;
    const uint DIGCF_DEVICEINTERFACE = 0x10;
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 0x01;
    const uint FILE_SHARE_WRITE = 0x02;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_OVERLAPPED = 0x40000000;
    const int HIDP_STATUS_SUCCESS = 0x00110000;

    [StructLayout(LayoutKind.Sequential)]
    struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS {
        public ushort Usage;
        public ushort UsagePage;
        public ushort InputReportByteLength;
        public ushort OutputReportByteLength;
        public ushort FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps;
        public ushort NumberInputValueCaps;
        public ushort NumberInputDataIndices;
        public ushort NumberOutputButtonCaps;
        public ushort NumberOutputValueCaps;
        public ushort NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps;
        public ushort NumberFeatureValueCaps;
        public ushort NumberFeatureDataIndices;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid g);
    [DllImport("hid.dll")] static extern bool HidD_GetAttributes(SafeFileHandle h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(SafeFileHandle h, out IntPtr p);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr p);
    [DllImport("hid.dll")] static extern int  HidP_GetCaps(IntPtr p, ref HIDP_CAPS c);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr enumerator, IntPtr hwnd, uint flags);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid g, uint index, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, uint size, out uint required, IntPtr devInfo);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr templ);

    // 모든 HID 콜렉션 열거. vid 가 0 이 아니면 해당 제조사만.
    public static List<LogiHidDev> Enumerate(ushort vid) {
        List<LogiHidDev> list = new List<LogiHidDev>();
        Guid g;
        HidD_GetHidGuid(out g);
        IntPtr set = SetupDiGetClassDevs(ref g, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == new IntPtr(-1)) return list;
        try {
            SP_DEVICE_INTERFACE_DATA ifd = new SP_DEVICE_INTERFACE_DATA();
            ifd.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
            uint i = 0;
            while (SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref g, i, ref ifd)) {
                i++;
                uint need = 0;
                SetupDiGetDeviceInterfaceDetail(set, ref ifd, IntPtr.Zero, 0, out need, IntPtr.Zero);
                if (need == 0) continue;
                IntPtr buf = Marshal.AllocHGlobal((int)need);
                try {
                    Marshal.WriteInt32(buf, (IntPtr.Size == 8) ? 8 : 6);
                    uint dummy = 0;
                    if (!SetupDiGetDeviceInterfaceDetail(set, ref ifd, buf, need, out dummy, IntPtr.Zero)) continue;
                    string path = Marshal.PtrToStringUni(new IntPtr(buf.ToInt64() + 4));
                    if (string.IsNullOrEmpty(path)) continue;

                    SafeFileHandle h = CreateFile(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (h.IsInvalid) { h.Dispose(); continue; }
                    try {
                        HIDD_ATTRIBUTES a = new HIDD_ATTRIBUTES();
                        a.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
                        if (!HidD_GetAttributes(h, ref a)) continue;
                        if (vid != 0 && a.VendorID != vid) continue;

                        IntPtr pp;
                        if (!HidD_GetPreparsedData(h, out pp)) continue;
                        try {
                            HIDP_CAPS c = new HIDP_CAPS();
                            if (HidP_GetCaps(pp, ref c) != HIDP_STATUS_SUCCESS) continue;
                            LogiHidDev d = new LogiHidDev();
                            d.Path = path; d.Vid = a.VendorID; d.Pid = a.ProductID;
                            d.UsagePage = c.UsagePage; d.Usage = c.Usage;
                            d.InLen = c.InputReportByteLength; d.OutLen = c.OutputReportByteLength;
                            list.Add(d);
                        } finally { HidD_FreePreparsedData(pp); }
                    } finally { h.Dispose(); }
                } finally { Marshal.FreeHGlobal(buf); }
            }
        } finally { SetupDiDestroyDeviceInfoList(set); }
        return list;
    }

    // HID++ 요청 전송. inLen 이 0 이면 응답을 기다리지 않는다.
    // 응답은 deviceIndex 와 softwareId 가 맞는 것만 골라서 돌려준다.
    public static byte[] Request(string path, byte[] report, int inLen, int timeoutMs, byte devIdx, byte swId) {
        SafeFileHandle h = CreateFile(path, GENERIC_READ | GENERIC_WRITE,
                                      FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
                                      OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        if (h.IsInvalid) {
            int err = Marshal.GetLastWin32Error();
            h.Dispose();
            throw new IOException("HID 열기 실패 (Win32 " + err + "): " + path);
        }
        FileStream fs = new FileStream(h, FileAccess.ReadWrite, (inLen > 0 ? inLen : 1), true);
        try {
            fs.Write(report, 0, report.Length);
            fs.Flush();
            if (inLen <= 0) return null;

            int deadline = Environment.TickCount + timeoutMs;
            while (true) {
                int remain = deadline - Environment.TickCount;
                if (remain <= 0) return null;
                byte[] buf = new byte[inLen];
                Task<int> t = fs.ReadAsync(buf, 0, inLen);
                if (!t.Wait(remain)) return null;
                int n = t.Result;
                if (n < 5) continue;
                if (buf[1] != devIdx) continue;
                // 정상 응답: byte3 = func<<4 | swId
                // 오류 응답: byte2 = 0xFF, byte4 = func<<4 | swId
                bool ok = ((buf[3] & 0x0F) == swId) || (buf[2] == 0xFF && (buf[4] & 0x0F) == swId);
                if (!ok) continue;
                byte[] res = new byte[n];
                Array.Copy(buf, res, n);
                return res;
            }
        } finally {
            try { fs.Dispose(); } catch { }
        }
    }
}
'@
}

# ------------------------------------------------------------------- helpers

function Write-Head([string]$t) {
    Write-Host ''
    Write-Host ("=" * 74) -ForegroundColor DarkGray
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("=" * 74) -ForegroundColor DarkGray
}

function Get-LogitechVendorCollections {
    # 로지텍의 모든 벤더 콜렉션 (진단 표시용)
    [LogiHid]::Enumerate([uint16]$Config.VendorId) | Where-Object { $_.UsagePage -ge 0xFF00 }
}

function Get-HidppCollections {
    # HID++ 리포트 크기는 long=20바이트, short=7바이트로 고정이다.
    # 그 외 크기의 벤더 콜렉션(G-Series 등)은 다른 프로토콜이므로 반드시 제외해야 한다.
    # 사용 페이지는 Unifying/Bolt 리시버가 0xFF00, BLE 직결이 0xFF43 을 쓴다.
    Get-LogitechVendorCollections |
        Where-Object { $_.OutLen -eq 20 -or $_.OutLen -eq 7 } |
        Sort-Object -Property `
            @{ Expression = { if ($_.UsagePage -eq 0xFF00 -or $_.UsagePage -eq 0xFF43) { 0 } else { 1 } } },
            @{ Expression = { if ($_.OutLen -eq 20) { 0 } else { 1 } } }
}

function Select-HidppPath {
    if ($Config.ForceHidPath) { return $Config.ForceHidPath }
    $c = Get-HidppCollections | Select-Object -First 1
    if ($c) { return $c.Path }
    return $null
}

function Invoke-Hidpp {
    param(
        [string] $Path,
        [byte]   $DeviceIndex,
        [byte]   $FeatureIndex,
        [byte]   $FunctionId,
        [byte[]] $Params = @(),
        [switch] $NoResponse,
        [int]    $TimeoutMs = 700
    )
    $dev = (Get-LogitechVendorCollections | Where-Object { $_.Path -eq $Path } | Select-Object -First 1)
    if (-not $dev) { throw "HID 콜렉션을 찾을 수 없습니다: $Path" }

    $outLen = $dev.OutLen
    $inLen  = $dev.InLen
    # HID++ 가 아닌 콜렉션에 쏘면 조용히 무시당하므로 여기서 걸러낸다.
    if ($outLen -ne 7 -and $outLen -ne 20) {
        throw "HID++ 콜렉션이 아닙니다 (출력 리포트 $outLen 바이트). HID++ 는 7 또는 20 바이트여야 합니다."
    }

    $swId = [byte]($Config.SoftwareId -band 0x0F)
    $buf  = New-Object byte[] $outLen
    $buf[0] = if ($outLen -ge 20) { 0x11 } else { 0x10 }   # long / short report id
    $buf[1] = $DeviceIndex
    $buf[2] = $FeatureIndex
    $buf[3] = [byte](($FunctionId -shl 4) -bor $swId)
    for ($i = 0; $i -lt $Params.Length -and (4 + $i) -lt $outLen; $i++) {
        $buf[4 + $i] = $Params[$i]
    }

    $want = if ($NoResponse) { 0 } else { $inLen }
    return [LogiHid]::Request($Path, $buf, $want, $TimeoutMs, $DeviceIndex, $swId)
}

function Get-FeatureIndex {
    param([string]$Path, [byte]$DeviceIndex, [uint16]$Feature = 0x1814)
    # Root(0x0000).getFeature(featureId) -> 응답 byte4 = feature index
    $hi = [byte](($Feature -shr 8) -band 0xFF)
    $lo = [byte]($Feature -band 0xFF)
    $r = Invoke-Hidpp -Path $Path -DeviceIndex $DeviceIndex -FeatureIndex 0x00 -FunctionId 0x00 -Params @($hi, $lo)
    if ($null -eq $r) { return 0 }
    if ($r[2] -eq 0xFF) { return 0 }     # 오류 응답
    return [int]$r[4]                    # 0 이면 미지원
}

function Get-CurrentHost {
    param([string]$Path, [byte]$DeviceIndex, [byte]$FeatureIndex)
    # 0x1814.getHostInfo() -> p0 = nbHost, p1 = currHost
    $r = Invoke-Hidpp -Path $Path -DeviceIndex $DeviceIndex -FeatureIndex $FeatureIndex -FunctionId 0x00
    if ($null -eq $r -or $r[2] -eq 0xFF) { return $null }
    return @{ NbHost = [int]$r[4]; CurrentHost = [int]$r[5] }
}

function Send-ChangeHost {
    param([int]$HostIndex)

    $path = Select-HidppPath
    if (-not $path) { throw '로지텍 HID++ 콜렉션을 찾지 못했습니다. 리시버(동글)가 꽂혀 있는지 확인하세요.' }

    $devIdx = [byte]$Config.MouseDeviceIndex
    $feat   = [byte]$Config.FeatureIndex
    if ($feat -eq 0) {
        $feat = [byte](Get-FeatureIndex -Path $path -DeviceIndex $devIdx)
        if ($feat -eq 0) { throw "장치 인덱스 $devIdx 에서 ChangeHost(0x1814) 를 찾지 못했습니다. -Discover 로 확인하세요." }
    }

    # 0x1814.setCurrentHost(hostIndex) — 성공하면 응답이 없다(링크가 이미 끊김).
    Invoke-Hidpp -Path $path -DeviceIndex $devIdx -FeatureIndex $feat `
                 -FunctionId 0x01 -Params @([byte]$HostIndex) -NoResponse | Out-Null

    Write-Host ("  -> ChangeHost(host={0}) 전송  [devIdx={1} featIdx=0x{2:X2}]" -f $HostIndex, $devIdx, $feat) -ForegroundColor Green
}

# 블루투스 연결 상태 속성. BLE 기기는 끊겨도 PnP 노드와 Status 가 그대로 남기 때문에
# Status 로는 판별할 수 없다. 이 속성은 실제 링크 상태를 돌려준다.
$script:PK_BT_CONNECTED = '{83DA6326-97A6-4088-9453-A1923F573B29} 15'

function Get-KeyboardDevice {
    if ($Config.KeyboardInstanceId) {
        return Get-PnpDevice -InstanceId $Config.KeyboardInstanceId -ErrorAction SilentlyContinue
    }
    if ($Config.KeyboardNamePattern) {
        return Get-PnpDevice -ErrorAction SilentlyContinue |
               Where-Object { $_.InstanceId -like 'BTH*' -and $_.FriendlyName -like "*$($Config.KeyboardNamePattern)*" } |
               Select-Object -First 1
    }
    throw '설정에서 KeyboardInstanceId 또는 KeyboardNamePattern 을 채워주세요. (-ListBluetooth 참고)'
}

function Get-DeviceProp {
    param([string]$InstanceId, [string]$KeyName)
    try {
        $v = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop
        if ($null -ne $v) { return $v.Data }
    } catch { }
    return $null
}

# 하위 HID 노드 개수. BLE 키보드가 끊기면 보통 HID 자식 노드가 사라진다.
function Get-ChildHidCount {
    param([string]$InstanceId)
    $children = Get-DeviceProp -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_Children'
    if ($null -eq $children) { return -1 }
    return @($children).Count
}

# 사용 가능한 판별 방식을 한 번만 정해서 캐시한다.
function Resolve-DetectMethod {
    if ($script:DetectResolved) { return $script:DetectResolved }

    $m = $Config.DetectMethod
    if ($m -ne 'Auto') { $script:DetectResolved = $m; return $m }

    $d = Get-KeyboardDevice
    if ($null -eq $d) { $script:DetectResolved = 'Status'; return 'Status' }

    if ($null -ne (Get-DeviceProp -InstanceId $d.InstanceId -KeyName $script:PK_BT_CONNECTED)) {
        $script:DetectResolved = 'BtConnected'
    } elseif ((Get-ChildHidCount -InstanceId $d.InstanceId) -ge 0) {
        $script:DetectResolved = 'ChildHid'
    } else {
        $script:DetectResolved = 'Status'
    }
    return $script:DetectResolved
}

function Test-KeyboardConnected {
    $d = Get-KeyboardDevice
    if ($null -eq $d) { return $false }

    switch (Resolve-DetectMethod) {
        'BtConnected' {
            $v = Get-DeviceProp -InstanceId $d.InstanceId -KeyName $script:PK_BT_CONNECTED
            if ($null -eq $v) { return ($d.Status -eq 'OK') }
            return [bool]$v
        }
        'ChildHid' {
            return ((Get-ChildHidCount -InstanceId $d.InstanceId) -gt 0)
        }
        'Property' {
            if (-not $Config.DetectPropertyKey) { throw 'DetectMethod=Property 인데 DetectPropertyKey 가 비어 있습니다.' }
            $v = Get-DeviceProp -InstanceId $d.InstanceId -KeyName $Config.DetectPropertyKey
            return ((($v -join ',')) -eq $Config.DetectPropertyConnectedValue)
        }
        default {
            return ($d.Status -eq 'OK')
        }
    }
}

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
