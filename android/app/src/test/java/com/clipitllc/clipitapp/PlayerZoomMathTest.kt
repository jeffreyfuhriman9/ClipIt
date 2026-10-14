package com.clipitllc.clipitapp

import com.clipitllc.clipitapp.ui.PlayerZoomMath
import org.junit.Assert.assertEquals
import org.junit.Test

class PlayerZoomMathTest {
    @Test fun doubleTapKeepsTappedPointUnderFingerAndClampsToVideo() {
        val target = PlayerZoomMath.doubleTap(PlayerZoomMath.Point(40f, -20f))
        assertEquals(3.5f, target.scale, 0.001f)
        assertEquals(-100f, target.translation.x, 0.001f)
        assertEquals(50f, target.translation.y, 0.001f)

        // A portrait video in a tall viewport has no horizontal pan room at 1x.
        val bounded = PlayerZoomMath.clamp(target, 400f, 800f, 9f / 16f)
        assertEquals(-100f, bounded.translation.x, 0.001f)
        assertEquals(50f, bounded.translation.y, 0.001f)
    }

    @Test fun pinchFocusTracksTheSameContentPoint() {
        val start = PlayerZoomMath.Frame(2f, PlayerZoomMath.Point(20f, -10f))
        val frame = PlayerZoomMath.focusedPinch(start,
            PlayerZoomMath.Point(40f, 30f), PlayerZoomMath.Point(50f, 20f), 3f)
        assertEquals(3f, frame.scale, 0.001f)
        assertEquals(20f, frame.translation.x, 0.001f)
        assertEquals(-40f, frame.translation.y, 0.001f)
    }

    @Test fun pinchRubberBandsThenSnapsAtGestureEnd() {
        assertEquals(0.82f, PlayerZoomMath.rubberBandedScale(0f), 0.001f)
        assertEquals(5.35f, PlayerZoomMath.rubberBandedScale(10f), 0.001f)
        assertEquals(4f, PlayerZoomMath.rubberBandedScale(4f), 0.001f)
    }
}
