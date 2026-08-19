package com.example.logiswitch

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.os.Build
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import java.util.concurrent.Executors

/**
 * 키보드가 블루투스에서 끊기는 순간을 감지해 마우스를 다른 호스트로 밀어낸다.
 *
 * ACTION_ACL_DISCONNECTED 는 암시적 브로드캐스트 제한의 예외지만,
 * 실행 중인 포그라운드 서비스에서 동적으로 등록하는 쪽이 훨씬 안정적이다.
 */
class AutoSwitchService : Service() {

    private lateinit var p: Prefs
    private val io = Executors.newSingleThreadExecutor()
    private var lastFireAt = 0L
    private var busy = false

    private val handler = Handler(Looper.getMainLooper())
    private var lastConnected: Boolean? = null

    /**
     * 브로드캐스트가 안 올 수도 있으므로 연결 상태를 직접 확인한다.
     * 두 가지 방법을 모두 읽어서 어느 쪽이 실제를 반영하는지 기록으로 남긴다.
     *   A: BluetoothManager.getConnectedDevices(GATT)  - 공개 API
     *   B: BluetoothDevice.isConnected()               - 숨은 API, 막힐 수 있음
     */
    @SuppressLint("MissingPermission")
    private fun readKeyboardState(): Triple<Boolean?, Boolean?, Boolean?> {
        val mgr = getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val mac = p.keyboardMac

        val a: Boolean? = try {
            mgr?.getConnectedDevices(BluetoothProfile.GATT)
                ?.any { it.address.equals(mac, ignoreCase = true) }
        } catch (e: Exception) { null }

        val b: Boolean? = try {
            val dev = mgr?.adapter?.getRemoteDevice(mac)
            val m = android.bluetooth.BluetoothDevice::class.java.getMethod("isConnected")
            m.invoke(dev) as? Boolean
        } catch (e: Exception) { null }

        val eff = b ?: a
        return Triple(a, b, eff)
    }

    private val poller = object : Runnable {
        override fun run() {
            try { pollOnce() } catch (e: Exception) {
                EventLog.add(this@AutoSwitchService, "폴링 예외: " + e.message)
            }
            handler.postDelayed(this, 1500)
        }
    }

    private fun pollOnce() {
        if (p.keyboardMac.isBlank()) return
        val (a, b, eff) = readKeyboardState()
        if (eff == null) return

        if (lastConnected == null) {
            lastConnected = eff
            EventLog.add(this, "폴링 시작 상태: " + (if (eff) "연결됨" else "끊김") +
                    "  (GATT목록=" + a + " isConnected=" + b + ")")
            return
        }
        if (lastConnected == true && !eff) {
            EventLog.add(this, "폴링 감지: 키보드 끊김  (GATT목록=" + a + " isConnected=" + b + ")")
            lastConnected = false
            onKeyboardGone()
            return
        }
        if (lastConnected == false && eff) {
            EventLog.add(this, "폴링 감지: 키보드 다시 연결됨")
        }
        lastConnected = eff
    }


    @SuppressLint("MissingPermission")
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val act = intent.action ?: return

