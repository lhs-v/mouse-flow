# mouse-flow

독거미(AULA) 키보드의 블루투스 채널을 바꾸면 **MX Vertical 마우스가 따라오게** 만드는 도구.
로지텍의 Enhanced Easy-Switch 를 직접 구현한 것이라 로지텍 키보드가 아니어도 동작한다.

> **상태: 양방향 자동 전환 동작 확인** (2026-08-19)
> 사내망 Windows PC + Galaxy Z Fold 7 (Android 16) + MX Vertical + AULA F108 5.0

```
Fn+1  키보드 -> PC    :  폰 앱이 감지, 마우스를 PC 로 밀어냄
Fn+2  키보드 -> 폰    :  PC 스크립트가 감지, 마우스를 폰으로 밀어냄
```

> **처음 쓰시나요?** 클릭만으로 따라 할 수 있는 [사용법.md](%EC%82%AC%EC%9A%A9%EB%B2%95.md) 를 보세요.
> 아래 내용은 동작 원리와 프로토콜 분석입니다.

키 하나로 키보드와 마우스가 같이 넘어간다. 마우스를 들어 바닥 버튼을 누를 일이 없다.

---

## 왜 양쪽에 프로그램이 필요한가

Easy-Switch 는 HID++ 의 **feature `0x1814` (ChangeHost)** 명령이다. 그런데 이 명령은
**밀어내기만 되고 불러오기는 안 된다.** 명령이 성공하는 순간 무선 링크가 끊기므로
응답조차 오지 않는다. 마우스가 폰에 있는 동안 PC 는 마우스와 통신할 방법이 아예 없다.

그래서 "지금 마우스를 쥐고 있는 쪽"이 상대에게 넘겨주는 구조여야 한다.

| 방향 | 감지 | 전송 |
|---|---|---|
| PC → 폰 | PowerShell 이 키보드의 BT 링크 해제를 감지 | Unifying 리시버로 HID++ ChangeHost |
| 폰 → PC | 앱이 키보드 연결 상태를 폴링 | BLE 벤더 GATT 로 HID++ ChangeHost |

---

## 확인된 사실들

이 프로젝트에서 실기로 알아낸 것들. 문서화된 자료가 없어 하나씩 측정했다.

### BLE 벤더 GATT 프레임은 18바이트, 헤더가 없다

로지텍 BLE 마우스는 GATT 서비스를 두 개 노출한다.

| 서비스 | UUID | 앱 접근 |
|---|---|---|
| HID over GATT | `0x1812` | **불가** — `BLUETOOTH_PRIVILEGED` 필요 (실기 확인) |
| 로지텍 독자 서비스 | `00010000-0000-1000-8000-011f2000046d` | 가능 — 일반 커스텀 서비스 |

벤더 서비스에는 특성이 하나뿐이다: `00010001-...` `[READ/WRITE/WRITE_NR/NOTIFY]`

이 특성이 받는 프레임은 **리포트 ID 도 장치 인덱스도 없다.**

```
[0]     featureIndex
[1]     (funcId << 4) | swId
[2..17] parameters
                          총 18바이트 고정
```

20바이트 long report 에서 앞 2바이트를 뺀 것이다. 19·20바이트를 쓰면
`GATT_INVALID_ATTRIBUTE_LENGTH`(13) 로 거부된다.

**알아낸 방법**: `11 FF` 두 바이트만 써 봤더니 `FF 11 FF 07` 이 돌아왔다.
HID++ 2.0 오류 프레임은 `FF <원래 featIdx> <원래 fn|sw> <에러코드>` 이고,
보낸 두 바이트가 정확히 그 자리에 반사됐다. `07` 은 `INVALID_FUNCTION_ID`.

### 실제 교환 내용

```
TX  00 0D 18 14 …    Root.getFeature(0x1814)
RX  00 0D 0C 00 01   featureIndex=0x0C, type=0x00, version=1

TX  0C 0D …          0x1814.getHostInfo()
RX  0C 0D 03 01      호스트 3개, 현재 1 (0-based)

TX  0C 1D 02 …       0x1814.setCurrentHost(2)
RX  0C 1D 00         성공
```

`0C 1D` 에서 `1D` = `(funcId 1 << 4) | swId 0x0D`.

### 감지 신호는 양쪽 다 직관과 다르다

**PC**: 블루투스 LE 기기는 링크가 끊겨도 PnP 노드가 남고 `Status` 가 `OK` 를 유지한다.
페어링 정보가 유지되기 때문이다. 그래서 `Status` 로는 판별할 수 없고 링크 상태를 따로 읽어야 한다.

**폰**: `ACTION_ACL_DISCONNECTED` 브로드캐스트에만 의존하면 놓친다.
1.5초 폴링으로 연결 상태를 직접 확인하는 쪽이 확실하다.
`getConnectedDevices(GATT)` 와 숨은 `isConnected()` 둘 다 실제를 정확히 반영했다.

