

#include <bluefruit.h>        // main Adafruit nRF52 Bluetooth library
#include <Adafruit_TinyUSB.h> // handles USB functionality
#include <Adafruit_FlashTransport.h> // Later uses flashtransport.runcommand(0xB9) 
// to send the JEDEC Deep Power‑Down command to the external QSPI flash. This places 
// the flash in a low‑current state (~1–5 µA), or deep sleep mode.
#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>
#include <string.h>           // Provides C string functions

using namespace Adafruit_LittleFS_Namespace;

Adafruit_FlashTransport_QSPI flashTransport;

const int buttonPin = D2;      // ClipIt button (Handling ClipIt moments and Toggle Recording)
const int powerSwitchPin = D4; // Slide switch input ON/OFF

// -------------------------
// Battery monitor
// -------------------------
#define PIN_VBAT        (32)
#define PIN_VBAT_ENABLE (14)
#define PIN_CHARGE_STATUS (23) // P0.17, active LOW while the charger is charging

unsigned long lastBatteryCheck = 0;
const unsigned long batteryInterval = 60000; // 60 sec
float batteryVoltage = 0;
int batteryPercentValue = 0;

// Battery percentage calibration.
// The nRF52840's nominal 3.6 V ADC reference is not exact. With the original
// calculation, a fully charged battery was being reported at about 93%, so
// the measured voltage needs a small correction. Adjust this value after
// comparing the Serial voltage to a multimeter measurement at the battery.
const float BATTERY_VOLTAGE_CALIBRATION = 1.015f;
const float BATTERY_EMPTY_VOLTAGE = 3.30f;
const float BATTERY_FULL_VOLTAGE = 4.20f;

BLEUart bleuart; // Nordic's UART Service using BLE like a wireless text channel
BLEDis bledis;   // Device Information Service
BLEBas blebas;   // Bluetooth Battery Service

// The friendly button name is stored in the nRF52840's internal flash so it
// survives power cycles and is visible to every phone that scans for it.
// "Clip: " plus a 23-character custom name fits the 29-byte BLE scan-response
// name limit exactly.
const char defaultButtonName[] = "ClipIt Button";
const char customNamePrefix[] = "Clip: ";
const char buttonNameFile[] = "/clipit_name.txt";
const uint8_t maxCustomButtonNameLength = 23;
char customButtonName[maxCustomButtonNameLength + 1] = { 0 };
char advertisedButtonName[30] = { 0 };
bool buttonNameStorageReady = false;
bool advertisingDataNeedsRefresh = false;

bool lastButtonReading = HIGH;            // raw signal bounce
bool buttonState = HIGH;                  // debounced, accepted button state
unsigned long lastButtonDebounceTime = 0; // Wait until reading is stable
unsigned long buttonPressedAt = 0;        // Save the time at accepted press
bool longPressHandled = false;            // Allows the long press and not triggering multiple commands

const unsigned long debounceDelay = 30;
const unsigned long longPressDuration = 2500;
uint32_t clipCount = 0;

// Clip taps are timestamped and retained in RAM through a BLE outage. Record
// controls use a separate lane so a delayed clip ACK cannot block a new hold.
struct PendingCommand { uint16_t sequence; char kind; uint32_t pressedAt; uint32_t lastSentAt; };
const uint8_t commandQueueCapacity = 64;
PendingCommand commandQueue[commandQueueCapacity];
uint8_t commandCount = 0;
uint8_t nextClipOffset = 0;
uint32_t lastClipPacketAt = 0;
bool clipPacketSent = false;
PendingCommand controlCommand;
bool controlPending = false;
uint16_t nextSequence = 1;
uint32_t bootToken = 0;
unsigned long lastControlAttempt = 0;
uint8_t controlAttempts = 0;
bool controlWasSent = false;
const unsigned long commandRetryMs = 650;
const uint8_t maxCommandAttempts = 8;
const unsigned long clipRetryMs = 1200;
const unsigned long clipPacketSpacingMs = 150;
const unsigned long queueStatusIntervalMs = 2000;
unsigned long lastQueueStatusAt = 0;
unsigned long failureLEDUntil = 0;

// Device/app state
bool isRecording = false;
volatile bool deviceAwake = true; 
volatile uint16_t activeConnHandle = 0xFFFF; // Tracks the active app connection handle (0xFFFF = None)

// Range-first BLE connection profile.
const uint16_t preferredConnectionIntervalMs = 30;
const uint16_t preferredSupervisionTimeoutMs = 6000;
bool phyUpdatePending = false;
unsigned long phyUpdateNotBefore = 0;
unsigned long lastAdvertisingRecovery = 0;

