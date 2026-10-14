package com.clipitllc.clipitapp.ble

internal object ButtonConnectionPolicy {
    private const val DEFAULT_NAME = "ClipIt Button"
    private const val CUSTOM_NAME_PREFIX = "Clip: "
    const val MAX_FRIENDLY_NAME_LENGTH = 23

    fun isClipItButton(name: String): Boolean {
        val trimmed = name.trim()
        if (trimmed.equals(DEFAULT_NAME, ignoreCase = true)) return true
        if (!trimmed.startsWith(CUSTOM_NAME_PREFIX)) return false
        return isValidFriendlyName(trimmed.removePrefix(CUSTOM_NAME_PREFIX))
    }

    fun displayName(advertisedName: String): String {
        val trimmed = advertisedName.trim()
        return if (trimmed.startsWith(CUSTOM_NAME_PREFIX)) {
            trimmed.removePrefix(CUSTOM_NAME_PREFIX)
        } else DEFAULT_NAME
    }

    fun isValidFriendlyName(name: String): Boolean =
        name.isNotEmpty() && name.length <= MAX_FRIENDLY_NAME_LENGTH && name.all(::isAllowedNameCharacter)

    fun filterFriendlyName(name: String): String = name
        .filter(::isAllowedNameCharacter)
        .take(MAX_FRIENDLY_NAME_LENGTH)

    private fun isAllowedNameCharacter(character: Char): Boolean =
        character in 'A'..'Z' || character in 'a'..'z' || character in '0'..'9' ||
            character == ' ' || character == '-' || character == '\'' || character == '_'

    fun shouldAutoConnect(
        foundId: String,
        preferredId: String?,
        manuallyDisconnectedId: String?,
        autoReconnect: Boolean,
        rejectedIds: Set<String>
    ): Boolean = autoReconnect && preferredId != null && foundId == preferredId &&
        foundId != manuallyDisconnectedId && foundId !in rejectedIds
}
