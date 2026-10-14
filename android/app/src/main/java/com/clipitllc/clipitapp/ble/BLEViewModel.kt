package com.clipitllc.clipitapp.ble

import android.Manifest
import android.app.Application
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.edit
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import java.util.UUID

// Nordic UART Service (matches Bluefruit BLEUart on your XIAO) — same hardware,
// same UUIDs as the iOS version.
private val SERVICE_UUID: UUID = UUID.fromString("6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private val RX_CHAR_UUID: UUID = UUID.fromString("6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
private val TX_CHAR_UUID: UUID = UUID.fromString("6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
private val DEVICE_INFO_UUID: UUID = UUID.fromString("0000180A-0000-1000-8000-00805F9B34FB")
private val MANUFACTURER_UUID: UUID = UUID.fromString("00002A29-0000-1000-8000-00805F9B34FB")
private const val CLIPIT_NAME = "ClipIt Button"
private const val CLIPIT_MANUFACTURER = "ClipIt"

// Client Characteristic Config descriptor. iOS's setNotifyValue(true, for:) writes this
// for you behind the scenes — on Android you have to write it yourself to actually
// start receiving notifications.
private val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

// Swift's `enum BLEState` with an associated value (`.connected(peripheralName:)`)
// becomes a sealed class in Kotlin — this is the same pattern mentioned earlier.
sealed class BLEState {
    object PoweredOff : BLEState()
    object Scanning : BLEState()
    object Connecting : BLEState()
    data class Connected(val peripheralName: String) : BLEState()
    object Disconnected : BLEState()

    val label: String
        get() = when (this) {
            is PoweredOff -> "Bluetooth off"
            is Scanning -> "Scanning..."
            is Connecting -> "Connecting..."
            is Connected -> "Connected: $peripheralName"
            is Disconnected -> "Disconnected"
        }

    val isConnected: Boolean
        get() = this is Connected
}

// Swift's `struct DiscoveredDevice: Identifiable` becomes a plain data class.
// BluetoothDevice.address (a MAC-derived string) stands in for CBPeripheral.identifier.
data class DiscoveredDevice(
    val id: String,
    val name: String,
    val rssi: Int,
    val device: BluetoothDevice
)

class BLEViewModel(application: Application) : AndroidViewModel(application) {

    private val connectionPreferences = application.getSharedPreferences("clipit_ble_connection", Context.MODE_PRIVATE)
    private val mainHandler = Handler(Looper.getMainLooper())
    private var preferredButtonId: String? = connectionPreferences.getString("preferred_button_id", null)
    private var manuallyDisconnectedButtonId: String? = connectionPreferences.getString("manually_disconnected_button_id", null)
    val isWaitingForManualButtonSelection: Boolean
        get() = manuallyDisconnectedButtonId != null && preferredButtonId == null
    val connectedDeviceId: String? get() = if (hasConnectPermission()) {
        try { connectedGatt?.device?.address } catch (_: SecurityException) { null }
    } else null
    fun displayNameFor(advertisedName: String): String = ButtonConnectionPolicy.displayName(advertisedName)

    // Compose's `mutableStateOf` + `by` is the closest match to Swift's `@Published` —
    // reading one of these inside a Composable automatically triggers recomposition
    // when it changes, the same way SwiftUI views redraw on `@Published` changes.
    var bleState by mutableStateOf<BLEState>(BLEState.Disconnected)
        private set
    var discoveredDevices by mutableStateOf<List<DiscoveredDevice>>(emptyList())
        private set
    // A versioned key deliberately ignores the former default-on preference. Every
    // installation must explicitly opt in after the shared-button warning was added.
    private var autoReconnectState by mutableStateOf(
        connectionPreferences.getBoolean("auto_reconnect_v13_opt_in", false)
    )
    var autoReconnect: Boolean
        get() = autoReconnectState
        set(value) {
            autoReconnectState = value
            connectionPreferences.edit { putBoolean("auto_reconnect_v13_opt_in", value) }
            if (value && connectedGatt == null) startScanning()
            else if (!value && connectedGatt == null) {
                stopScanning()
                bleState = BLEState.Disconnected
            }
        }
    var connectedButtonName by mutableStateOf(CLIPIT_NAME)
        private set
    var commandError by mutableStateOf<String?>(null)
        private set
    var hapticOnClip by mutableStateOf(true)
    var lastMessage by mutableStateOf("")
        private set

    // 🔋 Parsed hardware battery level, exposed up to Compose UI
    var remoteBatteryLevel by mutableStateOf<Int?>(null)
        private set
    var remoteUSBConnected by mutableStateOf<Boolean?>(null)
        private set
    var remoteBatteryCharging by mutableStateOf<Boolean?>(null)
        private set
    var pendingButtonClips by mutableStateOf<Int?>(null)
        private set
    var lastClipTransferStatus by mutableStateOf("Waiting for button clips.")
        private set
    fun reportClipTransferStatus(message: String) { lastClipTransferStatus = message }

    // Combine's PassthroughSubject → Kotlin's MutableSharedFlow. Collect these with
    // `.collect { }` inside a LaunchedEffect in whichever Composable listens for them.
    private val _clipTrigger = MutableSharedFlow<Unit>()
    val clipTrigger = _clipTrigger.asSharedFlow()

    private val _toggleRecordTrigger = MutableSharedFlow<Unit>()
    val toggleRecordTrigger = _toggleRecordTrigger.asSharedFlow()
    private val _startRecordTrigger = MutableSharedFlow<Unit>()
    val startRecordTrigger = _startRecordTrigger.asSharedFlow()
    private val _stopRecordTrigger = MutableSharedFlow<Unit>()
    val stopRecordTrigger = _stopRecordTrigger.asSharedFlow()
    private val _reliableCommandTrigger = MutableSharedFlow<ReliableButtonCommand>()
    val reliableCommandTrigger = _reliableCommandTrigger.asSharedFlow()
    private val _connectionReady = MutableSharedFlow<Unit>()
    val connectionReady = _connectionReady.asSharedFlow()
    private val handledCommands = application.getSharedPreferences("clipit_button_commands", Context.MODE_PRIVATE)
    private val lineFramer = ButtonLineFramer()
    private val pendingCommandKeys = mutableSetOf<String>()
    private data class QueuedCommand(val chunks: ArrayDeque<ByteArray>)
    private val writeQueue = ArrayDeque<QueuedCommand>()
    private var activeWrite: QueuedCommand? = null
    private var writeInFlight = false
    private var writeTypeInFlight = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
    private var writeTimeout: Runnable? = null

    private val appContext: Context get() = getApplication()
    private val bluetoothManager: BluetoothManager
        get() = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter?
        get() = bluetoothManager.adapter
    private var scanner: BluetoothLeScanner? = null

    private var connectedGatt: BluetoothGatt? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null
    private var rxCharacteristic: BluetoothGattCharacteristic? = null
    private var manufacturerVerified = false
    private var notificationsReady = false
    private var manuallySelectedId: String? = null
    private var rejectedDeviceIds = mutableSetOf<String>()
    private var scanRequestedWhileBluetoothOff = false
    private val connectionTimeout = Runnable {
        val gatt = connectedGatt ?: return@Runnable
        if (!bleState.isConnected) reject(gatt, invalidIdentity = false)
    }

    // Reacts to the user toggling Bluetooth on/off system-wide while the app is open —
    // the Android equivalent of CoreBluetooth's centralManagerDidUpdateState.
    private val bluetoothStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_ON -> {
                    if (connectedGatt == null && !bleState.isConnected) {
                        bleState = BLEState.Disconnected
                        if (autoReconnect || scanRequestedWhileBluetoothOff) startScanning()
                    }
                }
                BluetoothAdapter.STATE_OFF -> {
                    stopScanning()
                    clearConnection()
                    bleState = BLEState.PoweredOff
                    discoveredDevices = emptyList()
                }
            }
        }
    }

    init {
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Android 13+ requires an explicit exported/not-exported flag or this throws
            // SecurityException at runtime — there's no pre-33 equivalent to omit.
            appContext.registerReceiver(bluetoothStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            appContext.registerReceiver(bluetoothStateReceiver, filter)
        }
    }

    override fun onCleared() {
        appContext.unregisterReceiver(bluetoothStateReceiver)
        stopScanning()
        clearConnection()
    }

    private fun hasScanPermission(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) Manifest.permission.BLUETOOTH_SCAN
            else Manifest.permission.ACCESS_FINE_LOCATION
        return ContextCompat.checkSelfPermission(appContext, permission) == PackageManager.PERMISSION_GRANTED
    }

    fun startScanning() {
        if (!hasScanPermission()) return
        val adapter = bluetoothAdapter
        try {
            if (adapter == null || !adapter.isEnabled) {
                scanRequestedWhileBluetoothOff = true
                bleState = BLEState.PoweredOff
                return
            }
            if (connectedGatt != null || bleState.isConnected) return

            scanRequestedWhileBluetoothOff = false
            stopScanning()
            discoveredDevices = emptyList()
            bleState = BLEState.Scanning

            val filters = listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE_UUID)).build())
            val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()

            scanner = adapter.bluetoothLeScanner
            if (scanner == null) bleState = BLEState.Disconnected
            else scanner?.startScan(filters, settings, scanCallback)
        } catch (_: SecurityException) {
            bleState = BLEState.Disconnected
        }
    }

    fun stopScanning() {
        if (hasScanPermission()) {
            try { scanner?.stopScan(scanCallback) } catch (_: SecurityException) { }
        }
        scanner = null
    }

    private fun hasConnectPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return ContextCompat.checkSelfPermission(
            appContext, Manifest.permission.BLUETOOTH_CONNECT
        ) == PackageManager.PERMISSION_GRANTED
    }

    @Suppress("DEPRECATION") // Compatible BLE connection API for the app's Android 8 minimum.
    fun connect(to: DiscoveredDevice) {
        connect(to, manuallySelected = true)
    }

    @Suppress("DEPRECATION")
    private fun connect(to: DiscoveredDevice, manuallySelected: Boolean) {
        if (!hasConnectPermission()) {
            bleState = BLEState.Disconnected
            return
        }
        if (connectedGatt != null || !ButtonConnectionPolicy.isClipItButton(to.name) ||
            discoveredDevices.none { it.id == to.id }) return
        if (manuallySelected) {
            manuallyDisconnectedButtonId = null
            connectionPreferences.edit { remove("manually_disconnected_button_id") }
        }
        stopScanning()
        bleState = BLEState.Connecting
        manuallySelectedId = if (manuallySelected) to.id else null
        manufacturerVerified = false
        notificationsReady = false
        remoteBatteryLevel = null
        connectedButtonName = ButtonConnectionPolicy.displayName(to.name)
        commandError = null
        try {
            connectedGatt = to.device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            if (connectedGatt == null) {
                bleState = BLEState.Disconnected
                startScanning()
            } else mainHandler.postDelayed(connectionTimeout, 10_000)
        } catch (_: SecurityException) {
            bleState = BLEState.Disconnected
            manuallySelectedId = null
        }
    }

    fun disconnect() {
        val gatt = connectedGatt ?: return
        val id = connectedDeviceId
        manuallyDisconnectedButtonId = id
        preferredButtonId = null
        connectionPreferences.edit {
            remove("preferred_button_id")
            if (id != null) putString("manually_disconnected_button_id", id)
        }
        if (hasConnectPermission()) {
            try { gatt.disconnect() } catch (_: SecurityException) { }
        }
        clearConnection()
        bleState = BLEState.Disconnected
        lastMessage = ""
        startScanning()
    }

    private fun clearConnection() {
        mainHandler.removeCallbacks(connectionTimeout)
        val old = connectedGatt
        connectedGatt = null
        txCharacteristic = null
        rxCharacteristic = null
        manufacturerVerified = false
        notificationsReady = false
        manuallySelectedId = null
        remoteBatteryLevel = null
        remoteUSBConnected = null
        remoteBatteryCharging = null
        pendingButtonClips = null
        connectedButtonName = CLIPIT_NAME
        commandError = null
        pendingCommandKeys.clear()
        lineFramer.reset()
        writeQueue.clear()
        activeWrite = null
        writeInFlight = false
        writeTimeout?.let(mainHandler::removeCallbacks)
        writeTimeout = null
        if (old != null) try { old.close() } catch (_: SecurityException) { }
    }

    private fun reject(gatt: BluetoothGatt, invalidIdentity: Boolean = true) {
        if (connectedGatt !== gatt) return
        val id = try { gatt.device.address } catch (_: SecurityException) { null }
        if (invalidIdentity && id != null) rejectedDeviceIds.add(id)
        if (hasConnectPermission()) try { gatt.disconnect() } catch (_: SecurityException) { }
        clearConnection()
        bleState = BLEState.Disconnected
        if (autoReconnect) startScanning()
    }

    private fun finishConnectionIfReady(gatt: BluetoothGatt) {
        if (connectedGatt !== gatt || !manufacturerVerified || !notificationsReady ||
            rxCharacteristic == null || txCharacteristic == null || bleState.isConnected) return
        val id = try { gatt.device.address } catch (_: SecurityException) { return }
        mainHandler.removeCallbacks(connectionTimeout)
        bleState = BLEState.Connected(connectedButtonName)
        if (preferredButtonId == null || manuallySelectedId == id) {
            preferredButtonId = id
            connectionPreferences.edit { putString("preferred_button_id", id) }
        }
        manuallySelectedId = null
        sendRemoteCommand("GET_NAME")
        sendRemoteCommand("GET_BATTERY")
        viewModelScope.launch { _connectionReady.emit(Unit) }
    }

    fun renameConnectedButton(name: String) {
        val friendlyName = name.trim()
        if (!ButtonConnectionPolicy.isValidFriendlyName(friendlyName)) {
            commandError = "Use 1–23 letters, numbers, spaces, hyphens, apostrophes, or underscores."
            return
        }
        if (!sendRemoteCommand("SET_NAME $friendlyName")) {
            commandError = "Could not save the button name. Keep it connected and try again."
        }
    }

    fun resetConnectedButtonName() {
        if (!sendRemoteCommand("RESET_NAME")) {
            commandError = "Could not reset the button name. Keep it connected and try again."
        }
    }

    fun clearCommandError() { commandError = null }

    fun sendRemoteCommand(command: String): Boolean {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { sendRemoteCommand(command) }
            return true
        }
        if (!hasConnectPermission() || !bleState.isConnected) return false
        val bytes = (command + "\n").toByteArray(Charsets.UTF_8)
        // The longest SET_NAME command is larger than the default 20-byte ATT
        // payload. Nordic UART is a byte stream, so serialize it in safe chunks.
        // Keep every command's chunks together so a priority ACK cannot split a name.
        val queued = QueuedCommand(ArrayDeque(bytes.asList().chunked(20).map { it.toByteArray() }))
        if (command.startsWith("ACK ")) writeQueue.addFirst(queued) else writeQueue.addLast(queued)
        drainWrites()
        return true
    }

    private fun drainWrites() {
        if (writeInFlight || !hasConnectPermission() || !bleState.isConnected) return
        val gatt = connectedGatt ?: return
        val characteristic = rxCharacteristic ?: return
        val command = activeWrite ?: if (writeQueue.isNotEmpty()) writeQueue.removeFirst().also { activeWrite = it } else return
        val bytes = command.chunks.removeFirst()
        val writeType = if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0)
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        try {
            val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(characteristic, bytes, writeType) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.value = bytes
                characteristic.writeType = writeType
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
            if (!started) { reject(gatt, invalidIdentity = false); return }
            writeInFlight = true
            writeTypeInFlight = writeType
            val timeout = Runnable { if (connectedGatt === gatt && writeInFlight) reject(gatt, invalidIdentity = false) }
            writeTimeout = timeout
            mainHandler.postDelayed(timeout, 2_000)
            if (writeType == BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) {
                mainHandler.postDelayed({ if (connectedGatt === gatt && writeInFlight) finishWrite(gatt, BluetoothGatt.GATT_SUCCESS) }, 100)
            }
        } catch (_: SecurityException) {
            reject(gatt, invalidIdentity = false)
        }
    }

    private fun finishWrite(gatt: BluetoothGatt, status: Int) {
        if (connectedGatt !== gatt || !writeInFlight) return
        writeTimeout?.let(mainHandler::removeCallbacks)
        writeTimeout = null
        writeInFlight = false
        if (status != BluetoothGatt.GATT_SUCCESS) { reject(gatt, invalidIdentity = false); return }
        if (activeWrite?.chunks?.isEmpty() == true) activeWrite = null
        drainWrites()
    }

    fun acknowledge(command: ReliableButtonCommand, accepted: Boolean) {
        pendingCommandKeys.remove(command.key)
        handledCommands.edit(commit = true) { putBoolean(command.key, accepted) }
        sendRemoteCommand("ACK ${command.bootToken} ${command.sequence} ${if (accepted) 1 else 0}")
    }

    fun retryWhenRecordingIsReady(command: ReliableButtonCommand) {
        pendingCommandKeys.remove(command.key)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!hasConnectPermission()) return
            val device = result.device
            // The firmware's local name can arrive in a later scan response.
            val name = (result.scanRecord?.deviceName
                ?: try { device.name } catch (_: SecurityException) { null })?.trim() ?: return
            if (!ButtonConnectionPolicy.isClipItButton(name)) return
            val id = try { device.address } catch (_: SecurityException) { return }
            mainHandler.post {
                if (bleState !is BLEState.Scanning) return@post
                val discovered = DiscoveredDevice(id, name, result.rssi, device)
                val existingIndex = discoveredDevices.indexOfFirst { it.id == id }
                discoveredDevices = if (existingIndex < 0) discoveredDevices + discovered
                else discoveredDevices.toMutableList().also { it[existingIndex] = discovered }
                if (connectedGatt == null && ButtonConnectionPolicy.shouldAutoConnect(
                        id, preferredButtonId, manuallyDisconnectedButtonId, autoReconnect, rejectedDeviceIds)) {
                    connect(discovered, manuallySelected = false)
                }
            }
        }

        override fun onScanFailed(errorCode: Int) {
            mainHandler.post { bleState = BLEState.Disconnected }
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            mainHandler.post {
                if (connectedGatt !== gatt) {
                    try { gatt.close() } catch (_: SecurityException) { }
                    return@post
                }
                if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED &&
                    hasConnectPermission()) {
                    try { if (!gatt.discoverServices()) reject(gatt, invalidIdentity = false) }
                    catch (_: SecurityException) { reject(gatt, invalidIdentity = false) }
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                    clearConnection()
                    bleState = BLEState.Disconnected
                    lastMessage = ""
                    if (autoReconnect) startScanning()
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            mainHandler.post {
                if (connectedGatt !== gatt) return@post
                if (status != BluetoothGatt.GATT_SUCCESS || !hasConnectPermission()) {
                    reject(gatt, invalidIdentity = false)
                    return@post
                }
                val uart = gatt.getService(SERVICE_UUID)
                val info = gatt.getService(DEVICE_INFO_UUID)
                val tx = uart?.getCharacteristic(TX_CHAR_UUID)
                val rx = uart?.getCharacteristic(RX_CHAR_UUID)
                val manufacturer = info?.getCharacteristic(MANUFACTURER_UUID)
                if (tx == null || rx == null || manufacturer == null || tx.getDescriptor(CCCD_UUID) == null ||
                    tx.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY == 0 ||
                    rx.properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or
                        BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) == 0) {
                    reject(gatt)
                    return@post
                }
                txCharacteristic = tx
                rxCharacteristic = rx
                try { if (!gatt.readCharacteristic(manufacturer)) reject(gatt, invalidIdentity = false) }
                catch (_: SecurityException) { reject(gatt, invalidIdentity = false) }
            }
        }

        @Deprecated("Used for Android 12 and earlier")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            @Suppress("DEPRECATION") val value = characteristic.value ?: byteArrayOf()
            handleManufacturerRead(gatt, characteristic, value, status)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int
        ) {
            handleManufacturerRead(gatt, characteristic, value, status)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            mainHandler.post {
                if (connectedGatt !== gatt || descriptor.uuid != CCCD_UUID) return@post
                if (status != BluetoothGatt.GATT_SUCCESS) reject(gatt, invalidIdentity = false)
                else {
                    notificationsReady = true
                    finishConnectionIfReady(gatt)
                }
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            if (characteristic.uuid == RX_CHAR_UUID) mainHandler.post {
                if (writeTypeInFlight == BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) finishWrite(gatt, status)
            }
        }

        // API 33+ path: value is delivered directly instead of read back off the
        // characteristic, which avoids a race if it changes again before you read it.
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid != TX_CHAR_UUID) return
            val receivedAtMs = System.currentTimeMillis()
            mainHandler.post { if (connectedGatt === gatt && bleState.isConnected) receiveBytes(value, receivedAtMs) }
        }

        // Pre-33 path. On 33+ the overload above is called instead of this one, so the
        // early return here just prevents both from firing and double-handling a message.
        @Suppress("DEPRECATION")
        @Deprecated("Deprecated in Java, superseded by the value-param overload on API 33+")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            if (characteristic.uuid != TX_CHAR_UUID) return
            val text = characteristic.value?.toString(Charsets.UTF_8) ?: return
            val receivedAtMs = System.currentTimeMillis()
            mainHandler.post { if (connectedGatt === gatt && bleState.isConnected) receiveBytes(text.toByteArray(Charsets.UTF_8), receivedAtMs) }
        }
    }

    private fun handleManufacturerRead(
        gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int
    ) {
        if (characteristic.uuid != MANUFACTURER_UUID) return
        mainHandler.post {
            if (connectedGatt !== gatt) return@post
            val manufacturer = value.toString(Charsets.UTF_8).trim { it.isWhitespace() || it.isISOControl() }
            if (status != BluetoothGatt.GATT_SUCCESS || !manufacturer.equals(CLIPIT_MANUFACTURER, ignoreCase = true)) {
                reject(gatt)
                return@post
            }
            manufacturerVerified = true
            val tx = txCharacteristic ?: return@post
            val descriptor = tx.getDescriptor(CCCD_UUID) ?: run { reject(gatt); return@post }
            if (!hasConnectPermission()) { reject(gatt, invalidIdentity = false); return@post }
            try {
                if (!gatt.setCharacteristicNotification(tx, true)) { reject(gatt, invalidIdentity = false); return@post }
                val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION")
                    descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    @Suppress("DEPRECATION")
                    gatt.writeDescriptor(descriptor)
                }
                if (!started) reject(gatt, invalidIdentity = false)
            } catch (_: SecurityException) { reject(gatt, invalidIdentity = false) }
        }
    }

    private fun receiveBytes(bytes: ByteArray, receivedAtMs: Long) {
        lineFramer.feed(bytes).forEach { handleIncomingMessage(it, receivedAtMs) }
    }

    // 🛠 UNIFIED PROCESSING ENGINE: mirrors the Swift version's single entry point
    // that every incoming BLE packet funnels through.
    private fun handleIncomingMessage(text: String, receivedAtMs: Long) {
        val message = text.trim()
        if (message.isEmpty()) return

        lastMessage = message
        println("BLE received: $message")

        if (message.startsWith("NAME ")) {
            val receivedName = message.removePrefix("NAME ").trim()
            if (receivedName == CLIPIT_NAME || ButtonConnectionPolicy.isValidFriendlyName(receivedName)) {
                connectedButtonName = receivedName
                bleState = BLEState.Connected(receivedName)
                connectedDeviceId?.let { id ->
                    discoveredDevices = discoveredDevices.map { device ->
                        if (device.id != id) device else device.copy(
                            name = if (receivedName == CLIPIT_NAME) CLIPIT_NAME else "Clip: $receivedName"
                        )
                    }
                }
                commandError = null
            }
            return
        }
        if (message == "NAME_ERROR") {
            commandError = "The button could not save that name. Please try again."
            return
        }

        val pending = ButtonProtocol.pending(message)
        if (pending != null) { pendingButtonClips = pending; return }
        val buttonId = connectedDeviceId ?: return
        val command = ButtonProtocol.parseReliable(message, buttonId, receivedAtMs)
        if (command != null) {
            if (handledCommands.contains(command.key)) {
                if (command.pressedAtMs != null) lastClipTransferStatus =
                    if (handledCommands.getBoolean(command.key, false))
                        "Button tap ${command.sequence} was already registered."
                    else "Button tap ${command.sequence} could not be matched to recorded video."
                sendRemoteCommand("ACK ${command.bootToken} ${command.sequence} ${if (handledCommands.getBoolean(command.key, false)) 1 else 0}")
            } else if (pendingCommandKeys.add(command.key)) {
                if (command.pressedAtMs != null) lastClipTransferStatus = "Received button tap ${command.sequence}."
                viewModelScope.launch { _reliableCommandTrigger.emit(command) }
            }
            return
        }

        if (message.startsWith('Q')) {
            lastClipTransferStatus = "Received an unreadable clip timestamp."
            return
        }

        if (message == "START_RECORDING") { viewModelScope.launch { _startRecordTrigger.emit(Unit) }; return }
        if (message == "STOP_RECORDING") { viewModelScope.launch { _stopRecordTrigger.emit(Unit) }; return }

        if (message == "TOGGLE_RECORD" || message == "TOGGLE_RECORDING") {
            viewModelScope.launch { _toggleRecordTrigger.emit(Unit) }
            return
        }

        if (message.startsWith("CLIP")) {
            if (hapticOnClip) {
                // Wire up your haptics helper here, e.g. Haptics.clipRegistered()
            }
            viewModelScope.launch { _clipTrigger.emit(Unit) }
            return
        }

        // 🔋 Same forgiving parse we just added on the iOS side — strip everything
        // that isn't a digit rather than requiring an exact "BATT 87" format.
        val parts = message.split(' ')
        if (parts.size == 3 && parts[0] == "POWER" && parts[1] in listOf("0", "1") &&
            parts[2] in listOf("0", "1")) {
            remoteUSBConnected = parts[1] == "1"
            remoteBatteryCharging = parts[2] == "1"
            return
        }
        if (message.startsWith("BATT")) {
            val digits = message.removePrefix("BATTERY").removePrefix("BATT").filter { it.isDigit() }
            remoteBatteryLevel = digits.toIntOrNull()?.takeIf { it in 0..100 }
        }
    }
}
