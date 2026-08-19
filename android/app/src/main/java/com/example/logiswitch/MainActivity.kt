package com.example.logiswitch

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.text.method.ScrollingMovementMethod
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import java.util.UUID
import java.util.concurrent.Executors

/**
 * 설정 + 진단 화면.
 *
 * 회사에서 마우스를 처음 만났을 때 이 순서로 쓰면 된다:
 *   1) 권한 허용
 *   2) 마우스/키보드 선택
 *   3) [연결 + 서비스 탐색]  -> 로그에 서비스 목록이 뜬다. 벤더 서비스가 보이는지 확인
 *   4) 쓰기/알림 특성 선택
 *   5) [Feature Index 조회]  -> 응답이 오면 성공
 *   6) [지금 전환]           -> 마우스가 PC 로 넘어가면 끝
 *   7) 자동 전환 켜기
 */
@SuppressLint("MissingPermission")
class MainActivity : Activity() {

    private lateinit var p: Prefs
    private val io = Executors.newSingleThreadExecutor()

    private lateinit var logView: TextView
    private lateinit var kbSpinner: Spinner
    private lateinit var mouseSpinner: Spinner
    private lateinit var writeSpinner: Spinner
    private lateinit var notifySpinner: Spinner
    private lateinit var svcEdit: EditText
    private lateinit var featEdit: EditText
    private lateinit var hostEdit: EditText
    private lateinit var rawEdit: EditText
    private lateinit var rptCheck: CheckBox
    private lateinit var autoCheck: CheckBox
    private lateinit var screenCheck: CheckBox

