import Foundation
import CoreBluetooth
import Combine

// Nordic UART Service (matches Bluefruit BLEUart on your XIAO)
private let kServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let kRXCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
private let kTXCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
private let kDeviceInfoServiceUUID = CBUUID(string: "180A")
private let kManufacturerCharUUID = CBUUID(string: "2A29")
private let kBatteryServiceUUID = CBUUID(string: "180F")
private let kBatteryLevelCharUUID = CBUUID(string: "2A19")
private let kClipItName = "ClipIt Button"
private let kCustomClipItNamePrefix = "Clip: "
private let kClipItManufacturer = "ClipIt"
private let kPreferredButtonKey = "preferredClipItPeripheralID"
private let kAutoReconnectKey = "clipItAutoReconnect"
private let kManuallyDisconnectedButtonsKey = "manuallyDisconnectedClipItPeripheralIDs"
private let kHandledCommandsKey = "handledClipItButtonCommandsV1"

struct ReliableButtonCommand {
    enum Kind: String { case clip = "C", start = "S", stop = "T" }
    let bootToken: String
    let sequence: String
    let kind: Kind
    let key: String
    // A timestamped clip is sent by current firmware; older buttons use CMD.
    let ageMilliseconds: UInt32?
}

enum BLEState: Equatable {
    case poweredOff
    case scanning
    case connecting
    case connected(peripheralName: String)
    case disconnected

