package com.clipitllc.clipitapp.ble

import java.util.Base64
import java.util.Locale

data class ReliableButtonCommand(
    val bootToken: String,
    val sequence: String,
    val kind: Char,
    val key: String,
    val pressedAtMs: Long? = null
)

/** The UART characteristic is a byte stream, not a packet boundary. */
internal class ButtonLineFramer {
    private val buffer = StringBuilder()
    private var discarding = false

    fun reset() {
        buffer.clear()
        discarding = false
    }

    fun feed(bytes: ByteArray): List<String> {
        val lines = mutableListOf<String>()
        for (byte in bytes) {
            when (byte.toInt() and 0xff) {
                10 -> {
                    if (!discarding && buffer.isNotEmpty()) lines.add(buffer.toString().trimEnd('\r'))
                    reset()
                }
                13 -> Unit
                else -> if (!discarding) {
                    if (buffer.length < 128) buffer.append((byte.toInt() and 0xff).toChar())
                    else {
                        buffer.clear()
                        discarding = true
                    }
                }
            }
        }
        return lines
    }
}

internal object ButtonProtocol {
    private val hex8 = Regex("[0-9A-Fa-f]{8}")
    private val hex4 = Regex("[0-9A-Fa-f]{4}")

    fun parseReliable(message: String, buttonId: String, receivedAtMs: Long): ReliableButtonCommand? {
        if (message.startsWith('Q')) {
            if (message.length != 17 || !message.endsWith("==")) return null
            val bytes = try { Base64.getDecoder().decode(message.substring(1)) }
                catch (_: IllegalArgumentException) { return null }
            if (bytes.size != 10) return null
            val boot = ((bytes[0].toLong() and 0xff) shl 24) or
                ((bytes[1].toLong() and 0xff) shl 16) or
                ((bytes[2].toLong() and 0xff) shl 8) or (bytes[3].toLong() and 0xff)
            val sequence = ((bytes[4].toInt() and 0xff) shl 8) or (bytes[5].toInt() and 0xff)
            val age = ((bytes[6].toLong() and 0xff) shl 24) or
                ((bytes[7].toLong() and 0xff) shl 16) or
                ((bytes[8].toLong() and 0xff) shl 8) or (bytes[9].toLong() and 0xff)
            val token = String.format(Locale.US, "%08X", boot)
            val number = String.format(Locale.US, "%04X", sequence)
            return ReliableButtonCommand(token, number, 'C', "$buttonId:$token:$number", receivedAtMs - age)
        }
        val parts = message.split(' ')
        if (parts.size != 4 || parts[0] != "CMD" || !hex8.matches(parts[1]) ||
            !hex4.matches(parts[2]) || parts[3] !in listOf("C", "S", "T")) return null
        val token = parts[1].uppercase(Locale.US)
        val number = parts[2].uppercase(Locale.US)
        return ReliableButtonCommand(token, number, parts[3][0], "$buttonId:$token:$number")
    }

    fun pending(message: String): Int? {
        if (!message.startsWith("PENDING ")) return null
        return message.removePrefix("PENDING ").toIntOrNull()?.takeIf { it in 0..64 }
    }

    fun recordingStateCommand(isRecording: Boolean): String =
        "RECORDING_STATE ${if (isRecording) 1 else 0}"
}
