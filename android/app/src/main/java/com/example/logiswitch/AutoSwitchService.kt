package com.example.logiswitch

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
import android.os.IBinder
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

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (intent.action != BluetoothDevice.ACTION_ACL_DISCONNECTED) return

            val dev = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            else
                @Suppress("DEPRECATION") intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)

            val mac = dev?.address ?: return
            if (!mac.equals(p.keyboardMac, ignoreCase = true)) return

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
        val filter = IntentFilter(BluetoothDevice.ACTION_ACL_DISCONNECTED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        try { unregisterReceiver(receiver) } catch (_: Exception) {}
        io.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ------------------------------------------------------------------

    private fun onKeyboardGone() {
        val now = SystemClock.elapsedRealtime()
        if (now - lastFireAt < p.debounceMs) return
        if (busy) return

        if (p.onlyWhenScreenOn) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isInteractive) {
                notify("화면 꺼짐 상태라 무시함")
                return
            }
        }

        lastFireAt = now
        busy = true
        notify("키보드 끊김 감지 — 마우스 전환 중")

        io.execute {
            val sb = StringBuilder()
            val ok = try {
                SwitchOp.run(this@AutoSwitchService, p) { line -> sb.append(line).append('\n') }
            } catch (e: Exception) {
                sb.append("예외: ").append(e.message)
                false
            }
            busy = false
            notify(if (ok) "전환 명령 전송됨" else "전환 실패 — 앱에서 로그 확인")
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
