package com.example.logiswitch

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * HID++ 2.0 패킷 조립/해석.
 *
 * long report (20바이트):
 *   [0] 0x11  리포트 ID
 *   [1] devIdx        BLE 직결이면 0xFF
 *   [2] featureIndex  런타임에 조회해야 함 (펌웨어마다 다름)
 *   [3] (funcId shl 4) or swId
 *   [4..] 파라미터
 *
 * BLE 벤더 GATT 특성에 쓸 때 리포트 ID 바이트가 필요한지는 확인되지 않았다.
 * 그래서 includeReportId 로 두 방식 다 시도할 수 있게 해 둔다.
 */
object Hidpp {
    const val SW_ID = 0x0D
    const val DEV_INDEX_BLE = 0xFF
    const val FEATURE_CHANGE_HOST = 0x1814

    /** 로지텍 독자 GATT 서비스. HID 서비스(0x1812)와 별개라 일반 앱이 접근 가능하다. */
    const val VENDOR_SERVICE = "00010000-0000-1000-8000-011f2000046d"

    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    /**
     * HID++ 패킷 조립.
     * long  = 20바이트, 리포트 ID 0x11
     * short =  7바이트, 리포트 ID 0x10
     * includeReportId=false 면 맨 앞 바이트를 뗀다 (19 / 6바이트).
     */
    fun packet(devIdx: Int, featIdx: Int, funcId: Int, params: IntArray,
               longReport: Boolean, includeReportId: Boolean): ByteArray {
        val size = if (longReport) 20 else 7
        val full = ByteArray(size)
        full[0] = if (longReport) 0x11 else 0x10
        full[1] = (devIdx and 0xFF).toByte()
        full[2] = (featIdx and 0xFF).toByte()
        full[3] = (((funcId and 0x0F) shl 4) or (SW_ID and 0x0F)).toByte()
        for (i in params.indices) if (4 + i < size) full[4 + i] = (params[i] and 0xFF).toByte()
        return if (includeReportId) full else full.copyOfRange(1, size)
    }

    fun report(devIdx: Int, featIdx: Int, funcId: Int, params: IntArray, includeReportId: Boolean): ByteArray =
        packet(devIdx, featIdx, funcId, params, true, includeReportId)

    /** Root(0x0000).getFeature(featureId) */
    fun rootGetFeature(featureId: Int, includeReportId: Boolean): ByteArray =
        report(DEV_INDEX_BLE, 0x00, 0x00,
            intArrayOf((featureId shr 8) and 0xFF, featureId and 0xFF), includeReportId)

    /** 0x1814.setCurrentHost(hostIndex) — 0-based. 0 = 채널1, 1 = 채널2, 2 = 채널3 */
    fun setCurrentHost(featIdx: Int, hostIndex: Int, includeReportId: Boolean): ByteArray =
        report(DEV_INDEX_BLE, featIdx, 0x01, intArrayOf(hostIndex), includeReportId)

    /** 0x1814.getHostInfo() */
    fun getHostInfo(featIdx: Int, includeReportId: Boolean): ByteArray =
        report(DEV_INDEX_BLE, featIdx, 0x00, intArrayOf(), includeReportId)

    /** 응답에서 리포트 ID를 떼어 [devIdx, featIdx, fn|sw, p0, p1, ...] 형태로 정규화. */
    fun normalize(raw: ByteArray): ByteArray {
        if (raw.size < 4) return raw
        val b0 = raw[0].toInt() and 0xFF
        return if (b0 == 0x11 || b0 == 0x10) raw.copyOfRange(1, raw.size) else raw
    }

    /** 오류 응답이면 true. 형식: devIdx, 0xFF, origFeat, origFn|sw, errCode */
    fun isError(n: ByteArray): Boolean = n.size >= 5 && (n[1].toInt() and 0xFF) == 0xFF

    fun errorCode(n: ByteArray): Int = if (n.size >= 5) n[4].toInt() and 0xFF else -1

    fun hex(b: ByteArray): String = b.joinToString(" ") { String.format("%02X", it) }

    fun parseHex(s: String): ByteArray? {
        val parts = s.trim().split(Regex("[\\s,]+")).filter { it.isNotEmpty() }
        if (parts.isEmpty()) return null
        val out = ByteArray(parts.size)
        for (i in parts.indices) {
            val v = parts[i].removePrefix("0x").removePrefix("0X").toIntOrNull(16) ?: return null
            out[i] = v.toByte()
        }
        return out
    }
}

