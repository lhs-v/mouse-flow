package com.example.logiswitch

import android.content.Context
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 백그라운드 서비스가 남기는 로그.
 * 자동 전환은 화면을 안 보는 상태에서 일어나므로, 나중에 확인할 수 있어야 한다.
 */
object EventLog {

    private const val MAX_BYTES = 64 * 1024
    private val fmt = SimpleDateFormat("MM-dd HH:mm:ss", Locale.US)

    private fun file(ctx: Context) = File(ctx.filesDir, "events.log")

    @Synchronized
    fun add(ctx: Context, line: String) {
        try {
            val f = file(ctx)
            if (f.exists() && f.length() > MAX_BYTES) {
                val keep = f.readText().takeLast(MAX_BYTES / 2)
                f.writeText(keep)
            }
            f.appendText("${fmt.format(Date())}  $line\n")
        } catch (_: Exception) { }
    }

    @Synchronized
    fun read(ctx: Context): String =
        try { file(ctx).takeIf { it.exists() }?.readText() ?: "(기록 없음)" }
        catch (e: Exception) { "(읽기 실패: ${e.message})" }

    @Synchronized
    fun clear(ctx: Context) {
        try { file(ctx).delete() } catch (_: Exception) { }
    }
}