---

## 구성

```
LogiSwitch 시작.cmd   더블클릭용 런처
pc/LogiSwitchApp.ps1  Windows 데스크톱 앱 (GUI, 트레이 상주)
pc/LogiSwitchCore.ps1 공용 HID++ 엔진
pc/LogiSwitch.ps1     명령줄 진단 도구 (-Discover, -FindSignal 등)
android/              폰 앱 (상태 / 설정 / 고급 탭)
```

PC 쪽은 흔히 쓰는 `hidapitester.exe` 를 쓰지 않는다. 망분리 PC 는 GitHub 다운로드가 막혀 있고,
미서명 바이너리는 AppLocker/백신에 걸린다. 대신 `hid.dll` / `setupapi.dll` 을 P/Invoke 로 직접 호출한다.
HID 벤더 콜렉션은 일반 사용자 권한으로 열린다.

---

## 설정

### 채널 배치

| | 채널 1 | 채널 2 | 채널 3 |
|---|---|---|---|
| AULA F108 | BT1 = PC | BT2 = 폰 | |
| MX Vertical | | 폰 (BLE) | PC (Unifying 리시버) |

마우스의 PC 쪽은 **반드시 리시버**여야 한다. 블루투스로 붙으면 Windows 에서
HID++ 벤더 콜렉션에 접근할 수 없다.

`TargetHostIndex` 는 0-based 다. 위 배치면 PC 로 보낼 때 `2`, 폰으로 보낼 때 `1`.

### PC

```powershell
git clone https://github.com/lhs-v/mouse-flow.git
```

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitch.ps1 -ListBluetooth
```

키보드의 `BTHLE\...` InstanceId 를 복사한다.

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitch.ps1 -Discover
```

`MouseDeviceIndex` 와 `FeatureIndex` 를 알려준다.
`$Config` 에 값을 채운 뒤 감지가 되는지 먼저 본다.

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitch.ps1 -MonitorKeyboard
```

상태가 안 바뀌면 `-FindSignal` 로 실제 신호를 찾는다. 연결/해제 두 상태의 PnP 스냅샷을
떠서 무엇이 달라지는지 비교하고, `$Config` 에 넣을 값을 그대로 출력해 준다.

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitch.ps1 -Watch
```

시작프로그램은 `Win+R` → `shell:startup` 에 바로가기를 넣는다.

### 폰

[Releases](https://github.com/lhs-v/mouse-flow/releases) 에서 APK 를 받는다.
직접 빌드하려면 `android/` 를 Android Studio 로 열면 된다. 외부 의존성이 없다.

1. 권한 허용 → 키보드·마우스 선택
2. **[연결 + 서비스 탐색]** — 벤더 서비스가 보이는지 확인
3. **[전체 조합 자동 탐색]** — feature index 와 현재 호스트를 읽어온다
4. **대상 호스트** 에 PC 채널 번호 − 1 을 입력
5. **[지금 전환]** 로 수동 확인
6. **자동 전환** 켜기

---

## 잘 안 될 때

| 증상 | 원인 |
|---|---|
| `-Discover` 에서 콜렉션 없음 | 리시버 미연결, 또는 마우스가 BT 로 붙어 있음 |
| `제외 (HID++ 리포트 크기 아님)` 만 나옴 | 잡힌 로지텍 기기가 헤드셋/G-Series 등 다른 프로토콜 |
| `-MonitorKeyboard` 가 안 변함 | BLE 는 끊겨도 `Status` 가 `OK`. `-FindSignal` 사용 |
| 앱에서 벤더 서비스가 안 보임 | 마우스가 폰 채널로 켜져 있는지 확인 |
| `write 실패 status=13` | 프레임이 18바이트가 아님 |
| `오류 응답 InvalidFunctionID` | 프레임 구조는 맞고 funcId 가 틀림 |
| 자동 전환이 조용히 안 됨 | 앱을 열면 서비스 기록이 자동으로 표시된다. 거기 이유가 남는다 |
| 자동 전환이 멋대로 발동 | 키보드 절전 끊김. 디바운스를 늘리거나 "화면 켜져 있을 때만" 을 켠다 |

---

## 알려진 한계

- 폰 앱이 1.5초마다 폴링한다. 배터리 영향은 크지 않지만 0 은 아니다.
- 키보드가 절전이나 거리 이탈로 끊겨도 트리거된다. 기본 디바운스 5초로 완화한다.
- 마우스가 폰에 있는 동안 PC 는 마우스에 접근할 수 없다. 프로토콜상 불가피하다.
- 사내 PC 에서 스크립트 실행이 정책상 허용되는지 확인할 것.