/**
 * 마우스에 GATT로 붙어 HID++ 명령을 쓰는 클라이언트.
 * 모든 메서드는 블로킹이므로 반드시 백그라운드 스레드에서 호출할 것.
 */
@SuppressLint("MissingPermission")
class HidppBle(private val ctx: Context, private val log: (String) -> Unit) {

    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null

    private val connQ = LinkedBlockingQueue<Boolean>()
    private val discQ = LinkedBlockingQueue<Boolean>()
    private val writeAckQ = LinkedBlockingQueue<Int>()
    private val descAckQ = LinkedBlockingQueue<Boolean>()
    private val notifyQ = LinkedBlockingQueue<ByteArray>()
    private val readQ = LinkedBlockingQueue<Pair<Int, ByteArray>>()

    private val cb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> connQ.offer(true)
                BluetoothProfile.STATE_DISCONNECTED -> {
                    connQ.offer(false)
                    notifyQ.offer(ByteArray(0))   // 대기 중인 request 를 깨운다
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            discQ.offer(status == BluetoothGatt.GATT_SUCCESS)
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            writeAckQ.offer(status)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            descAckQ.offer(status == BluetoothGatt.GATT_SUCCESS)
        }

        @Deprecated("API 32 이하에서 호출됨")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            c.value?.let { notifyQ.offer(it.copyOf()) }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            notifyQ.offer(value.copyOf())
        }

        @Deprecated("API 32 이하에서 호출됨")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION")
            readQ.offer(Pair(status, c.value?.copyOf() ?: ByteArray(0)))
        }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            readQ.offer(Pair(status, value.copyOf()))
        }
    }

    fun connect(dev: BluetoothDevice, timeoutMs: Long = 10_000): Boolean {
        close()
        connQ.clear(); discQ.clear(); notifyQ.clear()
        log("연결 시도: ${dev.address}")
        gatt = dev.connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE)
        if (gatt == null) { log("connectGatt 실패"); return false }

        val connected = connQ.poll(timeoutMs, TimeUnit.MILLISECONDS)
        if (connected != true) { log("연결 타임아웃 — 마우스가 폰 채널에 켜져 있는지 확인"); close(); return false }
        log("연결됨. 서비스 탐색 중...")

        if (gatt?.discoverServices() != true) { log("discoverServices 호출 실패"); close(); return false }
        val ok = discQ.poll(timeoutMs, TimeUnit.MILLISECONDS)
        if (ok != true) { log("서비스 탐색 실패"); close(); return false }
        return true
    }

    fun services(): List<BluetoothGattService> = gatt?.services ?: emptyList()

    /** 발견한 서비스/특성을 사람이 읽을 수 있게 덤프. 회사에서 이 출력을 캡처해 오면 됨. */
    fun dump(): String {
        val sb = StringBuilder()
        val svcs = services()
        if (svcs.isEmpty()) return "(서비스 없음)"
        for (s in svcs) {
            val vendor = if (s.uuid.toString().equals(Hidpp.VENDOR_SERVICE, true)) "   <<< 로지텍 벤더 서비스" else ""
            sb.append("SERVICE ${s.uuid}$vendor\n")
            for (c in s.characteristics) {
                sb.append("   CHAR ${c.uuid}  [${propNames(c.properties)}]\n")
            }
        }
        return sb.toString()
    }

    fun characteristicsOf(serviceUuid: UUID): List<BluetoothGattCharacteristic> =
        gatt?.getService(serviceUuid)?.characteristics ?: emptyList()

    /**
     * 쓰기/알림 특성을 결정하고 알림을 켠다.
     * 인자가 null 이면 서비스 안에서 자동으로 고른다. 응답이 어디로 올지 모르므로
     * NOTIFY/INDICATE 가 있는 특성은 전부 구독한다.
     */
    fun bind(serviceUuid: UUID, writeUuid: UUID?, notifyUuid: UUID?): Boolean {
        val g = gatt ?: return false
        val svc = g.getService(serviceUuid)
        if (svc == null) { log("서비스를 찾을 수 없음: $serviceUuid"); return false }

        val writable = svc.characteristics.filter {
            it.properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or
                               BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
        }
        writeChar = when {
            writeUuid != null -> svc.getCharacteristic(writeUuid)
            writable.size == 1 -> writable[0].also { log("쓰기 특성 자동 선택: ${it.uuid}") }
            else -> null
        }
        if (writeChar == null) {
            log("쓰기 특성을 정하지 못했습니다 (후보 ${writable.size}개). 목록에서 직접 고르세요.")
            return false
        }
        log("쓰기 특성: ${writeChar!!.uuid} [${propNames(writeChar!!.properties)}]")

        // 알림 대상: 지정됐으면 그것만, 아니면 구독 가능한 전부
        val notifyTargets = if (notifyUuid != null) {
            listOfNotNull(svc.getCharacteristic(notifyUuid))
        } else {
            svc.characteristics.filter {
                it.properties and (BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                                   BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0
            }
        }

        if (notifyTargets.isEmpty()) {
            log("경고: 구독할 알림 특성이 없습니다. 응답을 받을 수 없습니다.")
        }
        for (nc in notifyTargets) {
            val ok = enableNotify(g, nc)
            log("알림 구독 ${nc.uuid} -> " + if (ok) "성공" else "실패")
        }
        return true
    }

    private fun enableNotify(g: BluetoothGatt, c: BluetoothGattCharacteristic): Boolean {
        if (!g.setCharacteristicNotification(c, true)) {
            log("  setCharacteristicNotification 거부됨: ${c.uuid}")
            return false
        }
        val d = c.getDescriptor(Hidpp.CCCD)
        if (d == null) { log("  CCCD(0x2902) 디스크립터 없음: ${c.uuid}"); return false }
        val value = if (c.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0)
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        else
            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE

        descAckQ.clear()
        val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(d, value) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run { d.value = value; g.writeDescriptor(d) }
        }
        if (!started) return false
        return descAckQ.poll(3000, TimeUnit.MILLISECONDS) == true
    }

    /**
     * 페이로드를 쓰고 알림 응답을 기다린다.
     * waitMs <= 0 이면 응답을 기다리지 않는다 (setCurrentHost 는 응답이 오지 않음).
     */
    fun request(payload: ByteArray, waitMs: Long, writeTypeOverride: Int = -1): ByteArray? {
        val g = gatt ?: return null
        val c = writeChar ?: return null

        notifyQ.clear(); writeAckQ.clear()
        val type = if (writeTypeOverride >= 0) writeTypeOverride
        else if (c.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0)
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        else
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE

        log("  TX  ${Hidpp.hex(payload)}")
        val started = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val rc = g.writeCharacteristic(c, payload, type)
                if (rc != BluetoothStatusCodes.SUCCESS) log("  writeCharacteristic 거부 rc=$rc")
                rc == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run { c.writeType = type; c.value = payload; g.writeCharacteristic(c) }
            }
        } catch (e: Exception) {
            log("  write 예외: ${e.javaClass.simpleName}: ${e.message}"); false
        }
        if (!started) return null

        if (type == BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) {
            val st = writeAckQ.poll(3000, TimeUnit.MILLISECONDS)
            when {
                st == null -> log("  write ACK 없음 (타임아웃)")
                st != BluetoothGatt.GATT_SUCCESS -> log("  write 실패 status=$st")
            }
        }
        if (waitMs <= 0) return null

        val r = notifyQ.poll(waitMs, TimeUnit.MILLISECONDS)
        if (r == null) { log("  응답 없음 (타임아웃)"); return null }
        if (r.isEmpty()) { log("  응답 없음 (링크 끊김)"); return null }
        log("  RX  ${Hidpp.hex(r)}")
        return r
    }

    /** 특성을 읽는다. 응답이 알림이 아니라 read 로 오는 경우를 잡기 위한 것. */
    fun read(serviceUuid: UUID, charUuid: UUID, timeoutMs: Long = 2500): ByteArray? {
        val g = gatt ?: return null
        val c = g.getService(serviceUuid)?.getCharacteristic(charUuid) ?: return null
        if (c.properties and BluetoothGattCharacteristic.PROPERTY_READ == 0) return null
        readQ.clear()
        val ok = try { g.readCharacteristic(c) } catch (e: Exception) {
            log("  read 예외: ${e.javaClass.simpleName}"); false
        }
        if (!ok) { log("  read 호출 거부됨: $charUuid"); return null }
        val r = readQ.poll(timeoutMs, TimeUnit.MILLISECONDS)
        if (r == null) { log("  read 응답 없음"); return null }
        if (r.first != BluetoothGatt.GATT_SUCCESS) { log("  read 실패 status=${r.first}"); return null }
        return r.second
    }

    /**
     * 안드로이드가 HID 서비스(0x1812) 접근을 막는지 실제로 확인한다.
     * HOGP 에서 HID++ 가 원래 오가는 통로이므로, 열려 있다면 그쪽이 정답이다.
     */
    fun probeHidService() {
        val g = gatt ?: return
        val hid = g.getService(UUID.fromString("00001812-0000-1000-8000-00805f9b34fb"))
        if (hid == null) { log("HID 서비스 없음"); return }
        val target = hid.characteristics.firstOrNull {
            it.properties and BluetoothGattCharacteristic.PROPERTY_READ != 0
        }
        if (target == null) { log("HID 서비스에 읽을 특성 없음"); return }
        readQ.clear()
        val started = try {
            g.readCharacteristic(target)
        } catch (e: SecurityException) {
            log("HID 서비스 접근: 차단됨 (BLUETOOTH_PRIVILEGED 필요) — 예상된 결과")
            return
        } catch (e: Exception) {
            log("HID 서비스 접근: 예외 ${e.javaClass.simpleName}")
            return
        }
        if (!started) { log("HID 서비스 접근: 차단됨 (read 호출 거부)"); return }
        val r = readQ.poll(2500, TimeUnit.MILLISECONDS)
        when {
            r == null -> log("HID 서비스 접근: 응답 없음")
            r.first != BluetoothGatt.GATT_SUCCESS -> log("HID 서비스 접근: 거부 status=${r.first}")
            else -> log("HID 서비스 접근: 허용됨! (${Hidpp.hex(r.second)})")
        }
    }

    fun close() {
        try { gatt?.disconnect() } catch (_: Exception) {}
        try { gatt?.close() } catch (_: Exception) {}
        gatt = null
        writeChar = null
    }

    companion object {
        fun propNames(p: Int): String {
            val l = ArrayList<String>()
            if (p and BluetoothGattCharacteristic.PROPERTY_READ != 0) l.add("READ")
            if (p and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) l.add("WRITE")
            if (p and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) l.add("WRITE_NR")
            if (p and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) l.add("NOTIFY")
            if (p and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) l.add("INDICATE")
            return if (l.isEmpty()) "-" else l.joinToString("/")
        }
    }
}

