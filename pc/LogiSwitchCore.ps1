<#
================================================================================
 LogiSwitchCore.ps1  -  공용 HID++ 엔진
================================================================================
 LogiSwitch.ps1 (명령줄) 과 LogiSwitchApp.ps1 (GUI) 이 함께 쓴다.
 점 소싱하기 전에 호출자가 $Config 해시테이블을 정의해 두어야 한다.

   . "$PSScriptRoot\LogiSwitchCore.ps1"
================================================================================
#>


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
