# XIAO offline clip recovery: phone test

Use the updated XIAO firmware and a physical Android phone. The phone must keep recording while Bluetooth is disconnected. The XIAO holds at most 64 taps in RAM; do not power it off during this test.

1. Connect the button in **Device** and start a recording. Make one live tap. Confirm the on-screen clip confirmation appears.
2. Disable Bluetooth on the phone without stopping the recording. Tap the button four times at distinct moments, at least a few seconds apart. Keep the phone recording.
3. Re-enable Bluetooth and let the button reconnect. In **Device**, watch **Clip transfer** drain to `Button queue clear`. The firmware reports `PENDING n` only about every two seconds, so a fast transfer may skip the visible `4` and show a lower first count. Queue clear means the timestamps reached the app; the video exports may still be running.
4. Stop recording. Wait for processing to finish. In **Library**, verify five highlight clips exist, are numbered in tap-time order, and each plays the correct moment of the original video.
5. Start a second recording and make another tap. Stop and verify the new session has its own playable clip.
6. Repeat steps 1–4, but stay disconnected after the four taps, stop the recording, then reconnect **while the original highlights are processing**. Verify recovered clips remain attached to that session and appear after processing. Also repeat with taps replayed out of order if the firmware can be induced to do so.
7. Disconnect again and make a tap after the phone has actually stopped recording. On reconnect, verify the app reports that no matching video was found; no playable clip should be fabricated.

The automated tests cover UART framing, packet decoding, replay identity, reconstructed press time, recording-window matching, pending counts, and reconnect state commands. They cannot establish real radio reliability, CameraX behavior in the background, or actual video playback on a phone.