// Shared blink engine
bool blinkOn = false;
unsigned long lastBlinkTime = 0;
const unsigned long blinkInterval = 500;

// Short visual confirmation after a clip tap.
bool clipFeedbackActive = false;
unsigned long clipFeedbackStartedAt = 0;
const unsigned long clipFeedbackDuration = 180;

// Recording blink state is separate from connection/search blinking.
bool recordingBlinkOn = true;
unsigned long lastRecordingBlinkTime = 0;

// Prototypes for compilation safety
void enterLowPowerMode();
void wakeDevice();
void updateBatteryStatus();
void setLEDOff();
void showBaseLEDState();
void startAdv();
void handleButton();
void handleIncomingBLECommand();
void updateBaseBlink();
void switchISR();
void connect_callback(uint16_t conn_handle);
void disconnect_callback(uint16_t conn_handle, uint8_t reason);
void requestLongRangePHY(uint16_t conn_handle);
void serviceCommandQueue();
bool queueCommand(char kind);
void encodeClipPayload(const PendingCommand& command, uint32_t ageMs, char output[17]);
bool parseAcknowledgment(const char* message, uint32_t& token,
                         uint16_t& sequence, bool& accepted);
void loadPersistentButtonName();
bool savePersistentButtonName(const char* requestedName);
bool resetPersistentButtonName();
void applyButtonNameToBluetooth();
bool isValidButtonName(const char* name);
void sendCurrentButtonName();

// helper function for detecting if usb c is plugged in
bool usbPluggedIn() {
  return (NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk);
}

bool batteryIsCharging() {
  return usbPluggedIn() && digitalRead(PIN_CHARGE_STATUS) == LOW;
}

// --------------------------------------------------
// Persistent Bluetooth name
// --------------------------------------------------
bool isValidButtonName(const char* name) {
  size_t length = strlen(name);
  if (length == 0 || length > maxCustomButtonNameLength) return false;
  for (size_t i = 0; i < length; i++) {
    char c = name[i];
    bool allowed = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                   (c >= '0' && c <= '9') || c == ' ' || c == '-' ||
                   c == '\'' || c == '_';
    if (!allowed) return false;
  }
  return true;
}

void applyButtonNameToBluetooth() {
  if (customButtonName[0]) {
    snprintf(advertisedButtonName, sizeof(advertisedButtonName), "%s%s",
             customNamePrefix, customButtonName);
  } else {
    strncpy(advertisedButtonName, defaultButtonName,
            sizeof(advertisedButtonName) - 1);
    advertisedButtonName[sizeof(advertisedButtonName) - 1] = '\0';
  }
  Bluefruit.setName(advertisedButtonName);
  // Advertising data is a snapshot. Do not restart it while a phone is
  // connected; rebuild it immediately after that connection ends instead.
  advertisingDataNeedsRefresh = true;
}

void loadPersistentButtonName() {
  buttonNameStorageReady = InternalFS.begin();
  if (!buttonNameStorageReady) {
    Serial.println("Button-name storage unavailable; using default name");
    applyButtonNameToBluetooth();
    return;
  }

  File file(InternalFS);
  if (file.open(buttonNameFile, FILE_O_READ)) {
    size_t readLength = file.read(customButtonName,
                                  sizeof(customButtonName) - 1);
    file.close();
    customButtonName[readLength] = '\0';
    if (!isValidButtonName(customButtonName)) customButtonName[0] = '\0';
  }
  applyButtonNameToBluetooth();
}

bool savePersistentButtonName(const char* requestedName) {
  if (!buttonNameStorageReady || !isValidButtonName(requestedName)) return false;

  char previousName[sizeof(customButtonName)];
  strncpy(previousName, customButtonName, sizeof(previousName) - 1);
  previousName[sizeof(previousName) - 1] = '\0';
  strncpy(customButtonName, requestedName, sizeof(customButtonName) - 1);
  customButtonName[sizeof(customButtonName) - 1] = '\0';

  InternalFS.remove(buttonNameFile);
  File file(InternalFS);
  bool saved = file.open(buttonNameFile, FILE_O_WRITE);
  if (saved) {
    saved = file.write(customButtonName, strlen(customButtonName)) ==
            strlen(customButtonName);
    file.close();
  }
  if (!saved) {
    strncpy(customButtonName, previousName, sizeof(customButtonName) - 1);
    customButtonName[sizeof(customButtonName) - 1] = '\0';
    return false;
  }
  applyButtonNameToBluetooth();
  return true;
}

