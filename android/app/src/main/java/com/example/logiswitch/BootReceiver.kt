package com.example.logiswitch

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 재부팅 후 감시를 다시 시작한다.
 *
 * 이게 없으면 폰을 껐다 켤 때마다 앱을 한 번 열어야 감시가 살아난다.
 *
 * 주의: Android 14 부터 백그라운드에서 포그라운드 서비스를 띄우는 데 제약이 있다.
 * 부팅 시점에는 예외가 적용되지만 기기에 따라 거부될 수 있어, 실패해도 앱이
 * 죽지 않도록 감싸고 사유를 기록에 남긴다.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(ctx: Context, intent: Intent) {
        val act = intent.action ?: return
        if (act != Intent.ACTION_BOOT_COMPLETED &&
            act != Intent.ACTION_LOCKED_BOOT_COMPLETED &&
            act != "android.intent.action.QUICKBOOT_POWERON") return

        val p = Prefs(ctx)
        if (!p.autoEnabled) {
            EventLog.add(ctx, "부팅 감지 — 자동 전환이 꺼져 있어 시작하지 않음")
            return
        }
        if (p.keyboardMac.isBlank() || p.mouseMac.isBlank()) {
            EventLog.add(ctx, "부팅 감지 — 기기 설정이 없어 시작하지 않음")
            return
        }

        try {
            ctx.startForegroundService(Intent(ctx, AutoSwitchService::class.java))
            EventLog.add(ctx, "부팅 감지 — 감시 서비스를 자동으로 시작했습니다")
        } catch (e: Exception) {
            EventLog.add(ctx, "부팅 후 자동 시작 실패: ${e.javaClass.simpleName} — 앱을 한 번 열어주세요")
        }
    }
}
