package com.example.logiswitch

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context

/**
 * 기기가 지금 이 폰에 붙어 있는지 확인한다.
 *
 * 폰이 알 수 있는 것은 "이 폰에 연결됐는가" 뿐이다. 연결돼 있지 않다면
 * 다른 채널(= PC)에 있거나 꺼진 것이고, 실제 사용에서는 PC 에 있다는 뜻이다.
 */
object BtState {

    @SuppressLint("MissingPermission")
    fun isOnThisPhone(ctx: Context, mac: String): Boolean? {
        if (mac.isBlank()) return null
        val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager ?: return null
        val adapter = mgr.adapter ?: return null
        if (!adapter.isEnabled) return false

        // 숨은 API 가 가장 정확했다. 막히면 공개 API 로 되돌아간다.
        try {
            val dev = adapter.getRemoteDevice(mac)
            val m = BluetoothDevice::class.java.getMethod("isConnected")
            (m.invoke(dev) as? Boolean)?.let { return it }
        } catch (_: Exception) { }

        return try {
            mgr.getConnectedDevices(BluetoothProfile.GATT)
                .any { it.address.equals(mac, ignoreCase = true) }
        } catch (_: Exception) { null }
    }

    @SuppressLint("MissingPermission")
    fun nameOf(ctx: Context, mac: String): String {
        if (mac.isBlank()) return "(선택 안 됨)"
        return try {
            val mgr = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            mgr?.adapter?.bondedDevices?.firstOrNull { it.address.equals(mac, true) }?.name ?: mac
        } catch (_: Exception) { mac }
    }

    /** 서비스가 실제로 돌고 있는지 */
    @Suppress("DEPRECATION")
    fun isServiceRunning(ctx: Context): Boolean = try {
        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
        am.getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == AutoSwitchService::class.java.name }
    } catch (_: Exception) { false }
}