bool resetPersistentButtonName() {
  if (!buttonNameStorageReady) return false;
  if (InternalFS.exists(buttonNameFile) && !InternalFS.remove(buttonNameFile)) return false;
  customButtonName[0] = '\0';
  applyButtonNameToBluetooth();
  return true;
}

void sendCurrentButtonName() {
  bleuart.print("NAME ");
  bleuart.println(customButtonName[0] ? customButtonName : defaultButtonName);
}

// --------------------------------------------------
// Battery Functions
// --------------------------------------------------
float readBatteryVoltage() {
  float total = 0;
  for (int i = 0; i < 10; i++) {
    total += analogRead(PIN_VBAT);
    delay(5);
  }
  float raw = total / 10.0;
  float voltage = raw * 3.6f / 4095.0f * 2.961f;
  voltage *= BATTERY_VOLTAGE_CALIBRATION;
  return voltage;
}

int batteryPercent(float voltage) {
    voltage = constrain(voltage, BATTERY_EMPTY_VOLTAGE, BATTERY_FULL_VOLTAGE);
    float percent = ((voltage - BATTERY_EMPTY_VOLTAGE) /
                     (BATTERY_FULL_VOLTAGE - BATTERY_EMPTY_VOLTAGE)) * 100.0f;
    return constrain((int)roundf(percent), 0, 100);
}

void updateBatteryStatus() {
  // Seeed warns that disabling the divider while charging can leave P0.31
  // close to its input-voltage limit. Keep P0.14 LOW at all times instead.
  batteryVoltage = readBatteryVoltage();
  batteryPercentValue = batteryPercent(batteryVoltage);

  blebas.write(batteryPercentValue);

  Serial.print("Battery: ");
  Serial.print(batteryVoltage, 2);
  Serial.print("V  ");
  Serial.print(batteryPercentValue);
  Serial.println("%");

  if (Bluefruit.connected()) {
    char battMsg[32];
    snprintf(battMsg, sizeof(battMsg), "BATTERY %d%%", batteryPercentValue);
    bleuart.println(battMsg);
    snprintf(battMsg, sizeof(battMsg), "POWER %u %u",
             usbPluggedIn() ? 1 : 0, batteryIsCharging() ? 1 : 0);
    bleuart.println(battMsg);
  }
}

// --------------------------------------------------
// RGB LED helpers (Common-Anode logic: LOW turns ON)
// --------------------------------------------------
void setLEDOff() {
  digitalWrite(LED_RED, HIGH);
  digitalWrite(LED_GREEN, HIGH);
  digitalWrite(LED_BLUE, HIGH);
}

void setRed() {
  digitalWrite(LED_RED, LOW);
  digitalWrite(LED_GREEN, HIGH);
  digitalWrite(LED_BLUE, HIGH);
}

void setGreen() {
  digitalWrite(LED_RED, HIGH);
  digitalWrite(LED_GREEN, LOW);
  digitalWrite(LED_BLUE, HIGH);
}

void setBlue() {
  digitalWrite(LED_RED, HIGH);
  digitalWrite(LED_GREEN, HIGH);
  digitalWrite(LED_BLUE, LOW);
}

// --------------------------------------------------
// Base LED state machine
// --------------------------------------------------
void showBaseLEDState() {
  // --- PRIORITIES WHEN SWITCH IS OFF ---
  if (digitalRead(powerSwitchPin) == HIGH) {
    if (batteryIsCharging()) setRed();
    else setLEDOff();
    return;
  }

  // A lost BLE connection takes priority over recording state. The blue blink
  // tells the player the phone is currently out of range or disconnected.
  if (!Bluefruit.connected()) {
    if (blinkOn) setBlue();
    else setLEDOff();
    return;
  }

  if (millis() < failureLEDUntil) {
    setRed();
    return;
  }

  // Acknowledged taps briefly show green even during a recording. Otherwise
  // the recording blink would hide confirmation and never clear the timer.
  if (clipFeedbackActive) {
    setGreen();
    return;
  }

  if (isRecording) {
    if (recordingBlinkOn) setRed();
    else setLEDOff();
    return;
  }

  // --- PRIORITIES WHEN SWITCH IS ON ---
  bool charging = batteryIsCharging();

  // Active connected state
  if (charging) {
    // Red + Blue combined = Solid Purple (Charging + Connected)
    digitalWrite(LED_RED, LOW);
    digitalWrite(LED_GREEN, HIGH);
    digitalWrite(LED_BLUE, LOW);
  } else {
    setBlue(); // Battery power + Connected
  }
  return;
}

