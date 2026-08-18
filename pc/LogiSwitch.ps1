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

function Get-HidppCollections {
    # 로지텍 벤더 콜렉션 (usage page 0xFF00 이상)만 추린다.
    # HID++ long report = 20바이트, short report = 7바이트.
    $all = [LogiHid]::Enumerate([uint16]$Config.VendorId)
    $all | Where-Object { $_.UsagePage -ge 0xFF00 } |
        Sort-Object -Property @{ Expression = { $_.OutLen } } -Descending
}

function Select-HidppPath {
    if ($Config.ForceHidPath) { return $Config.ForceHidPath }
    $c = Get-HidppCollections
    if (-not $c) { return $null }
    # long report(20B) 콜렉션 우선
    $long = $c | Where-Object { $_.OutLen -ge 20 } | Select-Object -First 1
    if ($long) { return $long.Path }
    return ($c | Select-Object -First 1).Path
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
    $dev = (Get-HidppCollections | Where-Object { $_.Path -eq $Path } | Select-Object -First 1)
    if (-not $dev) { throw "HID 콜렉션을 찾을 수 없습니다: $Path" }

    $outLen = $dev.OutLen
    $inLen  = $dev.InLen
    if ($outLen -lt 7) { throw "출력 리포트 길이가 비정상입니다 ($outLen)." }

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

function Test-KeyboardConnected {
    if ($Config.KeyboardInstanceId) {
        $d = Get-PnpDevice -InstanceId $Config.KeyboardInstanceId -ErrorAction SilentlyContinue
    } elseif ($Config.KeyboardNamePattern) {
        $d = Get-PnpDevice -ErrorAction SilentlyContinue |
             Where-Object { $_.InstanceId -like 'BTH*' -and $_.FriendlyName -like "*$($Config.KeyboardNamePattern)*" } |
             Select-Object -First 1
    } else {
        throw '설정에서 KeyboardInstanceId 또는 KeyboardNamePattern 을 채워주세요. (-ListBluetooth 참고)'
    }
    if ($null -eq $d) { return $false }
    return ($d.Status -eq 'OK')
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

if ($Discover) {
    Write-Head '1) 로지텍 HID++ 콜렉션'
    $cols = Get-HidppCollections
    if (-not $cols) {
        Write-Host '  로지텍 벤더 HID 콜렉션이 없습니다.' -ForegroundColor Red
        Write-Host '  -> Unifying/Bolt 리시버가 꽂혀 있지 않거나, 마우스가 블루투스로 연결되어 있습니다.' -ForegroundColor Red
        Write-Host '     이 경우 PC 쪽 자동 전환은 불가능합니다 (폰 앱 경로만 가능).' -ForegroundColor Red
        return
    }
    $cols | ForEach-Object {
        Write-Host ("  PID=0x{0:X4}  UsagePage=0x{1:X4} Usage=0x{2:X4}  in={3} out={4}" -f $_.Pid, $_.UsagePage, $_.Usage, $_.InLen, $_.OutLen)
        Write-Host ("      $($_.Path)") -ForegroundColor DarkGray
    }
    $path = Select-HidppPath
    Write-Host ''
    Write-Host "  선택된 콜렉션: $path" -ForegroundColor Cyan

    Write-Head '2) 리시버에 물린 장치 슬롯 탐색 (1~6)'
    $found = @()
    foreach ($idx in 1..6) {
        try {
            $fi = Get-FeatureIndex -Path $path -DeviceIndex ([byte]$idx)
        } catch { $fi = 0 }
        if ($fi -ne 0) {
            $info = $null
            try { $info = Get-CurrentHost -Path $path -DeviceIndex ([byte]$idx) -FeatureIndex ([byte]$fi) } catch { }
            $cur = if ($info) { "호스트 $($info.CurrentHost) / 총 $($info.NbHost)개" } else { '조회 실패' }
            Write-Host ("  [슬롯 $idx]  ChangeHost 지원  featureIndex=0x{0:X2}   현재: $cur" -f $fi) -ForegroundColor Green
            $found += [pscustomobject]@{ Index = $idx; Feature = $fi }
        } else {
            Write-Host "  [슬롯 $idx]  응답 없음" -ForegroundColor DarkGray
        }
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
            Write-Host '  (여러 개 발견 — 키보드도 리시버에 물려 있을 수 있습니다. 마우스 슬롯을 고르세요.)' -ForegroundColor DarkYellow
        }
    }
    return
}

if ($MonitorKeyboard) {
    Write-Head '키보드 연결 상태 모니터 — Fn+1 / Fn+2 를 눌러보세요 (Ctrl+C 종료)'
    $last = $null
    while ($true) {
        try { $now = Test-KeyboardConnected } catch { Write-Host $_.Exception.Message -ForegroundColor Red; return }
        if ($now -ne $last) {
            $stamp = (Get-Date).ToString('HH:mm:ss.fff')
            if ($now) { Write-Host "  [$stamp]  연결됨   (PC 채널)"   -ForegroundColor Green }
            else      { Write-Host "  [$stamp]  끊김     (폰으로 넘어감)" -ForegroundColor Magenta }
            $last = $now
        }
        Start-Sleep -Milliseconds $Config.PollIntervalMs
    }
}

if ($PSCmdlet.ParameterSetName -eq 'SwitchTo') {
    if ($SwitchTo -lt 0 -or $SwitchTo -gt 2) { throw '-SwitchTo 는 0, 1, 2 중 하나여야 합니다 (0-based 호스트 인덱스).' }
    Write-Head "즉시 전환 -> 호스트 $SwitchTo (Easy-Switch 채널 $($SwitchTo + 1))"
    Send-ChangeHost -HostIndex $SwitchTo
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
