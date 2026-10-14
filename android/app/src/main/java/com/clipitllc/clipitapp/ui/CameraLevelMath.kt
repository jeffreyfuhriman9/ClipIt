package com.clipitllc.clipitapp.ui

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.sin
import kotlin.math.cos

internal data class LevelReading(val visible: Boolean, val aligned: Boolean, val rollRadians: Double)

/** Mirrors the Core Motion gravity filtering and alignment thresholds in RecordView.swift. */
internal class CameraLevelFilter {
    private var filteredRoll: Double? = null
    private var aligned = false

    fun reset() {
        filteredRoll = null
        aligned = false
    }

    fun update(gravityX: Double, gravityY: Double, referenceAngle: Double): LevelReading {
        // Android gravity values are metres/second²; Core Motion reports unit gravity.
        if (hypot(gravityX, gravityY) / 9.80665 < 0.2) {
            reset()
            return LevelReading(false, false, 0.0)
        }
        val raw = wrapAngle(atan2(gravityX, -gravityY) - referenceAngle)
        val smooth = filteredRoll?.let {
            wrapAngle(it + 0.3 * wrapAngle(raw - it))
        } ?: raw
        filteredRoll = smooth
        if (abs(smooth) > PI / 9) {
            aligned = false
            return LevelReading(false, false, smooth)
        }
        val tolerance = if (aligned) PI / 72 else PI / 120
        aligned = abs(smooth) <= tolerance
        return LevelReading(true, aligned, smooth)
    }

    private fun wrapAngle(angle: Double) = atan2(sin(angle), cos(angle))

    companion object {
        fun referenceAngle(gravityX: Double, gravityY: Double, isLandscape: Boolean): Double =
            if (isLandscape) {
                if (gravityX >= 0) PI / 2 else -PI / 2
            } else {
                if (gravityY >= 0) PI else 0.0
            }
    }
}