// --------------------------------------------------
// Shared blink updater
// --------------------------------------------------
void updateBaseBlink() {
  unsigned long now = millis();
  static bool lastConnectedState = false;
  static bool lastUsbState = false;
  static bool lastChargingState = false;
  
  bool currentlyConnected = Bluefruit.connected();
  bool currentlyUsbPlugged = usbPluggedIn();
  bool currentlyCharging = batteryIsCharging();

  if (failureLEDUntil && now >= failureLEDUntil) {
    failureLEDUntil = 0;
    showBaseLEDState();
  }

  // If connection status changes or USB is yanked/inserted, instantly refresh LEDs
  if (currentlyConnected != lastConnectedState ||
      currentlyUsbPlugged != lastUsbState ||
      currentlyCharging != lastChargingState) {
    bool powerChanged = currentlyUsbPlugged != lastUsbState ||
                        currentlyCharging != lastChargingState;
    lastConnectedState = currentlyConnected;
    lastUsbState = currentlyUsbPlugged;
    lastChargingState = currentlyCharging;
    showBaseLEDState();
    if (powerChanged) updateBatteryStatus();
  }

  // Disconnected state always blinks blue, even if the last known app state was
  // recording. Once reconnected, recording LED priority is restored below.
  if (!currentlyConnected) {
    if (now - lastBlinkTime >= blinkInterval) {
      lastBlinkTime = now;
      blinkOn = !blinkOn;
      showBaseLEDState();
    }
    return;
  }

  if (clipFeedbackActive) {
    if (now - clipFeedbackStartedAt >= clipFeedbackDuration) {
      clipFeedbackActive = false;
      showBaseLEDState();
    }
    return;
  }

  if (isRecording) {
    if (now - lastRecordingBlinkTime >= blinkInterval) {
      lastRecordingBlinkTime = now;
      recordingBlinkOn = !recordingBlinkOn;
      showBaseLEDState();
    }
    return;
  }

}

// --------------------------------------------------
// BLE Callbacks & Setup
// --------------------------------------------------
void startAdv() {
  Bluefruit.Advertising.stop();
  // This can run again after waking from USB-powered sleep. Without clearing,
  // repeated calls append duplicate fields until the advertising data is full.
  Bluefruit.Advertising.clearData();
  Bluefruit.ScanResponse.clearData();
  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(bleuart);
  Bluefruit.Advertising.addService(blebas);
  Bluefruit.Advertising.addName();
  Bluefruit.ScanResponse.addName();
  
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);
  Bluefruit.Advertising.setFastTimeout(30);
  if (!Bluefruit.Advertising.start(0)) {
    Serial.println("Advertising start failed; will retry");
  } else {
    advertisingDataNeedsRefresh = false;
  }
}

void connect_callback(uint16_t conn_handle) {
  activeConnHandle = conn_handle; 
  // Replay every unacknowledged tap on the new link, not only the oldest one.
  for (uint8_t i = 0; i < commandCount; i++) commandQueue[i].lastSentAt = 0;
  nextClipOffset = 0;
  clipPacketSent = false;
  controlPending = false;
  controlAttempts = 0;
  controlWasSent = false;
  // Give the connection a moment to finish setup before requesting coded PHY.
  phyUpdatePending = true;
  phyUpdateNotBefore = millis() + 500;
  showBaseLEDState(); 
}

void disconnect_callback(uint16_t conn_handle, uint8_t reason) {
  (void) reason;
  if (conn_handle != activeConnHandle) return;
  activeConnHandle = 0xFFFF;
  phyUpdatePending = false;
  // A delayed record-start/stop would be dangerous after reconnection.
  // Timestamped clip taps remain queued for reconciliation with the video.
  controlPending = false;
  controlAttempts = 0;
  controlWasSent = false;
  clipPacketSent = false;
  blinkOn = true;
  lastBlinkTime = millis();
  if (advertisingDataNeedsRefresh) startAdv();
  showBaseLEDState(); 
}

void requestLongRangePHY(uint16_t conn_handle) {
  ble_gap_phys_t phys;
  phys.tx_phys = BLE_GAP_PHY_CODED;
  phys.rx_phys = BLE_GAP_PHY_CODED;

  uint32_t err = sd_ble_gap_phy_update(conn_handle, &phys);

  Serial.print("Coded PHY request result: ");
  Serial.println(err);
}

