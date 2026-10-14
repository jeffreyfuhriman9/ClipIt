package com.clipitllc.clipitapp.ui

import kotlin.math.max
import kotlin.math.min

/** Geometry shared by the clip player's pinch and double-tap gestures. */
internal object PlayerZoomMath {
    const val maxScale = 5f
    const val doubleTapScale = 3.5f

    data class Point(val x: Float, val y: Float)
    data class Frame(val scale: Float, val translation: Point)

    fun rubberBandedScale(raw: Float): Float = when {
        raw < 1f -> max(0.82f, 1f - (1f - raw) * 0.32f)
        raw > maxScale -> min(maxScale + 0.35f, maxScale + (raw - maxScale) * 0.18f)
        else -> raw
    }

    fun focusedPinch(start: Frame, startFocus: Point, currentFocus: Point, rawScale: Float): Frame {
        val scale = rubberBandedScale(rawScale)
        val contentX = (startFocus.x - start.translation.x) / start.scale
        val contentY = (startFocus.y - start.translation.y) / start.scale
        return Frame(scale, Point(currentFocus.x - contentX * scale, currentFocus.y - contentY * scale))
    }

    fun doubleTap(focus: Point): Frame = Frame(
        doubleTapScale,
        Point(focus.x * (1f - doubleTapScale), focus.y * (1f - doubleTapScale))
    )

    fun clamp(frame: Frame, viewportWidth: Float, viewportHeight: Float, videoAspect: Float): Frame {
        if (viewportWidth <= 0f || viewportHeight <= 0f || !frame.scale.isFinite()) return Frame(1f, Point(0f, 0f))
        val aspect = videoAspect.takeIf { it.isFinite() && it > 0f } ?: viewportWidth / viewportHeight
        val baseWidth = min(viewportWidth, viewportHeight * aspect)
        val baseHeight = min(viewportHeight, viewportWidth / aspect)
        val limitX = max(0f, (baseWidth * frame.scale - viewportWidth) / 2f)
        val limitY = max(0f, (baseHeight * frame.scale - viewportHeight) / 2f)
        return Frame(frame.scale, Point(
            (frame.translation.x.takeIf { it.isFinite() } ?: 0f).coerceIn(-limitX, limitX),
            (frame.translation.y.takeIf { it.isFinite() } ?: 0f).coerceIn(-limitY, limitY)
        ))
    }

}
