package com.clipitllc.clipitapp

import com.clipitllc.clipitapp.ui.CameraLevelFilter
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

class CameraLevelFilterTest {
    private fun readingAtDegrees(filter: CameraLevelFilter, degrees: Double) =
        filter.update(9.80665 * sin(degrees * PI / 180),
            -9.80665 * cos(degrees * PI / 180), 0.0)

    @Test fun alignedStateUsesEntryAndExitHysteresis() {
        val filter = CameraLevelFilter()
        assertTrue(readingAtDegrees(filter, 0.0).aligned)
        repeat(20) { assertTrue(readingAtDegrees(filter, 2.0).aligned) }
        repeat(20) { readingAtDegrees(filter, 4.0) }
        assertFalse(readingAtDegrees(filter, 4.0).aligned)
    }

    @Test fun hidesWhenTiltIsLargeOrDeviceIsFlat() {
        val filter = CameraLevelFilter()
        assertFalse(readingAtDegrees(filter, 25.0).visible)
        assertFalse(filter.update(0.0, 0.0, 0.0).visible)
    }

    @Test fun referenceFollowsPhysicalOrientationWithinTheCurrentLayout() {
        assertTrue(CameraLevelFilter.referenceAngle(0.0, -9.8, false) == 0.0)
        assertTrue(CameraLevelFilter.referenceAngle(0.0, 9.8, false) == PI)
        assertTrue(CameraLevelFilter.referenceAngle(-9.8, 0.0, true) == -PI / 2)
        assertTrue(CameraLevelFilter.referenceAngle(9.8, 0.0, true) == PI / 2)
    }
}