bool queueCommand(char kind) {
  // A clip tap is meaningful even when the link is down: the phone may still
  // be recording. Start/stop cannot operate the camera while disconnected.
  if (kind != 'C') {
    if (controlPending || !Bluefruit.connected() || !bleuart.notifyEnabled()) {
      failureLEDUntil = millis() + 1000;
      showBaseLEDState();
      return false;
    }
    controlCommand = { nextSequence++, kind, millis(), 0 };
    controlPending = true;
    controlAttempts = 0;
    controlWasSent = false;
    serviceCommandQueue();
    return true;
  }
  if (commandCount == commandQueueCapacity) {
    failureLEDUntil = millis() + 1000;
    showBaseLEDState();
    return false;
  }
  commandQueue[commandCount++] = { nextSequence++, kind, millis(), 0 };
  serviceCommandQueue();
  return true;
}

// Ten bytes -> 16 Base64 characters. Including Q and newline, this is 18
// bytes, fitting even the default 20-byte BLE notification payload.
void encodeClipPayload(const PendingCommand& command, uint32_t ageMs, char output[17]) {
  uint8_t bytes[10] = {
    (uint8_t)(bootToken >> 24), (uint8_t)(bootToken >> 16),
    (uint8_t)(bootToken >> 8), (uint8_t)bootToken,
    (uint8_t)(command.sequence >> 8), (uint8_t)command.sequence,
    (uint8_t)(ageMs >> 24), (uint8_t)(ageMs >> 16),
    (uint8_t)(ageMs >> 8), (uint8_t)ageMs
  };
  const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  uint8_t out = 0;
  for (uint8_t i = 0; i < sizeof(bytes); i += 3) {
    uint32_t value = ((uint32_t)bytes[i] << 16);
    if (i + 1 < sizeof(bytes)) value |= ((uint32_t)bytes[i + 1] << 8);
    if (i + 2 < sizeof(bytes)) value |= bytes[i + 2];
    output[out++] = alphabet[(value >> 18) & 63];
    output[out++] = alphabet[(value >> 12) & 63];
    output[out++] = i + 1 < sizeof(bytes) ? alphabet[(value >> 6) & 63] : '=';
    output[out++] = i + 2 < sizeof(bytes) ? alphabet[value & 63] : '=';
  }
  output[out] = '\0';
}

int hexDigitValue(char digit) {
  if (digit >= '0' && digit <= '9') return digit - '0';
  if (digit >= 'A' && digit <= 'F') return digit - 'A' + 10;
  if (digit >= 'a' && digit <= 'f') return digit - 'a' + 10;
  return -1;
}

bool parseAcknowledgment(const char* message, uint32_t& token,
                         uint16_t& sequence, bool& accepted) {
  // Exact framing makes a partial or concatenated UART write harmless. The
  // line is 19 characters without its newline: ACK BBBBBBBB SSSS 0/1.
  if (strlen(message) != 19 || strncmp(message, "ACK ", 4) != 0 ||
      message[12] != ' ' || message[17] != ' ' ||
      (message[18] != '0' && message[18] != '1')) return false;

  token = 0;
  sequence = 0;
  for (uint8_t i = 4; i < 12; i++) {
    int digit = hexDigitValue(message[i]);
    if (digit < 0) return false;
    token = (token << 4) | (uint32_t)digit;
  }
  for (uint8_t i = 13; i < 17; i++) {
    int digit = hexDigitValue(message[i]);
    if (digit < 0) return false;
    sequence = (sequence << 4) | (uint16_t)digit;
  }
  accepted = message[18] == '1';
  return true;
}

