package com.clipitllc.clipitapp.ui

internal object RecoveryTiming {
    fun belongsToRecording(pressedAtMs: Long, startedAtMs: Long, endedAtMs: Long): Boolean =
        pressedAtMs >= startedAtMs - 500 && pressedAtMs <= endedAtMs + 500

    fun offsetMs(pressedAtMs: Long, startedAtMs: Long): Long =
        (pressedAtMs - startedAtMs).coerceAtLeast(0)
}