    var label: String {
        switch self {
        case .poweredOff: return "Bluetooth off"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .connected(let name): return "Connected: \(name)"
        case .disconnected: return "Disconnected"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
    let lastSeen: Date
}

final class BLEViewModel: NSObject, ObservableObject {

    @Published var bleState: BLEState = .disconnected
    @Published var discoveredDevices: [DiscoveredDevice] = []
    // This is deliberately opt-in. A remembered button can be nearby at a
    // shared venue, where reconnecting to it without a deliberate choice
    // would be confusing.
    @Published private(set) var autoReconnect: Bool
    @Published var hapticOnClip: Bool = true
    @Published var lastMessage: String = ""
    @Published private(set) var commandError: String?
    @Published private(set) var lastClipTransferStatus: String?
    
    // 🔋 NEW: Expose the parsed hardware battery level up to SwiftUI views
    @Published var remoteBatteryLevel: Int? = nil
    @Published private(set) var pendingButtonClips: Int?
    @Published private(set) var remoteUSBConnected: Bool?
    @Published private(set) var remoteBatteryCharging: Bool?
    @Published private(set) var connectedButtonID: UUID?
    @Published private(set) var hasConnectedButtonThisLaunch = false

    let clipTrigger = PassthroughSubject<Void, Never>()
    let startRecordTrigger = PassthroughSubject<Void, Never>()
    let stopRecordTrigger = PassthroughSubject<Void, Never>()
    let toggleRecordTrigger = PassthroughSubject<Void, Never>()
    let remoteCommandReadyTrigger = PassthroughSubject<Void, Never>()
    let reliableCommandTrigger = PassthroughSubject<ReliableButtonCommand, Never>()

    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var manufacturerVerified = false
    private var notificationsReady = false
    private var connectionTimeout: DispatchWorkItem?
    private var manuallySelectedID: UUID?
    private var preferredPeripheralID: UUID? = UserDefaults.standard
        .string(forKey: kPreferredButtonKey)
        .flatMap(UUID.init(uuidString:))
    private var manuallyDisconnectedButtonIDs = Set(
        (UserDefaults.standard.stringArray(forKey: kManuallyDisconnectedButtonsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
    )
    private var rejectedPeripheralIDs = Set<UUID>()
    private var recordingReconnectPeripheralID: UUID?

    var isRecordingReconnectActive: Bool {
        recordingReconnectPeripheralID != nil
    }

    private var shouldRecoverConnection: Bool {
        autoReconnect || recordingReconnectPeripheralID != nil
    }

    private var hasAutoConnected = false
    private var scanRequestedWhileInitializing = false
    private var incomingBuffer = Data()
    private var discardIncomingUntilNewline = false
    private var handledCommands = UserDefaults.standard.dictionary(forKey: kHandledCommandsKey) as? [String: Bool] ?? [:]
    private var pendingCommandKeys = Set<String>()
    private var connectedButtonName = kClipItName
    private var discoveredDevicePruneTimer: Timer?
    private let discoveredDeviceExpiry: TimeInterval = 4

    var isWaitingForManualButtonSelection: Bool {
        preferredPeripheralID.map { manuallyDisconnectedButtonIDs.contains($0) } ?? false
    }

    override init() {
        autoReconnect = UserDefaults.standard.object(forKey: kAutoReconnectKey) as? Bool ?? false
        super.init()
    }

    deinit {
        discoveredDevicePruneTimer?.invalidate()
    }

    func setAutoReconnect(_ enabled: Bool) {
        autoReconnect = enabled
        UserDefaults.standard.set(enabled, forKey: kAutoReconnectKey)
        if !enabled, recordingReconnectPeripheralID == nil,
           connectedPeripheral == nil, !scanRequestedWhileInitializing {
            stopScanning()
            bleState = .disconnected
        }
    }

    func setRecordingInProgress(_ recording: Bool) {
        if recording {
            if recordingReconnectPeripheralID == nil, bleState.isConnected {
                recordingReconnectPeripheralID = connectedButtonID
            }
            return
        }

        let wasRecovering = recordingReconnectPeripheralID != nil
        recordingReconnectPeripheralID = nil
        guard !autoReconnect, wasRecovering else { return }

        if let peripheral = connectedPeripheral,
           !bleState.isConnected, manuallySelectedID == nil {
            centralManager?.cancelPeripheralConnection(peripheral)
            clearConnection()
            bleState = .disconnected
        } else if connectedPeripheral == nil {
            stopScanning()
            bleState = .disconnected
        }
    }

    func startScanning() {
        if centralManager == nil {
            scanRequestedWhileInitializing = true
            centralManager = CBCentralManager(delegate: self, queue: nil)
            return  // Continue the requested scan once Bluetooth reports its state.
        }
        guard centralManager?.state == .poweredOn else {
            scanRequestedWhileInitializing = true
            return
        }
        guard connectedPeripheral == nil else { return }
        guard !bleState.isConnected else { return }

        scanRequestedWhileInitializing = false
        discoveredDevices.removeAll()
        bleState = .scanning
        hasAutoConnected = false

        centralManager?.scanForPeripherals(
            withServices: [kServiceUUID],
            // The name can arrive in the scan response after the first packet.
            // Repeated callbacks let us recognize it without admitting unnamed boards.
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        startPruningStaleDiscoveredDevices()
    }

    func stopScanning() {
        scanRequestedWhileInitializing = false
        centralManager?.stopScan()
        stopPruningStaleDiscoveredDevices()
    }

    private func startPruningStaleDiscoveredDevices() {
        guard discoveredDevicePruneTimer == nil else { return }
        discoveredDevicePruneTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.removeStaleDiscoveredDevices()
        }
    }

    private func stopPruningStaleDiscoveredDevices() {
        discoveredDevicePruneTimer?.invalidate()
        discoveredDevicePruneTimer = nil
    }

    private func removeStaleDiscoveredDevices() {
        let expiryDate = Date().addingTimeInterval(-discoveredDeviceExpiry)
        discoveredDevices.removeAll { $0.lastSeen < expiryDate }
    }

    func connect(to device: DiscoveredDevice) {
        connect(to: device, manuallySelected: true)
    }

    private func connect(to device: DiscoveredDevice, manuallySelected: Bool) {
        guard centralManager?.state == .poweredOn,
              connectedPeripheral == nil,
              isRecognizedClipItName(device.name),
              discoveredDevices.contains(where: { $0.id == device.id }) else { return }

        if manuallySelected && manuallyDisconnectedButtonIDs.remove(device.id) != nil {
            saveManuallyDisconnectedButtons()
        }
        stopScanning()
        bleState = .connecting
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
        txCharacteristic = nil
        rxCharacteristic = nil
        manufacturerVerified = false
        notificationsReady = false
        remoteBatteryLevel = nil
        pendingButtonClips = nil
        remoteUSBConnected = nil
        remoteBatteryCharging = nil
        connectedButtonName = displayName(for: device.name)
        manuallySelectedID = manuallySelected ? device.id : nil
        scheduleConnectionTimeout(for: device.peripheral)
        centralManager?.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        let id = peripheral.identifier
        recordingReconnectPeripheralID = nil
        manuallyDisconnectedButtonIDs.insert(id)
        saveManuallyDisconnectedButtons()

        clearConnection()
        bleState = .disconnected
        lastMessage = ""
        centralManager?.cancelPeripheralConnection(peripheral)
        startScanning()
    }

    private func saveManuallyDisconnectedButtons() {
        UserDefaults.standard.set(
            manuallyDisconnectedButtonIDs.map(\.uuidString).sorted(),
            forKey: kManuallyDisconnectedButtonsKey
        )
    }

    var currentButtonName: String { connectedButtonName }

    func displayName(for advertisedName: String) -> String {
        if advertisedName.hasPrefix(kCustomClipItNamePrefix) {
            return String(advertisedName.dropFirst(kCustomClipItNamePrefix.count))
        }
        return advertisedName
    }

    func renameConnectedButton(to name: String) {
        let permittedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 -'_")
        let allowed = name.unicodeScalars.filter {
            permittedCharacters.contains($0)
        }
        let sanitized = String(String.UnicodeScalarView(allowed))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }
        let savedName = String(sanitized.prefix(23))
        guard sendRemoteCommand("SET_NAME \(savedName)") else {
            commandError = "Could not save the button name. Keep it connected and try again."
            return
        }
    }

    func resetConnectedButtonName() {
        guard sendRemoteCommand("RESET_NAME") else {
            commandError = "Could not reset the button name. Keep it connected and try again."
            return
        }
    }

    private func isRecognizedClipItName(_ name: String) -> Bool {
        name.caseInsensitiveCompare(kClipItName) == .orderedSame ||
            name.hasPrefix(kCustomClipItNamePrefix)
    }

    @discardableResult
    func sendRemoteCommand(_ command: String) -> Bool {
        guard bleState.isConnected,
              let peripheral = connectedPeripheral,
              peripheral.state == .connected,
              let characteristic = rxCharacteristic else {
            if command.hasPrefix("ACK ") {
                commandError = "Clip receipt could not be sent while the button was reconnecting. It will retry."
                print("[ClipIt BLE] ACK deferred: UART is not connected")
            }
            return false
        }

        let data = Data((command + "\n").utf8)
        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse : .withoutResponse
        guard data.count <= peripheral.maximumWriteValueLength(for: writeType) else {
            commandError = "Button message exceeds the BLE write limit."
            return false
        }
        peripheral.writeValue(data, for: characteristic, type: writeType)
        if command.hasPrefix("ACK ") { print("[ClipIt BLE] sent \(command)") }
        return true
    }

    func acknowledge(_ command: ReliableButtonCommand, accepted: Bool) {
        guard pendingCommandKeys.remove(command.key) != nil else { return }
        // Keep a bounded reconnect/relaunch deduplication history. This is not
        // an exactly-once transaction across an app crash during clip creation.
        handledCommands[command.key] = accepted
        if handledCommands.count > 256 {
            handledCommands.removeAll()
            handledCommands[command.key] = accepted
        }
        UserDefaults.standard.set(handledCommands, forKey: kHandledCommandsKey)
        let acknowledgmentQueued = sendAcknowledgment(command, accepted: accepted)
        if !accepted { commandError = "Button command could not be completed." }
        else if acknowledgmentQueued { commandError = nil }
    }

    func retryWhenRecordingIsReady(_ command: ReliableButtonCommand) {
        // Leave this command unacknowledged. The button will send the same
        // timestamp and sequence again; only a saved or impossible tap is ACKed.
        pendingCommandKeys.remove(command.key)
    }

    func reportCommandError(_ message: String) {
        commandError = message
    }

    /// User-facing button errors are presented by the app shell. Clearing the
    /// shared value lets the user acknowledge the message from any tab.
    func dismissCommandError() {
        commandError = nil
    }

    func reportClipTransferStatus(_ message: String) {
        lastClipTransferStatus = message
    }

    @discardableResult
    private func sendAcknowledgment(_ command: ReliableButtonCommand, accepted: Bool) -> Bool {
        sendRemoteCommand("ACK \(command.bootToken) \(command.sequence) \(accepted ? 1 : 0)")
    }

    private func scheduleConnectionTimeout(for peripheral: CBPeripheral) {
        connectionTimeout?.cancel()
        let id = peripheral.identifier
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectedPeripheral?.identifier == id,
                  !self.bleState.isConnected else { return }
            print("BLE connection timed out before ClipIt verification: \(id)")
            self.centralManager?.cancelPeripheralConnection(peripheral)
            self.clearConnection()
            self.bleState = .disconnected
            if self.shouldRecoverConnection { self.startScanning() }
        }
        connectionTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func clearConnection() {
        connectionTimeout?.cancel()
        connectionTimeout = nil
        connectedPeripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        manufacturerVerified = false
        notificationsReady = false
        manuallySelectedID = nil
        incomingBuffer.removeAll()
        discardIncomingUntilNewline = false
        pendingCommandKeys.removeAll()
        remoteBatteryLevel = nil
        pendingButtonClips = nil
        remoteUSBConnected = nil
        remoteBatteryCharging = nil
        batteryCharacteristic = nil
        connectedButtonID = nil
        connectedButtonName = kClipItName
    }

    private func reject(_ peripheral: CBPeripheral, reason: String) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        print("BLE rejected \(peripheral.identifier): \(reason)")
        rejectedPeripheralIDs.insert(peripheral.identifier)
        centralManager?.cancelPeripheralConnection(peripheral)
        clearConnection()
        bleState = .disconnected
        if shouldRecoverConnection { startScanning() }
    }

    private func finishConnectionIfReady(for peripheral: CBPeripheral) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              peripheral.state == .connected,
              manufacturerVerified, notificationsReady,
              txCharacteristic != nil, rxCharacteristic != nil,
              !bleState.isConnected else { return }

        connectionTimeout?.cancel()
        connectionTimeout = nil
        bleState = .connected(peripheralName: connectedButtonName)
        hasConnectedButtonThisLaunch = true
        lastClipTransferStatus = "Connected; waiting for clip data."
        connectedButtonID = peripheral.identifier
        if preferredPeripheralID == nil || manuallySelectedID == peripheral.identifier {
            preferredPeripheralID = peripheral.identifier
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: kPreferredButtonKey)
        }
        manuallySelectedID = nil
        print("BLE verified ClipIt Button: \(peripheral.identifier)")
        remoteCommandReadyTrigger.send()
        sendRemoteCommand("GET_BATTERY")
        sendRemoteCommand("GET_NAME")
    }