            val dev = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            else
                @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)

            val mac = dev?.address ?: "(주소없음)"
            val name = try { dev?.name ?: "?" } catch (e: Exception) { "?" }
            val kind = when (act) {
                BluetoothDevice.ACTION_ACL_CONNECTED -> "연결"
                BluetoothDevice.ACTION_ACL_DISCONNECTED -> "해제"
                else -> act
            }

            // 어떤 기기의 어떤 이벤트든 남긴다. MAC 이 틀렸으면 여기서 바로 보인다.
            val match = mac.equals(p.keyboardMac, ignoreCase = true)
            EventLog.add(this@AutoSwitchService,
                "BT " + kind + "  " + name + "  " + mac + (if (match) "   <<< 감시 대상" else ""))

            if (act != BluetoothDevice.ACTION_ACL_DISCONNECTED) return
            if (!match) return
            onKeyboardGone()
        }
    }

    override fun onCreate() {
        super.onCreate()
        p = Prefs(this)
        createChannel()

        // API 29+ 는 포그라운드 타입을 명시해야 하고, API 34 에서는 누락 시 예외가 난다.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIF_ID,
                buildNotification("키보드 연결 해제 감시 중"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
            )
        } else {
            startForeground(NOTIF_ID, buildNotification("키보드 연결 해제 감시 중"))
        }

        // API 34+ 는 리시버 등록 시 export 여부를 반드시 지정해야 한다.
        // 시스템 브로드캐스트만 받으므로 NOT_EXPORTED 가 맞다.
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_ACL_DISCONNECTED)
            addAction(BluetoothDevice.ACTION_ACL_CONNECTED)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
        val prev = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try { EventLog.add(this, "!! 처리되지 않은 예외 [" + t.name + "] " + e) } catch (x: Throwable) { }
            prev?.uncaughtException(t, e)
        }
        EventLog.add(this, "== 감시 서비스 시작 == 대상 키보드 ${p.keyboardMac}, host=${p.targetHost}")
        handler.post(poller)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        EventLog.add(this, "== 감시 서비스 종료 ==")
        handler.removeCallbacks(poller)
        try { unregisterReceiver(receiver) } catch (_: Exception) {}
        io.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ------------------------------------------------------------------

    private fun onKeyboardGone() {
        val now = SystemClock.elapsedRealtime()

        if (now - lastFireAt < p.debounceMs) {
            EventLog.add(this, "  무시: 디바운스")
            return
        }
        if (busy) { EventLog.add(this, "  무시: 이전 전환이 진행 중"); return }

        if (p.onlyWhenScreenOn) {
            val pmChk = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pmChk.isInteractive) {
                EventLog.add(this, "  무시: 화면 꺼짐 ('화면 켜져 있을 때만' 옵션)")
                notify("화면 꺼짐 상태라 무시함")
                return
            }
        }

        lastFireAt = now
        busy = true
        EventLog.add(this, "  전환 시작 -> host=" + p.targetHost)
        notify("키보드 끊김 감지 — 마우스 전환 중")

        io.execute {
            // 백그라운드 스레드에서 던져진 예외는 프로세스를 죽인다.
            // 자동 전환은 사용자가 화면을 안 보는 중에 돌아가므로 무엇도 새어나가면 안 된다.
            try {
                runSwitch()
            } catch (t: Throwable) {
                EventLog.add(this@AutoSwitchService, "  치명적 예외: " + t.javaClass.simpleName + ": " + t.message)
            } finally {
                busy = false
            }
        }
    }

    private fun runSwitch() {
        // wakelock 은 있으면 좋고 없어도 진행한다. 권한이 없으면 예외가 난다.
        var wl: PowerManager.WakeLock? = null
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LogiSwitch:switch")
            wl.acquire(30_000L)
        } catch (e: Exception) {
            EventLog.add(this, "  wakelock 실패(무시하고 진행): " + e.javaClass.simpleName)
            wl = null
        }

        try {
            val ok = try {
                SwitchOp.run(this, p) { line -> EventLog.add(this, "    " + line) }
            } catch (e: Exception) {
                EventLog.add(this, "    예외: " + e.javaClass.simpleName + ": " + e.message)
                false
            }
            EventLog.add(this, "  결과: " + (if (ok) "성공" else "실패"))
            notify(if (ok) "전환 명령 전송됨" else "전환 실패 — 앱에서 기록 확인")
        } finally {
            try { if (wl != null && wl.isHeld) wl.release() } catch (e: Exception) { }
        }
    }

    // ------------------------------------------------------------------

    private fun createChannel() {
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "LogiSwitch", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    private fun buildNotification(text: String): Notification {
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Builder(this, CHANNEL)
            .setContentTitle("LogiSwitch")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun notify(text: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification(text))
    }

    companion object {
        private const val CHANNEL = "logiswitch"
        private const val NOTIF_ID = 1001
    }
}