    private var bonded: List<BluetoothDevice> = emptyList()
    private var charUuids: List<String> = emptyList()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        p = Prefs(this)
        setContentView(buildUi())
        requestPerms()
        loadBonded()
        restore()
        log("준비됨. 마우스를 폰 채널로 켜고 [연결 + 서비스 탐색] 을 누르세요.")
        showServiceLog()
    }

    override fun onResume() {
        super.onResume()
        showServiceLog()
    }

    /** 자동 전환은 화면을 안 보는 사이에 일어나므로, 열 때마다 기록을 먼저 보여준다. */
    private fun showServiceLog() {
        val t = EventLog.read(this)
        log("")
        log("=== 백그라운드 서비스 기록 ===")
        log(if (t.isBlank()) "(기록 없음)" else t.trim())
        log("=== 기록 끝 ===")
        log("")
    }

    // ------------------------------------------------------------------ UI

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun buildUi(): ScrollView {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(16), dp(16), dp(16))
        }

        fun head(t: String) = root.addView(TextView(this).apply {
            text = t
            setTypeface(null, Typeface.BOLD)
            textSize = 15f
            setPadding(0, dp(18), 0, dp(4))
        })

        fun label(t: String) = root.addView(TextView(this).apply {
            text = t
            textSize = 13f
            setPadding(0, dp(8), 0, dp(2))
        })

        fun button(t: String, onClick: () -> Unit) = root.addView(Button(this).apply {
            text = t
            setOnClickListener { onClick() }
        }, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))

        head("1. 기기")

        label("키보드 (이 기기가 끊기면 마우스를 밀어냅니다)")
        kbSpinner = Spinner(this); root.addView(kbSpinner)

        label("마우스 (전환 대상)")
        mouseSpinner = Spinner(this); root.addView(mouseSpinner)

        button("기기 목록 새로고침") { loadBonded() }

        head("2. GATT 탐색")

        label("서비스 UUID")
        svcEdit = EditText(this).apply { setSingleLine(); textSize = 12f }
        root.addView(svcEdit)

        button("연결 + 서비스 탐색") { doDiscover() }

        label("쓰기 특성")
        writeSpinner = Spinner(this); root.addView(writeSpinner)

        label("알림 특성 (응답 수신용, 없으면 비워도 됨)")
        notifySpinner = Spinner(this); root.addView(notifySpinner)

        rptCheck = CheckBox(this).apply {
            text = "페이로드에 리포트 ID(0x11) 포함  ← 안 되면 꺼보세요"
            textSize = 13f
        }
        root.addView(rptCheck)

        head("3. 전환")

        label("Feature Index (16진수, 비우면 자동 조회)")
        featEdit = EditText(this).apply { setSingleLine(); textSize = 12f }
        root.addView(featEdit)

        label("대상 호스트 (0-based:  0=채널1, 1=채널2, 2=채널3)")
        hostEdit = EditText(this).apply { setSingleLine(); textSize = 12f }
        root.addView(hostEdit)

        button("전체 조합 자동 탐색  ★ 먼저 이걸 누르세요") { doSweep() }
        button("Feature Index 조회") { doProbeFeature() }
        button("지금 전환") { doSwitch() }

        head("4. 자동 전환")

        autoCheck = CheckBox(this).apply {
            text = "키보드가 끊기면 자동으로 전환"
            textSize = 13f
            setOnCheckedChangeListener { _, checked -> onAutoToggled(checked) }
        }
        root.addView(autoCheck)

        screenCheck = CheckBox(this).apply {
            text = "화면이 켜져 있을 때만 (주머니 속 오발 방지)"
            textSize = 13f
        }
        root.addView(screenCheck)

        head("5. 수동 전송 (실험용)")

        label("RAW 바이트 (예: 11 FF 00 0D 18 14 00)")
        rawEdit = EditText(this).apply { setSingleLine(); textSize = 12f }
        root.addView(rawEdit)
        button("RAW 전송") { doRaw() }

        head("로그")
        button("서비스 기록 보기  (자동 전환이 왜 안 됐는지)") {
            logView.text = ""
            log("=== 백그라운드 서비스 기록 ===")
            log(EventLog.read(this))
        }
        button("서비스 기록 지우기") { EventLog.clear(this); log("서비스 기록 삭제됨") }
        button("로그 지우기") { logView.text = "" }

        logView = TextView(this).apply {
            textSize = 11f
            setTextColor(Color.DKGRAY)
            typeface = Typeface.MONOSPACE
            movementMethod = ScrollingMovementMethod()
            setTextIsSelectable(true)
        }
        root.addView(logView)

        return ScrollView(this).apply { addView(root) }
    }

    // ------------------------------------------------------------- 설정 저장

    private fun restore() {
        svcEdit.setText(p.serviceUuid)
        featEdit.setText(if (p.featureIndex > 0) "%02X".format(p.featureIndex) else "")
        hostEdit.setText(p.targetHost.toString())
        rptCheck.isChecked = p.includeReportId
        autoCheck.isChecked = p.autoEnabled
        screenCheck.isChecked = p.onlyWhenScreenOn
    }

    private fun persist() {
        p.serviceUuid = svcEdit.text.toString().trim()
        p.featureIndex = featEdit.text.toString().trim().toIntOrNull(16) ?: 0
        p.targetHost = hostEdit.text.toString().trim().toIntOrNull()?.coerceIn(0, 2) ?: 0
        p.includeReportId = rptCheck.isChecked
        p.onlyWhenScreenOn = screenCheck.isChecked

        bonded.getOrNull(kbSpinner.selectedItemPosition)?.let { p.keyboardMac = it.address }
        bonded.getOrNull(mouseSpinner.selectedItemPosition)?.let { p.mouseMac = it.address }

        p.writeCharUuid = charUuids.getOrNull(writeSpinner.selectedItemPosition - 1) ?: ""
        p.notifyCharUuid = charUuids.getOrNull(notifySpinner.selectedItemPosition - 1) ?: ""
    }

    // ---------------------------------------------------------------- 동작

    private fun doDiscover() {
        persist()
        val mac = p.mouseMac
        if (mac.isBlank()) { log("마우스를 먼저 선택하세요"); return }

        io.execute {
            val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
            if (adapter == null || !adapter.isEnabled) { log("블루투스가 꺼져 있습니다"); return@execute }

            val ble = HidppBle(this) { log(it) }
            try {
                val dev = adapter.getRemoteDevice(mac)
                if (!ble.connect(dev)) return@execute

                log("\n--- 서비스 목록 ---\n" + ble.dump())

                val want = try { UUID.fromString(svcEdit.text.toString().trim()) } catch (e: Exception) { null }
                var chars = want?.let { ble.characteristicsOf(it) } ?: emptyList()

                if (chars.isEmpty()) {
                    log("지정한 서비스에서 특성을 못 찾았습니다. 전체 특성을 나열합니다.")
                    chars = ble.services().flatMap { it.characteristics }
                }

                val list = chars.map { it.uuid.toString() }
                val labels = chars.map {
                    it.uuid.toString().substring(0, 8) + "…  [" + HidppBle.propNames(it.properties) + "]"
                }
                runOnUiThread { fillCharSpinners(list, labels) }
                log("특성 ${list.size}개를 목록에 채웠습니다. 쓰기/알림 특성을 고르세요.")
            } catch (e: Exception) {
                log("예외: ${e.message}")
            } finally {
                ble.close()
            }
        }
    }

    private fun doProbeFeature() = doSweep()

    /**
     * 확정된 BLE 프레이밍으로 ChangeHost feature index 를 조회한다.
     * 실패하면 진단에 필요한 응답을 그대로 보여준다.
     */
    private fun doSweep() {
        persist()
        if (p.mouseMac.isBlank()) { log("마우스를 먼저 선택하세요"); return }
        p.featureIndex = 0
        runOnUiThread { featEdit.setText("") }

        io.execute {
            val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
            if (adapter == null || !adapter.isEnabled) { log("블루투스가 꺼져 있습니다"); return@execute }

            val ble = HidppBle(this) { log(it) }
            try {
                if (!ble.connect(adapter.getRemoteDevice(p.mouseMac))) return@execute

                val svc = UUID.fromString(p.serviceUuid)
                val w = p.writeCharUuid.takeIf { it.isNotBlank() }?.let { UUID.fromString(it) }
                val n = p.notifyCharUuid.takeIf { it.isNotBlank() }?.let { UUID.fromString(it) }
                if (!ble.bind(svc, w, n)) return@execute

                log("")
                log("=== ChangeHost(0x1814) feature index 조회 ===")
                log("프레임: [featIdx][fn|sw][params...] 18바이트")

                val resp = ble.request(Hidpp.bleGetFeature(Hidpp.FEATURE_CHANGE_HOST), 2500)
                if (resp == null) { log("응답 없음"); return@execute }

                if (Hidpp.bleIsError(resp)) {
                    log("오류 응답: ${Hidpp.errName(Hidpp.bleErrorCode(resp))}")
                    log("  (반사된 featIdx=0x%02X fn|sw=0x%02X)".format(
                        resp[1].toInt() and 0xFF, resp[2].toInt() and 0xFF))
                    return@execute
                }

                val feat = Hidpp.bleParam(resp, 0)
                val type = Hidpp.bleParam(resp, 1)
                val ver  = Hidpp.bleParam(resp, 2)
                if (feat <= 0) { log("0x1814 미지원으로 응답됨 (featIdx=0)"); return@execute }

                log("★★ ChangeHost feature index = 0x%02X  (type=0x%02X ver=%d)".format(feat, type, ver))
                p.featureIndex = feat
                runOnUiThread { featEdit.setText("%02X".format(feat)) }

                val info = ble.request(Hidpp.bleGetHostInfo(feat), 2000)
                if (info != null && !Hidpp.bleIsError(info)) {
                    log("호스트 수=${Hidpp.bleParam(info, 0)}  현재=${Hidpp.bleParam(info, 1)} (0-based)")
                }

                log("")
                log("이제 [지금 전환] 을 누르세요.")
            } catch (e: Exception) {
                log("예외: ${e.message}")
            } finally {
                ble.close()
            }
        }
    }

    private fun doSwitch() {
        persist()
        io.execute { SwitchOp.run(this, p) { log(it) } }
    }

    private fun doRaw() {
        persist()
        val bytes = Hidpp.parseHex(rawEdit.text.toString())
        if (bytes == null) { log("HEX 파싱 실패"); return }
        io.execute {
            val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter ?: return@execute
            val ble = HidppBle(this) { log(it) }
            try {
                if (!ble.connect(adapter.getRemoteDevice(p.mouseMac))) return@execute
                val n = p.notifyCharUuid.takeIf { it.isNotBlank() }?.let { UUID.fromString(it) }
                val w = p.writeCharUuid.takeIf { it.isNotBlank() }?.let { UUID.fromString(it) }
                if (!ble.bind(UUID.fromString(p.serviceUuid), w, n)) return@execute
                ble.request(bytes, 2500)
            } catch (e: Exception) {
                log("예외: ${e.message}")
            } finally {
                ble.close()
            }
        }
    }

    private fun onAutoToggled(checked: Boolean) {
        persist()
        p.autoEnabled = checked
        val i = Intent(this, AutoSwitchService::class.java)
        if (checked) {
            if (p.keyboardMac.isBlank()) { log("키보드를 먼저 선택하세요"); autoCheck.isChecked = false; return }
            startForegroundService(i)
            log("자동 전환 켜짐. 키보드(${p.keyboardMac}) 연결 해제를 감시합니다.")
        } else {
            stopService(i)
            log("자동 전환 꺼짐")
        }
    }

    // ---------------------------------------------------------------- 유틸

    private fun loadBonded() {
        val adapter = (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        if (adapter == null) { log("블루투스 어댑터 없음"); return }
        bonded = try { adapter.bondedDevices?.toList() ?: emptyList() } catch (e: SecurityException) {
            log("권한이 없습니다. 권한을 허용하고 새로고침하세요."); emptyList()
        }
        val names = bonded.map { "${it.name ?: "(이름없음)"}  ${it.address}" }
        kbSpinner.adapter = simpleAdapter(names)
        mouseSpinner.adapter = simpleAdapter(names)

        bonded.indexOfFirst { it.address == p.keyboardMac }.takeIf { it >= 0 }?.let { kbSpinner.setSelection(it) }
        bonded.indexOfFirst { it.address == p.mouseMac }.takeIf { it >= 0 }?.let { mouseSpinner.setSelection(it) }
        log("페어링된 기기 ${bonded.size}개")
    }

    private fun fillCharSpinners(uuids: List<String>, labels: List<String>) {
        charUuids = uuids
        val withBlank = listOf("(선택 안 함)") + labels
        writeSpinner.adapter = simpleAdapter(withBlank)
        notifySpinner.adapter = simpleAdapter(withBlank)
        uuids.indexOfFirst { it == p.writeCharUuid }.takeIf { it >= 0 }?.let { writeSpinner.setSelection(it + 1) }
        uuids.indexOfFirst { it == p.notifyCharUuid }.takeIf { it >= 0 }?.let { notifySpinner.setSelection(it + 1) }
    }

    private fun simpleAdapter(items: List<String>) =
        ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, items)

    private fun requestPerms() {
        val need = ArrayList<String>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)
                need.add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                need.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (need.isNotEmpty()) requestPermissions(need.toTypedArray(), 1)
    }

    override fun onRequestPermissionsResult(rc: Int, perms: Array<out String>, res: IntArray) {
        super.onRequestPermissionsResult(rc, perms, res)
        loadBonded()
    }

    override fun onPause() { super.onPause(); persist() }

    private fun log(s: String) = runOnUiThread {
        logView.append(s + "\n")
    }
}
