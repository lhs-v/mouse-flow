package com.example.logiswitch

import android.content.Context

/** 앱 안에서 직접 입력하는 설정값들. 회사에서 실물 확인 후 채우면 된다. */
class Prefs(ctx: Context) {

    private val sp = ctx.getSharedPreferences("logiswitch", Context.MODE_PRIVATE)

    /** 감시할 키보드(독거미)의 MAC. 이 기기가 끊기면 마우스를 밀어낸다. */
    var keyboardMac: String
        get() = sp.getString("kbMac", "") ?: ""
        set(v) = sp.edit().putString("kbMac", v).apply()

    /** 전환 대상 마우스(MX Vertical)의 MAC. */
    var mouseMac: String
        get() = sp.getString("mouseMac", "") ?: ""
        set(v) = sp.edit().putString("mouseMac", v).apply()

    /** 로지텍 독자 GATT 서비스 UUID. 기본값이 안 맞으면 탐색 결과로 바꾼다. */
    var serviceUuid: String
        get() = sp.getString("svc", Hidpp.VENDOR_SERVICE) ?: Hidpp.VENDOR_SERVICE
        set(v) = sp.edit().putString("svc", v).apply()

    /** HID++ 를 써 넣을 특성 UUID. 탐색 후 목록에서 고른다. */
    var writeCharUuid: String
        get() = sp.getString("wchar", "") ?: ""
        set(v) = sp.edit().putString("wchar", v).apply()

    /** 응답을 받을 알림 특성 UUID. 비워두면 응답 없이 전송만 한다. */
    var notifyCharUuid: String
        get() = sp.getString("nchar", "") ?: ""
        set(v) = sp.edit().putString("nchar", v).apply()

    /** 페이로드 첫 바이트로 리포트 ID(0x11)를 포함할지. 둘 다 시도해 볼 것. */
    var includeReportId: Boolean
        get() = sp.getBoolean("rptId", true)
        set(v) = sp.edit().putBoolean("rptId", v).apply()

    /** 0x1814 의 feature index. 0 이면 실행 시 자동 조회 후 캐시된다. */
    var featureIndex: Int
        get() = sp.getInt("feat", 0)
        set(v) = sp.edit().putInt("feat", v).apply()

    /** 마우스를 보낼 대상 호스트 (0-based). PC 가 채널1이면 0. */
    var targetHost: Int
        get() = sp.getInt("host", 0)
        set(v) = sp.edit().putInt("host", v).apply()

    /** 자동 전환 사용 여부. */
    var autoEnabled: Boolean
        get() = sp.getBoolean("auto", false)
        set(v) = sp.edit().putBoolean("auto", v).apply()

    /**
     * 화면이 꺼져 있으면 무시.
     * PC 로 돌아갈 때는 폰 화면이 꺼져 있는 게 정상이므로 기본값은 false 다.
     * 주머니 속 오발이 잦으면 켠다.
     */
    var onlyWhenScreenOn: Boolean
        get() = sp.getBoolean("screenOn", false)
        set(v) = sp.edit().putBoolean("screenOn", v).apply()

    /** 이 시간 안에 다시 트리거되면 무시 (ms). */
    var debounceMs: Int
        get() = sp.getInt("debounce", 5000)
        set(v) = sp.edit().putInt("debounce", v).apply()
}