    // 🛠 UNIFIED PROCESSING ENGINE: Everything funnels cleanly through here safely on MainActor
    @MainActor
    private func handleIncomingMessage(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        lastMessage = message
        print("BLE received: \(message)")

        let parts = message.split(separator: " ").map(String.init)
        if parts.count == 2, parts[0] == "PENDING",
           let pending = Int(parts[1]), (0...64).contains(pending) {
            if pendingButtonClips != pending { pendingButtonClips = pending }
            return
        }
        if message.hasPrefix("NAME ") {
            let receivedName = String(message.dropFirst(5))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !receivedName.isEmpty else { return }
            connectedButtonName = receivedName
            if let id = connectedButtonID {
                bleState = .connected(peripheralName: receivedName)
                if let index = discoveredDevices.firstIndex(where: { $0.id == id }) {
                    let existing = discoveredDevices[index]
                    discoveredDevices[index] = DiscoveredDevice(
                        id: existing.id, name: kCustomClipItNamePrefix + receivedName,
                        rssi: existing.rssi, peripheral: existing.peripheral,
                        lastSeen: existing.lastSeen
                    )
                }
            }
            commandError = nil
            return
        }
        if message == "NAME_ERROR" {
            commandError = "The button could not save that name. Please try again."
            return
        }
        if message.first == "Q",
           let peripheralID = connectedButtonID,
           let payload = Data(base64Encoded: String(message.dropFirst())),
           payload.count == 10 {
            let bytes = [UInt8](payload)
            let boot = bytes[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let sequence = bytes[4..<6].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
            let age = bytes[6..<10].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let token = String(format: "%08X", boot)
            let number = String(format: "%04X", sequence)
            let key = "\(peripheralID.uuidString):\(token):\(number)"
            let command = ReliableButtonCommand(
                bootToken: token, sequence: number, kind: .clip,
                key: key, ageMilliseconds: age
            )
            if let result = handledCommands[key] {
                sendAcknowledgment(command, accepted: result)
            } else if pendingCommandKeys.insert(key).inserted {
                reliableCommandTrigger.send(command)
            }
            return
        }
        if message.first == "Q" {
            commandError = "The button sent a clip timestamp the app could not read."
            lastClipTransferStatus = "Received an unreadable clip timestamp."
            print("[ClipIt BLE] malformed clip packet: \(message)")
            return
        }
        if parts.count == 4, parts[0] == "CMD",
           parts[1].count == 8, parts[2].count == 4,
           UInt32(parts[1], radix: 16) != nil,
           UInt16(parts[2], radix: 16) != nil,
           let kind = ReliableButtonCommand.Kind(rawValue: parts[3]),
           let peripheralID = connectedButtonID {
            let key = "\(peripheralID.uuidString):\(parts[1]):\(parts[2])"
            let command = ReliableButtonCommand(
                bootToken: parts[1], sequence: parts[2], kind: kind,
                key: key, ageMilliseconds: nil
            )
            if let result = handledCommands[key] {
                sendAcknowledgment(command, accepted: result)
            } else if pendingCommandKeys.insert(key).inserted {
                reliableCommandTrigger.send(command)
            }
            return
        }

        if message == "START_RECORDING" {
            startRecordTrigger.send()
            return
        }

        if message == "STOP_RECORDING" {
            stopRecordTrigger.send()
            return
        }

        // Legacy XIAO firmware used a dedicated toggle-record button and
        // reported a single TOGGLE_RECORD command instead of start/stop pairs.
        if message == "TOGGLE_RECORD" || message == "TOGGLE_RECORDING" {
            toggleRecordTrigger.send()
            return
        }

        if message == "CLIP" || (message.hasPrefix("CLIP ") &&
            Int(message.dropFirst(5)) != nil) {
            if hapticOnClip {
                // Ensure your Haptics helper exists or remove this conditional safe call block
                // Haptics.clipRegistered()
            }
            clipTrigger.send()
            return
        }
        
        // 🔋 Intercept and process the battery payload (e.g. "BATT 87", "BATT87", "BATT 87%")
        if message.hasPrefix("BATTERY ") || message.hasPrefix("BATT") {
            let numeric = message.hasPrefix("BATTERY ")
                ? String(message.dropFirst(8)) : String(message.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            let digits = numeric.hasSuffix("%") ? String(numeric.dropLast()) : numeric
            if !digits.isEmpty, digits.allSatisfy(\.isNumber),
               let parsedBattery = Int(digits), (0...100).contains(parsedBattery) {
                self.remoteBatteryLevel = parsedBattery
            } else {
                print("BLE battery parse failed for message: \"\(message)\"")
            }
        }
        if parts.count == 3, parts[0] == "POWER",
           let usb = Int(parts[1]), let charging = Int(parts[2]),
           (0...1).contains(usb), (0...1).contains(charging) {
            remoteUSBConnected = usb == 1
            remoteBatteryCharging = charging == 1
        }
    }

    private func receiveUARTBytes(_ data: Data) {
        for byte in data {
            if discardIncomingUntilNewline {
                if byte == 10 { discardIncomingUntilNewline = false }
                continue
            }
            if byte == 10 {
                if let text = String(data: incomingBuffer, encoding: .utf8) {
                    handleIncomingMessage(text)
                }
                incomingBuffer.removeAll()
            } else if incomingBuffer.count < 128 {
                incomingBuffer.append(byte)
            } else {
                incomingBuffer.removeAll()
                discardIncomingUntilNewline = true
                commandError = "Malformed button message was discarded."
            }
        }
    }
}

extension BLEViewModel: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            switch central.state {
            case .poweredOn:
                if self.connectedPeripheral != nil || self.bleState.isConnected {
                    return
                }

                self.bleState = .disconnected
                if self.shouldRecoverConnection || self.scanRequestedWhileInitializing {
                    self.startScanning()
                }

            case .poweredOff:
                self.bleState = .poweredOff
                self.discoveredDevices.removeAll()
                self.clearConnection()

            default:
                self.bleState = .disconnected
                self.discoveredDevices.removeAll()
                self.clearConnection()
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = (advName ?? peripheral.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Nordic UART is shared by many development boards. ClipIt firmware
        // advertises either its original name or the persistent Clip: prefix.
        guard self.isRecognizedClipItName(name) else { return }

        let device = DiscoveredDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            peripheral: peripheral,
            lastSeen: Date()
        )

        DispatchQueue.main.async {
            if let existingIndex = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[existingIndex] = device
            } else {
                self.discoveredDevices.append(device)
            }

            let recordingRecovery = self.recordingReconnectPeripheralID == device.id
            let normalAutoReconnect = self.autoReconnect &&
                (self.preferredPeripheralID == nil || self.preferredPeripheralID == device.id)
            if !self.hasAutoConnected &&
                !self.manuallyDisconnectedButtonIDs.contains(device.id) &&
                !self.rejectedPeripheralIDs.contains(device.id) &&
                (recordingRecovery || normalAutoReconnect) {
                self.hasAutoConnected = true
                self.connect(to: device, manuallySelected: false)
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            guard self.connectedPeripheral?.identifier == peripheral.identifier else {
                central.cancelPeripheralConnection(peripheral)
                return
            }
            print("BLE link established; verifying ClipIt identity: \(peripheral.identifier)")
            peripheral.delegate = self
            peripheral.discoverServices([kServiceUUID, kDeviceInfoServiceUUID,
                                         kBatteryServiceUUID])
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        DispatchQueue.main.async {
            guard self.connectedPeripheral?.identifier == peripheral.identifier else { return }
            print("BLE connection failed \(peripheral.identifier): \(error?.localizedDescription ?? "unknown error")")
            self.bleState = .disconnected
            self.clearConnection()

            if self.shouldRecoverConnection {
                self.startScanning()
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        DispatchQueue.main.async {
            guard self.connectedPeripheral?.identifier == peripheral.identifier else { return }
            print("BLE disconnected \(peripheral.identifier): \(error?.localizedDescription ?? "no error")")
            self.bleState = .disconnected
            self.clearConnection()
            self.lastMessage = ""

            if self.shouldRecoverConnection {
                self.startScanning()
            }
        }
    }
}

extension BLEViewModel: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        guard error == nil, let services = peripheral.services,
              let uart = services.first(where: { $0.uuid == kServiceUUID }),
              let deviceInfo = services.first(where: { $0.uuid == kDeviceInfoServiceUUID }) else {
            reject(peripheral, reason: "required UART or device-information service missing")
            return
        }
        peripheral.discoverCharacteristics([kTXCharUUID, kRXCharUUID], for: uart)
        peripheral.discoverCharacteristics([kManufacturerCharUUID], for: deviceInfo)
        if let battery = services.first(where: { $0.uuid == kBatteryServiceUUID }) {
            peripheral.discoverCharacteristics([kBatteryLevelCharUUID], for: battery)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if service.uuid == kBatteryServiceUUID && error != nil { return }
        guard error == nil, let chars = service.characteristics else {
            reject(peripheral, reason: "characteristic discovery failed")
            return
        }

        if service.uuid == kBatteryServiceUUID {
            batteryCharacteristic = chars.first(where: { $0.uuid == kBatteryLevelCharUUID })
            if let batteryCharacteristic {
                peripheral.readValue(for: batteryCharacteristic)
                if batteryCharacteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: batteryCharacteristic)
                }
            }
        } else if service.uuid == kDeviceInfoServiceUUID {
            guard let manufacturer = chars.first(where: { $0.uuid == kManufacturerCharUUID }) else {
                reject(peripheral, reason: "manufacturer characteristic missing")
                return
            }
            peripheral.readValue(for: manufacturer)
        } else if service.uuid == kServiceUUID {
            txCharacteristic = chars.first(where: { $0.uuid == kTXCharUUID })
            rxCharacteristic = chars.first(where: { $0.uuid == kRXCharUUID })
            guard let txCharacteristic, rxCharacteristic != nil else {
                reject(peripheral, reason: "UART characteristics missing")
                return
            }
            peripheral.setNotifyValue(true, for: txCharacteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              characteristic.uuid == kTXCharUUID else { return }
        guard error == nil, characteristic.isNotifying else {
            reject(peripheral, reason: "UART notifications unavailable")
            return
        }
        notificationsReady = true
        finishConnectionIfReady(for: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if characteristic.uuid == kBatteryLevelCharUUID,
           error == nil, let level = characteristic.value?.first, level <= 100 {
            remoteBatteryLevel = Int(level)
            return
        }
        if characteristic.uuid == kManufacturerCharUUID {
            guard error == nil,
                  let data = characteristic.value,
                  let manufacturer = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
                  manufacturer.caseInsensitiveCompare(kClipItManufacturer) == .orderedSame else {
                reject(peripheral, reason: "manufacturer is not ClipIt")
                return
            }
            manufacturerVerified = true
            finishConnectionIfReady(for: peripheral)
            return
        }
        guard error == nil, characteristic.uuid == kTXCharUUID,
              manufacturerVerified, notificationsReady,
              let data = characteristic.value else { return }

        // Forward all raw packets through the unified parsing engine on the main thread
        DispatchQueue.main.async {
            self.receiveUARTBytes(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier,
              characteristic.uuid == kRXCharUUID else { return }
        if let error {
            commandError = "Could not deliver a button response: \(error.localizedDescription)"
        }
    }
}