void serviceCommandQueue() {
  if ((!commandCount && !controlPending) || !Bluefruit.connected() ||
      !bleuart.notifyEnabled()) return;
  unsigned long now = millis();
  // Give start/stop priority, but still service a clip while waiting for the
  // control's next retry. Both lanes have independent ACKs and retry clocks.
  if (controlPending && (!controlWasSent || now - lastControlAttempt >= commandRetryMs)) {
    if (controlAttempts >= maxCommandAttempts) {
      Serial.println("Record command timed out without app acknowledgment");
      controlPending = false;
      controlWasSent = false;
      controlAttempts = 0;
      failureLEDUntil = now + 1000;
      showBaseLEDState();
    } else {
      char controlMessage[32];
      snprintf(controlMessage, sizeof(controlMessage), "CMD %08lX %04X %c\n",
               (unsigned long)bootToken, controlCommand.sequence, controlCommand.kind);
      size_t length = strlen(controlMessage);
      if (bleuart.write((const uint8_t*)controlMessage, length) == length) {
        controlWasSent = true;
        lastControlAttempt = now;
        controlAttempts++;
        return;
      }
    }
  }
  if (!commandCount || (clipPacketSent && now - lastClipPacketAt < clipPacketSpacingMs)) return;
  for (uint8_t step = 0; step < commandCount; step++) {
    uint8_t index = (nextClipOffset + step) % commandCount;
    PendingCommand& clip = commandQueue[index];
    if (clip.lastSentAt && now - clip.lastSentAt < clipRetryMs) continue;

    char message[20];
    char payload[17];
    encodeClipPayload(clip, (uint32_t)(now - clip.pressedAt), payload);
    snprintf(message, sizeof(message), "Q%s\n", payload);
    size_t length = strlen(message);
    if (bleuart.write((const uint8_t*)message, length) == length) {
      clip.lastSentAt = now;
      lastClipPacketAt = now;
      clipPacketSent = true;
      nextClipOffset = (index + 1) % commandCount;
    }
    return;
  }
}

void applyRecordingStateFromApp(bool recording) {
  isRecording = recording;
  clipFeedbackActive = false;
  recordingBlinkOn = recording;
  lastRecordingBlinkTime = millis();
  showBaseLEDState();
}

void handleIncomingBLECommand() {
  static char commandBuffer[48];
  static size_t commandLength = 0;
  static bool overflow = false;

  while (bleuart.available()) {
    char c = static_cast<char>(bleuart.read());

    if (c == '\n' || c == '\r') {
      if (!overflow && commandLength > 0) {
        commandBuffer[commandLength] = '\0';

        if (strcmp(commandBuffer, "GET_BATTERY") == 0) {
          updateBatteryStatus();
        } else if (strcmp(commandBuffer, "GET_NAME") == 0) {
          sendCurrentButtonName();
        } else if (strncmp(commandBuffer, "SET_NAME ", 9) == 0) {
          if (savePersistentButtonName(commandBuffer + 9)) {
            sendCurrentButtonName();
          } else {
            bleuart.println("NAME_ERROR");
          }
        } else if (strcmp(commandBuffer, "RESET_NAME") == 0) {
          if (resetPersistentButtonName()) {
            sendCurrentButtonName();
          } else {
            bleuart.println("NAME_ERROR");
          }
        } else if (strcmp(commandBuffer, "RECORDING_STATE 1") == 0) {
          applyRecordingStateFromApp(true);
        } else if (strcmp(commandBuffer, "RECORDING_STATE 0") == 0) {
          applyRecordingStateFromApp(false);
        } else if (strcmp(commandBuffer, "COMMAND_FAILED") == 0) {
          failureLEDUntil = millis() + 1000;
          showBaseLEDState();
        } else {
          uint32_t receivedBoot = 0;
          uint16_t receivedSequence = 0;
          bool accepted = false;
          if (parseAcknowledgment(commandBuffer, receivedBoot,
                                  receivedSequence, accepted) &&
              receivedBoot == bootToken) {
            if (controlPending && receivedSequence == controlCommand.sequence) {
              if (!accepted) failureLEDUntil = millis() + 1000;
              controlPending = false;
              controlWasSent = false;
              controlAttempts = 0;
              showBaseLEDState();
            } else {
              for (uint8_t i = 0; i < commandCount; i++) {
                if (receivedSequence != commandQueue[i].sequence) continue;
                if (accepted) {
                  clipFeedbackActive = true;
                  clipFeedbackStartedAt = millis();
                } else {
                  failureLEDUntil = millis() + 1000;
                }
                if (i < nextClipOffset) nextClipOffset--;
                for (uint8_t j = i; j + 1 < commandCount; j++) {
                  commandQueue[j] = commandQueue[j + 1];
                }
                commandCount--;
                if (!commandCount || nextClipOffset >= commandCount) nextClipOffset = 0;
                showBaseLEDState();
                break;
              }
            }
          }
        }
      }
      commandLength = 0;
      overflow = false;
    } else if (!overflow && commandLength < sizeof(commandBuffer) - 1) {
      commandBuffer[commandLength++] = c;
    } else {
      overflow = true; // Drop the whole malformed line; never parse a suffix.
    }
  }
}

