package com.clipitllc.clipitapp

import com.clipitllc.clipitapp.ble.ButtonConnectionPolicy
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ButtonConnectionPolicyTest {
    @Test fun onlyListsRecognizedClipItFirmwareNames() {
        assertTrue(ButtonConnectionPolicy.isClipItButton("ClipIt Button"))
        assertTrue(ButtonConnectionPolicy.isClipItButton(" clipit button "))
        assertTrue(ButtonConnectionPolicy.isClipItButton("Clip: Court 3 - Jeff's Button"))
        assertFalse(ButtonConnectionPolicy.isClipItButton("ClipIt Test Board"))
        assertFalse(ButtonConnectionPolicy.isClipItButton("Clip: "))
        assertFalse(ButtonConnectionPolicy.isClipItButton("Clip: Invalid!"))
        assertFalse(ButtonConnectionPolicy.isClipItButton("Nordic UART"))
    }

    @Test fun displaysOnlyTheFriendlyPortionAndEnforcesFirmwareNameRules() {
        assertEquals("Court 3 - Jeff's Button",
            ButtonConnectionPolicy.displayName("Clip: Court 3 - Jeff's Button"))
        assertEquals("ClipIt Button", ButtonConnectionPolicy.displayName("ClipIt Button"))
        assertTrue(ButtonConnectionPolicy.isValidFriendlyName("Court 3 - Jeff's Button"))
        assertFalse(ButtonConnectionPolicy.isValidFriendlyName("Court 3!"))
        assertFalse(ButtonConnectionPolicy.isValidFriendlyName("123456789012345678901234"))
        assertEquals("Court 3 Jeffs_Button",
            ButtonConnectionPolicy.filterFriendlyName("Court 3 Jeffs_Button!🙂"))
    }

    @Test fun firstButtonRequiresManualSelectionAndOnlyPreferredButtonReconnects() {
        assertFalse(ButtonConnectionPolicy.shouldAutoConnect("A", null, null, true, emptySet()))
        assertFalse(ButtonConnectionPolicy.shouldAutoConnect("B", "A", null, true, emptySet()))
        assertTrue(ButtonConnectionPolicy.shouldAutoConnect("A", "A", null, true, emptySet()))
    }

    @Test fun disconnectAndAutoReconnectSettingBlockAutomaticConnection() {
        assertFalse(ButtonConnectionPolicy.shouldAutoConnect("A", "A", "A", true, emptySet()))
        assertFalse(ButtonConnectionPolicy.shouldAutoConnect("A", "A", null, false, emptySet()))
        assertFalse(ButtonConnectionPolicy.shouldAutoConnect("A", "A", null, true, setOf("A")))
    }
}
