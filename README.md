# mouse-flow

독거미 키보드의 블루투스 채널 전환(`Fn+1` / `Fn+2`)에 **MX Vertical 마우스를 따라가게** 만드는 도구.
로지텍의 Enhanced Easy-Switch를 직접 구현한 것으로, 로지텍 키보드가 아니어도 동작한다.

> **검증 상태**: PowerShell 스크립트는 문법 검사만 통과했고, 실제 하드웨어에서의 동작은
> 아직 확인되지 않았다. 안드로이드 쪽 GATT 경로는 이론적 근거만 있고 **미검증**이다.
> 아래 "회사에서 할 일" 순서대로 진행하면서 확인할 것.

---

## 원리

Easy-Switch 버튼이 하는 일은 로지텍 독자 프로토콜 HID++ 의 **feature `0x1814` (ChangeHost)** 명령이다.
소프트웨어로도 보낼 수 있다. Logi Options+ 가 UI 에 노출하지 않을 뿐이다.

```
11 FF <featureIndex> <(funcId<<4)|swId> <hostIndex> 00 00 ...   (20바이트 long report)
                     funcId=1 : setCurrentHost
                                            hostIndex 는 0-based
                                            0=채널1, 1=채널2, 2=채널3
```

핵심 제약이 하나 있다. **ChangeHost 는 밀어내기만 되고 불러오기는 안 된다.**
명령이 성공하는 순간 무선 링크가 끊기므로 응답도 오지 않는다.
그래서 양쪽에 각각 "밀어내는 쪽"을 두어야 한다.

| 방향 | 조작 | 키보드 | 마우스 |
|---|---|---|---|
| PC → 폰 | `Fn+2` | 자체 전환 | **PC 의 PowerShell** 이 리시버로 ChangeHost(폰) |
| 폰 → PC | `Fn+1` | 자체 전환 | **폰의 앱** 이 BLE 로 ChangeHost(PC) |

---

## 구성

```
pc/LogiSwitch.ps1     Windows 감시 스크립트 (외부 실행파일 불필요, 관리자 권한 불필요)
android/              폰 앱 (설정 + 진단 + 자동 전환)
```

### PC 쪽이 순수 PowerShell 인 이유

흔히 쓰이는 `hidapitester.exe` 를 쓰지 않았다.

- 망분리 PC 에서 GitHub 다운로드가 안 될 가능성이 높다
- 미서명 서드파티 바이너리는 AppLocker/WDAC/백신에 걸린다

대신 `hid.dll` / `setupapi.dll` 을 P/Invoke 로 직접 호출한다.
HID 벤더 콜렉션(usage page `0xFF00` 이상)은 일반 사용자 권한으로 열 수 있다.

### 폰 앱이 GATT 로 접근 가능한 이유

로지텍 BLE 마우스는 GATT 서비스를 두 개 노출한다.

| 서비스 | UUID | 앱 접근 |
|---|---|---|
| HID over GATT | `0x1812` | ❌ 시스템 전용으로 보호됨 |
| 로지텍 독자 서비스 | `00010000-0000-1000-8000-011f2000046d` | ✅ 일반 커스텀 서비스 |

HID++ 는 **독자 서비스** 로 오간다. 벤더 UUID 는 플랫폼 제약을 받지 않으므로
`BLUETOOTH_CONNECT` 권한만 있는 평범한 앱이 루팅 없이 쓸 수 있다.

---

## 사전 준비: 채널 배치

| | 채널 1 | 채널 2 |
|---|---|---|
| 독거미 | BT1 = PC | BT2 = 폰 |
| MX Vertical | **Unifying/Bolt 리시버 = PC** | BT = 폰 |

마우스의 PC 쪽은 반드시 **리시버**여야 한다. 블루투스로 붙어 있으면
Windows 에서 HID++ 벤더 콜렉션에 접근할 수 없어 PC→폰 방향이 성립하지 않는다.

---

## 회사에서 할 일

### A. PC (5분)

```powershell
git pull
```

**A-1. 키보드 InstanceId 찾기** — 키보드를 PC 채널(`Fn+1`)로 둔 상태에서:

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitch.ps1 -ListBluetooth
```

`BTHLE\...` 로 시작하고 Status 가 `OK` 인 항목을 찾아 InstanceId 를 통째로 복사한다.

**A-2. 마우스 슬롯과 feature index 찾기** — 마우스를 리시버 채널로 켜 둔 상태에서:

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitch.ps1 -Discover
```