// --------------------------------------------------
// Setup / Loop
// --------------------------------------------------
void setup() {
  // Initialize pins with internal pull up resistors
  pinMode(buttonPin, INPUT_PULLUP);
  pinMode(powerSwitchPin, INPUT_PULLUP);

  // Deep sleep hardware register config - talks straight to reg and makes 
  // the chip look at the switch pin  
  nrf_gpio_cfg_sense_input(
      digitalPinToPinName(powerSwitchPin),
      NRF_GPIO_PIN_PULLUP,
      NRF_GPIO_PIN_SENSE_LOW
  );

  // Initialize all the RGB LEDs as outputs
  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);

  // Keep the divider enabled to avoid the documented P0.31 charging hazard.
  pinMode(PIN_VBAT_ENABLE, OUTPUT);
  digitalWrite(PIN_VBAT_ENABLE, LOW);
  pinMode(PIN_CHARGE_STATUS, INPUT);

  // Enable fast charging (100mA instead of 50mA)
  pinMode(22, OUTPUT);
  digitalWrite(22, LOW);

  // AR_DEFAULT sets the reference ceiling to the 
  // internal chip voltage (approx 3.6V), and 12 
  // unlocks 12-bit resolution (0 to 4095)
  analogReference(AR_DEFAULT);
  analogReadResolution(12);

  // Shuts off all LEDs, sets data speed to 115200 baud, and delays for .5s
  setLEDOff();
  Serial.begin(115200);
  delay(500);

  // Bluetooth protocol init 
  Bluefruit.begin();
  // A fresh random boot token prevents an old ACK/dedup entry from matching
  // sequence 1 after a fast power cycle. It is identity, not authentication.
  bootToken = ((uint32_t)NRF_FICR->DEVICEID[0] ^ micros());
  uint8_t randomCapacity = 0;
  for (uint8_t attempt = 0; attempt < 100; attempt++) {
    if (sd_rand_application_pool_capacity_get(&randomCapacity) == NRF_SUCCESS &&
        randomCapacity >= sizeof(bootToken) &&
        sd_rand_application_vector_get((uint8_t*)&bootToken,
                                       sizeof(bootToken)) == NRF_SUCCESS) break;
    delay(1);
  }
  nextSequence = (uint16_t)(bootToken ^ (bootToken >> 16));
  if (nextSequence == 0) nextSequence = 1;
  // nRF52840 supports up to +8 dBm. This favors range over battery life.
  Bluefruit.setTxPower(8);

  // Preferred connection parameters for a stable, responsive button link.
  // The iPhone may negotiate different values because it is the BLE central.
  Bluefruit.Periph.setConnIntervalMS(
      preferredConnectionIntervalMs,
      preferredConnectionIntervalMs
  );
  Bluefruit.Periph.setConnSlaveLatency(0);
  Bluefruit.Periph.setConnSupervisionTimeoutMS(preferredSupervisionTimeoutMs);

  Bluefruit.autoConnLed(false); 
  loadPersistentButtonName();

  // Links hardware event listeners to custom code blocks
  Bluefruit.Periph.setConnectCallback(connect_callback);
  Bluefruit.Periph.setDisconnectCallback(disconnect_callback);

  // Defines the standard Bluetooth data slots your device offers: 
  // DIS (Device Information Service), UART (Custom string streaming 
  // service for button commands), and BAS (Battery Service)
  bledis.setManufacturer("ClipIt");
  bledis.setModel("XIAO nRF52840");
  bledis.begin();

  bleuart.begin();
  blebas.begin();
  blebas.write(0); // Replaced with a measured estimate before advertising.
  
  // Interrupt Service Routine (ISR) attached to power switch
  attachInterrupt(digitalPinToInterrupt(powerSwitchPin), switchISR, CHANGE);

  if (digitalRead(powerSwitchPin) == HIGH) {
    if (usbPluggedIn()) {
      deviceAwake = false;
      if (batteryIsCharging()) setRed();
      else setLEDOff();
    } else {
      deviceAwake = false;
      enterLowPowerMode();
    }
  } else {
    deviceAwake = true;
    blinkOn = true;
    lastBlinkTime = millis();
    updateBatteryStatus();
    startAdv();
    showBaseLEDState();
  }

  Serial.println("BLE ClipIt ready");
}

