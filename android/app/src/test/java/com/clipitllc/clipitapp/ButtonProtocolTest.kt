package com.clipitllc.clipitapp

import com.clipitllc.clipitapp.ble.ButtonLineFramer
import com.clipitllc.clipitapp.ble.ButtonProtocol
import com.clipitllc.clipitapp.ui.RecoveryTiming
import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ButtonProtocolTest {
    private fun q(boot: Long, sequence: Int, age: Long): String {
        val bytes = byteArrayOf(
            (boot ushr 24).toByte(), (boot ushr 16).toByte(), (boot ushr 8).toByte(), boot.toByte(),
            (sequence ushr 8).toByte(), sequence.toByte(),
            (age ushr 24).toByte(), (age ushr 16).toByte(), (age ushr 8).toByte(), age.toByte()
        )
        return "Q" + Base64.getEncoder().encodeToString(bytes)
    }

    @Test fun splitAndCombinedNotificationsProduceOnlyCompleteLines() {
        val framer = ButtonLineFramer()
        val first = q(0x89ABCDEF, 2, 12_345)
        assertEquals(emptyList<String>(), framer.feed(first.take(7).toByteArray()))
        assertEquals(listOf(first, "PENDING 4"), framer.feed((first.drop(7) + "\nPENDING 4\nCMD 89ABCDEF 0003 S").toByteArray()))
        assertEquals(listOf("CMD 89ABCDEF 0003 S"), framer.feed("\n".toByteArray()))
    }

    @Test fun malformedOverflowIsDiscardedUntilNextNewline() {
        val framer = ButtonLineFramer()
        assertEquals(emptyList<String>(), framer.feed("x".repeat(130).toByteArray()))
        assertEquals(listOf("PENDING 0"), framer.feed("Qbad\nPENDING 0\n".toByteArray()))
    }

    @Test fun replayUsesAgeAtReceiptButDeduplicatesByButtonBootAndSequence() {
        val first = ButtonProtocol.parseReliable(q(0x89ABCDEF, 0x42, 10_000), "button-A", 100_000)!!
        val retry = ButtonProtocol.parseReliable(q(0x89ABCDEF, 0x42, 20_000), "button-A", 110_000)!!
        assertEquals("89ABCDEF", first.bootToken)
        assertEquals("0042", first.sequence)
        assertEquals(90_000L, first.pressedAtMs)
        assertEquals(first.pressedAtMs, retry.pressedAtMs)
        assertEquals(first.key, retry.key)
        assertFalse(first.key == ButtonProtocol.parseReliable(q(0x89ABCDEF, 0x42, 20_000), "button-B", 110_000)!!.key)
        assertFalse(first.key == ButtonProtocol.parseReliable(q(0x89ABCDEE, 0x42, 20_000), "button-A", 110_000)!!.key)
    }

    @Test fun newerPacketMayArriveBeforeOlderTapAndTimesStayChronological() {
        val later = ButtonProtocol.parseReliable(q(0x12345678, 3, 2_000), "A", 102_000)!!
        val earlier = ButtonProtocol.parseReliable(q(0x12345678, 2, 8_000), "A", 103_000)!!
        assertTrue(earlier.pressedAtMs!! < later.pressedAtMs!!)
        assertTrue(RecoveryTiming.belongsToRecording(earlier.pressedAtMs, 90_000, 110_000))
        assertEquals(5_000L, RecoveryTiming.offsetMs(earlier.pressedAtMs, 90_000))
        assertFalse(RecoveryTiming.belongsToRecording(earlier.pressedAtMs, 100_000, 110_000))
    }

    @Test fun controlAndPendingFramesRequireExactShape() {
        val control = ButtonProtocol.parseReliable("CMD abcdef01 00af T", "A", 100_000)!!
        assertEquals('T', control.kind)
        assertEquals("ABCDEF01", control.bootToken)
        assertEquals("00AF", control.sequence)
        assertNull(control.pressedAtMs)
        assertNull(ButtonProtocol.parseReliable("CMD ABCDEF01 00AF C extra", "A", 100_000))
        assertNull(ButtonProtocol.parseReliable("Qbad", "A", 100_000))
        assertEquals(4, ButtonProtocol.pending("PENDING 4"))
        assertEquals(0, ButtonProtocol.pending("PENDING 0"))
        assertNull(ButtonProtocol.pending("PENDING 65"))
    }

    @Test fun reconnectReportsActualCameraStateIndependentlyOfPendingClipCount() {
        assertEquals("RECORDING_STATE 1", ButtonProtocol.recordingStateCommand(true))
        assertEquals("RECORDING_STATE 0", ButtonProtocol.recordingStateCommand(false))
        assertEquals(4, ButtonProtocol.pending("PENDING 4"))
    }
}
