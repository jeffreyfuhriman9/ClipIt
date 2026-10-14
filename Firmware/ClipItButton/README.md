# ClipIt Button pilot firmware

Use `ClipItButton.ino` with the **Seeed Studio XIAO nRF52840** and the
Seeeduino nRF52 board package (verified here with version 1.1.12). This
firmware and the companion iOS app changes should be deployed together.

## BLE protocol

Nordic UART messages are UTF-8 lines ending in `\n`. Start and stop use
`CMD BBBBBBBB SSSS K`, where `BBBBBBBB` is a random per-boot hex token,
`SSSS` is a four-digit hex sequence, and `K` is `S` (start) or `T` (stop).
Clip taps use `Q` followed by Base64 of ten big-endian bytes: boot token
(4), sequence (2), and milliseconds since the physical press (4). The
timestamp is recalculated on every retry, so a tap delivered after a BLE
dropout still points to its original position in the phone's recording.
The whole `Q` line is 18 bytes and fits a default BLE notification.
The app returns `ACK BBBBBBBB SSSS 1` for an accepted
request or `ACK BBBBBBBB SSSS 0` for a rejected request. Acceptance means
the app accepted the command, **not** that a video file has been saved.
Recording is confirmed separately with `RECORDING_STATE 1` after AVFoundation
starts recording, or `RECORDING_STATE 0` after it stops. The app sends
`COMMAND_FAILED` when the camera subsequently fails. Start/stop commands
retry up to eight times, 650 ms apart while connected. Clip taps are replayed
individually in round-robin order until each is acknowledged. One missing
clip ACK cannot block later taps or new taps, and start/stop commands use a
separate priority lane. Clip taps remain queued after a disconnect, including
taps made while disconnected.
The RAM clip queue holds up to 64 taps; a full queue lights the failure LED.
It does **not** survive a button power cycle. Start and stop commands are not
replayed after a disconnect, since starting or stopping the camera late would
be unsafe. The app needs the original video to recover a late clip; taps
outside a recorded interval are rejected. The app
deduplicates sequence IDs across reconnects and relaunches (bounded history).

On the phone, a buffered tap is retried while session metadata is loading or
its movie is still being finalized. Recovered markers are preserved during
normal highlight export, and metadata writes happen in order so a stale save
cannot overwrite a newer marker.
The button also reports `PENDING n` every two seconds while connected. The
Device screen shows this queue count so a physical reconnect test can verify
that all taps reached the phone and were acknowledged. A count of zero means
the button queue drained; clip export may still be processing on the phone.

Older button firmware using `CLIP n`, `START_RECORDING`,
`STOP_RECORDING`, or `TOGGLE_RECORD` remains supported by the app. The
button still accepts `GET_BATTERY` and `RECORDING_STATE 0/1`.

## Button name and reconnect behavior

The updated app keeps **Auto-Reconnect off by default**. A player can opt in
only for a button they personally own; this prevents a phone at a shared gym
from automatically taking a button it used on a previous day.

When a connected button is renamed in the Device screen, the app sends
`SET_NAME <name>`. The firmware saves up to 23 ASCII letters, numbers,
spaces, hyphens, apostrophes, or underscores in the XIAO's internal flash.
It then advertises the name as `Clip: <name>`, which lets every phone running
the updated app identify the same button while scanning. `RESET_NAME` returns
it to `ClipIt Button`; `GET_NAME` returns `NAME <name>`. The name survives
power cycles and app/device changes, but is reset if the firmware's internal
filesystem is erased or the board is reflashed with a sketch that formats it.
Buttons on older firmware keep the default `ClipIt Button` name and continue
to work with the app.

The device's RGB LED indicates blue when connected but not recording,
blinking blue when disconnected, blinking red only after camera-start
confirmation, short green after an accepted clip marker, and one second red
on rejection or command timeout. On USB it displays charging only when
P0.17 reports active charging. This pin cannot distinguish a full battery
from another non-charging condition.

## Build and upload

1. In Arduino IDE, install/select **Seeed nRF52 Boards** and choose
   **Seeed Studio XIAO nRF52840** (not the Sense/Plus variant unless that is
   actually the installed board). Open `ClipItButton.ino`.
2. Connect one button with a data-capable USB-C cable. Select its port in
   **Tools > Port**, then click **Verify** and **Upload**. If the port is not
   visible, use the board's bootloader/reset procedure from Seeed's guide;
   do not guess a serial port belonging to another device.
3. Install the updated ClipIt app on the iPhone **before flashing this
   firmware**. Older app builds do not understand timestamped `Q` clips.
   The updated app still accepts older button firmware.
4. Flash/test the two physical buttons **one at a time** and label them,
   then test with both powered on. Do not flash during an important match.

This project was also verified with Arduino CLI and FQBN
`Seeeduino:nrf52:xiaonRF52840`. The locally installed 1.1.12 package has
an obsolete `python` invocation in its UF2 build recipe; when using the CLI,
override `recipe.objcopy.uf2.pattern` to call `/usr/bin/python3`, or use
Arduino IDE's normal Upload flow. The verification build alone does not
prove flashing or hardware behavior.

## Safety and limitations

- The switch is wired to D4/GND as a logic input; it does not isolate the
  battery. The firmware enters System OFF when unplugged and switched off.
  Check sleep current and charging current on the assembled button.
- P0.14 is deliberately held LOW, including before System OFF, because
  Seeed warns that HIGH while charging can drive the battery ADC input near
  its limit. Measure the resulting off-state current and ADC voltage on
  your exact board revision.
- The 100 mA charge setting is unchanged. Verify the *specific* 500 mAh
  cell's datasheet/label permits this rate, its polarity and protection
  circuit, and temperature behavior before customer use.
- Battery percentage is a voltage-based **estimate**, not a calibrated fuel
  gauge. Compare it with a multimeter at full, mid, and low charge, both
  idle and while charging. The calibration factor is board-specific.
- The boot token is for duplicate detection, not security. Name and DIS
  manufacturer checks are not authentication; a device can spoof them.
- UserDefaults-based app deduplication does not make clip creation an atomic
  transaction across an app crash in the tiny window between processing and
  acknowledgment. This must be tested before promising exactly-once behavior.
- iOS background/lock behavior and Bluetooth recovery require real-iPhone
  testing. This project does not add `bluetooth-central` background mode.
- Test with a real camera recording continuously while toggling Bluetooth from
  Control Center: make several offline taps, reconnect, verify every marker,
  then immediately start and stop another session. Repeat with reconnects
  during highlight export. Compile checks alone cannot prove radio or camera
  behavior on a physical device.