void loop() {
  bool switchOn = (digitalRead(powerSwitchPin) == LOW);

  // --- SLEEP / CHARGING ENGINE WHEN SWITCH IS OFF ---
  if (!switchOn) {
    if (usbPluggedIn()) {
      if (deviceAwake || activeConnHandle != 0xFFFF) {
        Bluefruit.Advertising.stop();
        if (activeConnHandle != 0xFFFF) {
          Bluefruit.disconnect(activeConnHandle); 
          activeConnHandle = 0xFFFF;
          phyUpdatePending = false;
          delay(100); 
        }
        deviceAwake = false;
      }
      if (batteryIsCharging()) setRed();
      else setLEDOff();
      __WFE(); 
      return;
    }
    
    enterLowPowerMode();
    return;  
  }

  // --- WAKE ENGINE ---
  if (!deviceAwake) {
    wakeDevice();
  }

  // --- RUNTIME CODE (Only runs when Switch is ON) ---
  handleIncomingBLECommand();
  handleButton();
  serviceCommandQueue();

  if (Bluefruit.connected() && bleuart.notifyEnabled() &&
      millis() - lastQueueStatusAt >= queueStatusIntervalMs) {
    lastQueueStatusAt = millis();
    char statusMessage[16];
    snprintf(statusMessage, sizeof(statusMessage), "PENDING %u\n", commandCount);
    bleuart.write((const uint8_t*)statusMessage, strlen(statusMessage));
  }

  if (!Bluefruit.connected() && millis() - lastAdvertisingRecovery >= 10000) {
    lastAdvertisingRecovery = millis();
    if (!Bluefruit.Advertising.isRunning()) startAdv();
  }

  if (phyUpdatePending &&
      activeConnHandle != 0xFFFF &&
      millis() >= phyUpdateNotBefore) {
    requestLongRangePHY(activeConnHandle);
    phyUpdatePending = false;
  }

  updateBaseBlink();

  if (millis() - lastBatteryCheck >= batteryInterval) {
    lastBatteryCheck = millis();
    updateBatteryStatus();
  }
}

// --------------------------------------------------
// Power Transitions
// --------------------------------------------------
void enterLowPowerMode() {
    Serial.println("Entering Deep System OFF...");
    // Tells processor to halt and wait for every character to be sent over UART
    Serial.flush();
    // Stop advertising, check that there is no connection, tells app to close the
    // connection
    Bluefruit.Advertising.stop();
    if (activeConnHandle != 0xFFFF) {
        Bluefruit.disconnect(activeConnHandle);
        activeConnHandle = 0xFFFF;
        delay(100);
    }
    // LEDs off; leave P0.14 LOW even in System OFF so USB insertion does not
    // expose the ADC input to the unsafe divider-disabled voltage.
    setLEDOff();
    digitalWrite(PIN_VBAT_ENABLE, LOW);

    // Puts flash memory chip to sleep. 0xB9 is a raw SPI hardware command to 
    // instruct the flash chip to power down
    flashTransport.begin();
    flashTransport.runCommand(0xB9); 
    flashTransport.end();

    deviceAwake = false;
    delay(20); 

    // SoftDevice OS shut down all radio timers and sleep
    sd_power_system_off();
    // Cut power to everything and wait for wake up ON switch
    NRF_POWER->SYSTEMOFF = 1; 
    
    while (1); 
}

void wakeDevice() {
  Serial.println("Waking device...");
  
  startAdv();
  updateBatteryStatus();
  
  blinkOn = true;
  lastBlinkTime = millis();
  
  showBaseLEDState();
  
  lastBatteryCheck = millis();
  deviceAwake = true;
}

void switchISR() {
  // Empty Handler: Hardware interrupt snaps CPU out of light sleep
}

// --------------------------------------------------
// Buttons
// --------------------------------------------------
void handleButton() {
  bool reading = digitalRead(buttonPin);

  if (reading != lastButtonReading) {
    lastButtonDebounceTime = millis();
  }

  unsigned long now = millis();

  if ((now - lastButtonDebounceTime) > debounceDelay) {
    if (reading != buttonState) {
      buttonState = reading;

      if (buttonState == LOW) {
        buttonPressedAt = now;
        longPressHandled = false;
      } else if (!longPressHandled) {
        // A release before the hold threshold is a normal clip tap.
        if (queueCommand('C')) clipCount++;
      }
    }
  }

  // Evaluate the hold while the button remains pressed and send exactly one command.
  if (buttonState == LOW && !longPressHandled &&
      (now - buttonPressedAt >= longPressDuration)) {
    // Recording LED changes only after the phone reports the camera state.
    queueCommand(isRecording ? 'T' : 'S');

    longPressHandled = true;
  }

  lastButtonReading = reading;
}
