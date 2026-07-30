import Foundation
import CoreBluetooth
import Combine

// Nordic UART Service (matches Bluefruit BLEUart on your XIAO)
private let kServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let kRXCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
private let kTXCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

enum BLEState {
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
}

final class BLEViewModel: NSObject, ObservableObject {

    @Published var bleState: BLEState = .disconnected
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var autoReconnect: Bool = true
    @Published var hapticOnClip: Bool = true
    @Published var lastMessage: String = ""
    
    // 🔋 NEW: Expose the parsed hardware battery level up to SwiftUI views
    @Published var remoteBatteryLevel: Int? = nil

    let clipTrigger = PassthroughSubject<Void, Never>()
    let toggleRecordTrigger = PassthroughSubject<Void, Never>()

    private var centralManager: CBCentralManager?
    private var connectedPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?

    private var hasAutoConnected = false
    private var incomingBuffer = ""

    override init() {
        super.init()
    }

    func startScanning() {
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
            return  // centralManagerDidUpdateState will fire and call startScanning() again once powered on
        }
        guard centralManager?.state == .poweredOn else { return }
        guard connectedPeripheral == nil else { return }
        guard !bleState.isConnected else { return }

        discoveredDevices.removeAll()
        bleState = .scanning
        hasAutoConnected = false

        centralManager?.scanForPeripherals(
            withServices: [kServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager?.stopScan()
    }

    func connect(to device: DiscoveredDevice) {
        stopScanning()
        bleState = .connecting
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
        centralManager?.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        centralManager?.cancelPeripheralConnection(peripheral)
    }

    // 🛠 UNIFIED PROCESSING ENGINE: Everything funnels cleanly through here safely on MainActor
    @MainActor
    private func handleIncomingMessage(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        lastMessage = message
        print("BLE received: \(message)")

        if message == "TOGGLE_RECORD" {
            toggleRecordTrigger.send()
            return
        }

        if message.hasPrefix("CLIP") {
            if hapticOnClip {
                // Ensure your Haptics helper exists or remove this conditional safe call block
                // Haptics.clipRegistered()
            }
            clipTrigger.send()
            return
        }
        
        // 🔋 NEW: Intercept and process the custom battery data payload string ("BATT 87")
        if message.hasPrefix("BATT") {
            let components = message.components(separatedBy: " ")
            if components.count == 2, let parsedBattery = Int(components[1]) {
                self.remoteBatteryLevel = parsedBattery
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
                if self.autoReconnect {
                    self.startScanning()
                }

            case .poweredOff:
                self.bleState = .poweredOff
                self.discoveredDevices.removeAll()
                self.remoteBatteryLevel = nil // Clear state on power down

            default:
                if !(self.connectedPeripheral != nil || self.bleState.isConnected) {
                    self.bleState = .disconnected
                }
                self.discoveredDevices.removeAll()
                self.remoteBatteryLevel = nil
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? "Unknown Device"

        let device = DiscoveredDevice(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            peripheral: peripheral
        )

        DispatchQueue.main.async {
            if !self.discoveredDevices.contains(where: { $0.id == device.id }) {
                self.discoveredDevices.append(device)
            }

            if self.autoReconnect && !self.hasAutoConnected {
                let lowered = name.lowercased()
                if lowered.contains("clipit") {
                    self.hasAutoConnected = true
                    self.connect(to: device)
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            self.bleState = .connected(peripheralName: peripheral.name ?? "ClipIt Button")
        }

        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        DispatchQueue.main.async {
            self.bleState = .disconnected
            self.connectedPeripheral = nil
            self.txCharacteristic = nil
            self.rxCharacteristic = nil
            self.incomingBuffer = ""
            self.remoteBatteryLevel = nil

            if self.autoReconnect {
                self.startScanning()
                }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        DispatchQueue.main.async {
            self.bleState = .disconnected
            self.connectedPeripheral = nil
            self.txCharacteristic = nil
            self.rxCharacteristic = nil
            self.lastMessage = ""
            self.incomingBuffer = ""
            self.remoteBatteryLevel = nil // Disconnect clears battery icon presentation

            if self.autoReconnect {
                self.startScanning()
            }
        }
    }
}

extension BLEViewModel: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else { return }

        for service in services where service.uuid == kServiceUUID {
            peripheral.discoverCharacteristics([kTXCharUUID, kRXCharUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil, let chars = service.characteristics else { return }

        for char in chars {
            if char.uuid == kTXCharUUID {
                txCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == kRXCharUUID {
                rxCharacteristic = char
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil else { return }
        guard characteristic.uuid == kTXCharUUID else { return }
        guard let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }

        // Forward all raw packets through the unified parsing engine on the main thread
        DispatchQueue.main.async {
            self.handleIncomingMessage(text)
        }
    }
}