`MouseDeviceIndex` 와 `FeatureIndex` 를 알려준다.
"로지텍 벤더 HID 콜렉션이 없습니다" 가 뜨면 리시버가 안 꽂혀 있거나 마우스가 BT 로 붙어 있는 것이다.

**A-3. `pc/LogiSwitch.ps1` 상단 `$Config` 채우기**

```powershell
KeyboardInstanceId = 'BTHLE\DEV_...'   # A-1 결과
MouseDeviceIndex   = 1                 # A-2 결과
FeatureIndex       = 0x0A              # A-2 결과
TargetHostIndex    = 1                 # 폰이 채널2 면 1
```

**A-4. 감지가 되는지 먼저 확인** — 실행해 두고 `Fn+1` / `Fn+2` 를 눌러본다:

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitch.ps1 -MonitorKeyboard
```

연결됨/끊김이 실시간으로 바뀌면 감지 절반은 끝난 것이다.

**A-5. 전송 단독 시험**

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitch.ps1 -SwitchTo 1
```

마우스가 폰으로 넘어가면 성공.

**A-6. 실사용**

```powershell
powershell -ExecutionPolicy Bypass -File .\pc\LogiSwitch.ps1 -Watch
```

시작프로그램에 넣으려면 `Win+R` → `shell:startup` 에 위 명령의 바로가기를 만든다.

### B. 폰 (10분)

앱은 집에서 Android Studio 로 빌드해 미리 설치해 둔다 (`android/` 를 열고 Run).
외부 의존성이 없어서 기본 템플릿 그대로 빌드된다.

1. 마우스를 폰 채널로 전환 (바닥 버튼)
2. 앱 실행 → 권한 허용 → 키보드/마우스 선택
3. **[연결 + 서비스 탐색]**
   - 로그에 `00010000-0000-1000-8000-011f2000046d` 가 보이는지 확인 ← **여기가 갈림길**
   - 안 보이면 폰 쪽 경로는 불가. PC 방향만 쓰면 된다
4. 쓰기 특성 / 알림 특성 선택 (`WRITE` 와 `NOTIFY` 속성 참고)
5. **[Feature Index 조회]** — 응답이 오면 프로토콜이 통한 것
   - 응답이 없으면 **"리포트 ID 포함" 체크를 반대로** 하고 다시. 이게 가장 흔한 실패 원인이다
   - 알림 특성을 다른 것으로 바꿔가며 시도
6. **[지금 전환]** — 마우스가 PC 로 넘어가면 완성
7. **자동 전환** 켜기

---

## 잘 안 될 때

| 증상 | 확인할 것 |
|---|---|
| `-Discover` 에서 콜렉션 없음 | 리시버가 안 꽂혔거나 마우스가 BT 연결. 리시버 채널로 전환 |
| `-Discover` 에서 슬롯 전부 무응답 | 마우스가 리시버 채널로 켜져 있는지. 전원 스위치 확인 |
| 슬롯이 여러 개 나옴 | 키보드도 리시버에 물린 것. 마우스 슬롯을 골라 넣을 것 |
| `-MonitorKeyboard` 가 안 변함 | InstanceId 가 틀렸다. `BTHLE\` 항목인지 확인 |
| 스크립트 실행 차단 | 실행 정책이 GPO 로 잠긴 것. 정책 확인 필요 |
| 앱에서 벤더 서비스 안 보임 | 폰 쪽 경로 불가. PC 방향만 사용 |
| 앱 Feature Index 조회 무응답 | 리포트 ID 체크 반대로 / 알림 특성 변경 |
| 자동 전환이 멋대로 발동 | "화면 켜져 있을 때만" 켜기, 디바운스 늘리기 |

---

## 알려진 한계

- 마우스가 폰에 있는 동안 PC 는 마우스와 무선 링크가 완전히 없다. 폰 쪽 앱이 안 되면 복귀는 물리 버튼뿐이다.
- 키보드가 절전이나 거리 이탈로 끊겨도 트리거된다. 디바운스와 화면 상태 조건으로 완화한다.
- 폰 앱의 GATT 경로는 미검증이다. 실기 확인 전까지는 될지 알 수 없다.
- 사내 PC 에서 스크립트 실행이 정책상 허용되는지 사전에 확인할 것.