/** 실제 전환 동작. MainActivity 의 수동 버튼과 AutoSwitchService 가 공유한다. */
object SwitchOp {

    @SuppressLint("MissingPermission")
    fun run(ctx: Context, p: Prefs, log: (String) -> Unit): Boolean {
        val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter: BluetoothAdapter? = mgr?.adapter
        if (adapter == null || !adapter.isEnabled) { log("블루투스가 꺼져 있습니다"); return false }

        val mac = p.mouseMac
        if (mac.isBlank()) { log("마우스를 먼저 선택하세요"); return false }

        val dev = try { adapter.getRemoteDevice(mac) } catch (e: Exception) { log("MAC 오류: $mac"); return false }

        val ble = HidppBle(ctx, log)
        try {
            if (!ble.connect(dev)) return false

            val svcUuid = try { UUID.fromString(p.serviceUuid) } catch (e: Exception) { log("서비스 UUID 형식 오류"); return false }
            // 비워두면 bind() 가 서비스 안에서 자동으로 고른다
            val wUuid = p.writeCharUuid.takeIf { it.isNotBlank() }?.let {
                try { UUID.fromString(it) } catch (e: Exception) { null }
            }
            val nUuid = p.notifyCharUuid.takeIf { it.isNotBlank() }?.let {
                try { UUID.fromString(it) } catch (e: Exception) { null }
            }

            if (!ble.bind(svcUuid, wUuid, nUuid)) return false

            // feature index 확보
            var feat = p.featureIndex
            if (feat <= 0) {
                log("ChangeHost feature index 조회 중...")
                val resp = ble.request(Hidpp.rootGetFeature(Hidpp.FEATURE_CHANGE_HOST, p.includeReportId), 2000)
                if (resp == null) { log("조회 응답 없음 — 알림 특성 설정 또는 Report ID 옵션을 바꿔보세요"); return false }
                val n = Hidpp.normalize(resp)
                if (Hidpp.isError(n)) { log("오류 응답 (code=${Hidpp.errorCode(n)})"); return false }
                feat = n.getOrNull(3)?.toInt()?.and(0xFF) ?: 0
                if (feat == 0) { log("0x1814 미지원으로 응답됨"); return false }
                log("feature index = 0x%02X".format(feat))
                p.featureIndex = feat
            }

            log("ChangeHost(host=${p.targetHost}) 전송")
            ble.request(Hidpp.setCurrentHost(feat, p.targetHost, p.includeReportId), 0)
            log("전송 완료 — 성공하면 마우스가 즉시 다른 호스트로 넘어갑니다")
            return true
        } catch (e: Exception) {
            log("예외: ${e.message}")
            return false
        } finally {
            ble.close()
        }
    }
}
