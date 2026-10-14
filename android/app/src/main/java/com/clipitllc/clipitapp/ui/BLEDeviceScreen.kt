package com.clipitllc.clipitapp.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipitllc.clipitapp.ble.ButtonConnectionPolicy
import com.clipitllc.clipitapp.ble.BLEViewModel
import com.clipitllc.clipitapp.ui.theme.CosmosBlue
import com.clipitllc.clipitapp.ui.theme.CrimsonBlaze

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BLEDeviceScreen(
    bleViewModel: BLEViewModel,
    onBack: (() -> Unit)? = null
) {
    val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { results ->
        if (results.values.all { it }) bleViewModel.startScanning()
    }
    LaunchedEffect(Unit) { permissionLauncher.launch(permissions) }
    val bleState = bleViewModel.bleState
    val discoveredDevices = bleViewModel.discoveredDevices
    var showRenameDialog by remember { mutableStateOf(false) }
    var renameDraft by remember { mutableStateOf("") }
    var showAutoReconnectConfirmation by remember { mutableStateOf(false) }

    Scaffold(
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text("Device", fontWeight = FontWeight.Bold) },
                navigationIcon = {
                    if (onBack != null) IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.White,
                    titleContentColor = CosmosBlue,
                    navigationIconContentColor = CosmosBlue
                )
            )
        }
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(Color(0xFFF2F2F7))
        ) {
            item {
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 8.dp)
                        .tourTarget(TourTarget.DEVICE),
                    color = Color.White,
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(24.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, com.clipitllc.clipitapp.ui.theme.BlueMarble.copy(alpha = 0.12f))
                ) {
                    Column(modifier = Modifier.padding(22.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp)
                    ) {
                        Surface(
                            modifier = Modifier.size(64.dp),
                            shape = androidx.compose.foundation.shape.RoundedCornerShape(18.dp),
                            color = CrimsonBlaze.copy(alpha = 0.12f)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Icon(
                                    Icons.Default.SmartButton,
                                    contentDescription = null,
                                    tint = CrimsonBlaze,
                                    modifier = Modifier.size(30.dp)
                                )
                            }
                        }
                        
                        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                val buttonId = bleViewModel.connectedDeviceId.takeIf { bleState.isConnected }
                                Text(if (buttonId != null) bleViewModel.connectedButtonName else "ClipIt Button",
                                    fontWeight = FontWeight.Bold, fontSize = 21.sp, color = CosmosBlue, modifier = Modifier.weight(1f))
                                if (buttonId != null) IconButton(onClick = {
                                    renameDraft = bleViewModel.connectedButtonName.takeUnless { it == "ClipIt Button" }.orEmpty()
                                    showRenameDialog = true
                                }) { Icon(Icons.Default.Edit, contentDescription = "Rename button", tint = CrimsonBlaze) }
                            }
                            Text(if (bleState.isConnected) "Connected" else if (bleState is com.clipitllc.clipitapp.ble.BLEState.Scanning) "Scanning" else if (bleState is com.clipitllc.clipitapp.ble.BLEState.Connecting) "Connecting" else "Not connected",
                                color = if (bleState.isConnected) Color(0xFF2E9E53) else Color.Gray, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            bleViewModel.connectedDeviceId.takeIf { bleState.isConnected }?.let {
                                Text("Button ID ${it.takeLast(4)}", color = Color.Gray, fontSize = 12.sp)
                            }
                        }
                    }
                    Text(when {
                        bleState.isConnected -> "Press your ClipIt Button while recording to save a highlight."
                        bleState is com.clipitllc.clipitapp.ble.BLEState.Connecting -> "Keep your button nearby while the connection finishes."
                        bleViewModel.isWaitingForManualButtonSelection -> "Choose a button below to reconnect. Your disconnected button won't reconnect on its own."
                        else -> "Turn on your button, then scan to connect."
                    }, color = Color.Gray, fontSize = 14.sp)
                    if (bleState.isConnected) {
                        HorizontalDivider(color = Color.Black.copy(alpha = 0.08f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.BatteryFull, contentDescription = null,
                                tint = if ((bleViewModel.remoteBatteryLevel ?: 100) <= 20) Color.Red else Color.Green)
                            Spacer(Modifier.width(12.dp))
                            Text("Button battery (estimated)", modifier = Modifier.weight(1f), color = Color.Gray, fontSize = 14.sp)
                            bleViewModel.remoteBatteryLevel?.let { battery ->
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text("$battery%", color = CosmosBlue, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                                }
                            } ?: Text("Checking…", color = CosmosBlue, fontSize = 17.sp)
                        }
                        if (bleViewModel.remoteUSBConnected != null) {
                            Text(
                                if (bleViewModel.remoteUSBConnected == true)
                                    if (bleViewModel.remoteBatteryCharging == true) "USB connected · charging"
                                    else "USB connected"
                                else "Running on battery",
                                color = Color.Gray, fontSize = 12.sp
                            )
                        }
                        HorizontalDivider(color = Color.Black.copy(alpha = 0.08f))
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("Clip transfer", fontWeight = FontWeight.SemiBold, color = CosmosBlue)
                            Text(when (val pending = bleViewModel.pendingButtonClips) {
                                null -> "Checking button queue…"
                                0 -> "Button queue clear. Video clips may still be processing."
                                1 -> "1 button tap awaiting acknowledgment"
                                else -> "$pending button taps awaiting acknowledgment"
                            }, color = Color.Gray, fontSize = 13.sp)
                            Text(bleViewModel.lastClipTransferStatus, color = CosmosBlue, fontSize = 13.sp)
                        }
                    }
                    if (bleState.isConnected) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                        TextButton(onClick = bleViewModel::disconnect) { Text("Disconnect Button", color = Color.Red) }
                    }
                    }
                }
            }

            item {
                if (bleState is com.clipitllc.clipitapp.ble.BLEState.Connecting) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp).height(52.dp),
                        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(20.dp), color = CrimsonBlaze)
                        Spacer(Modifier.width(10.dp))
                        Text("Connecting…", fontWeight = FontWeight.SemiBold)
                    }
                } else if (!bleState.isConnected) Button(
                    onClick = { permissionLauncher.launch(permissions) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 8.dp).height(52.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = CrimsonBlaze),
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(15.dp)
                ) {
                    Icon(Icons.Default.SettingsInputAntenna, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text("Scan for ClipIt Button", fontWeight = FontWeight.SemiBold)
                }
            }

            if (!bleState.isConnected && bleState !is com.clipitllc.clipitapp.ble.BLEState.Connecting && discoveredDevices.isNotEmpty()) {
                item { SectionHeader("Nearby buttons") }
                items(discoveredDevices) { device ->
                    SettingsRow(
                        icon = Icons.Default.Memory,
                        iconColor = Color.Blue,
                        label = bleViewModel.displayNameFor(device.name),
                        onClick = { bleViewModel.connect(device) }
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("ID ${device.id.takeLast(4)} · ${if (device.rssi >= -65) "Strong" else if (device.rssi >= -80) "Good" else "Weak"} signal", color = Color.Gray, fontSize = 12.sp)
                            Icon(Icons.Default.ChevronRight, contentDescription = "Connect", tint = CrimsonBlaze)
                        }
                    }
                }
            }

            item {
                Surface(modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp), color = Color.White,
                    shape = androidx.compose.foundation.shape.RoundedCornerShape(18.dp)) {
                Row(Modifier.padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Auto-reconnect", fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                        Text("Off by default. Use only with a button you personally own.", color = Color.Gray, fontSize = 12.sp)
                    }
                    Switch(
                        checked = bleViewModel.autoReconnect,
                        onCheckedChange = { enabled ->
                            if (enabled) showAutoReconnectConfirmation = true
                            else bleViewModel.autoReconnect = false
                        },
                        colors = SwitchDefaults.colors(checkedTrackColor = CrimsonBlaze)
                    )
                }
                }
            }
        }
    }
    if (showRenameDialog) AlertDialog(
        onDismissRequest = { showRenameDialog = false },
        title = { Text("Rename ClipIt Button") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "This name is saved on your ClipIt Button and will appear on every phone that scans for it.",
                    color = Color.Gray,
                    fontSize = 13.sp
                )
                OutlinedTextField(
                    value = renameDraft,
                    onValueChange = { renameDraft = ButtonConnectionPolicy.filterFriendlyName(it) },
                    label = { Text("Button name") },
                    supportingText = {
                        Text("${renameDraft.length}/23 · Letters, numbers, spaces, hyphens, apostrophes, and underscores")
                    },
                    singleLine = true
                )
            }
        },
        confirmButton = { TextButton(onClick = {
            bleViewModel.renameConnectedButton(renameDraft)
            showRenameDialog = false
        }, enabled = renameDraft.isNotBlank()) { Text("Save") } },
        dismissButton = {
            Row {
                if (bleViewModel.connectedButtonName != "ClipIt Button") {
                    TextButton(onClick = {
                        bleViewModel.resetConnectedButtonName()
                        showRenameDialog = false
                    }) { Text("Use Default Name") }
                }
                TextButton(onClick = { showRenameDialog = false }) { Text("Cancel") }
            }
        }
    )
    if (showAutoReconnectConfirmation) AlertDialog(
        onDismissRequest = { showAutoReconnectConfirmation = false },
        title = { Text("Turn On Auto-Reconnect?") },
        text = { Text("Only turn Auto-Reconnect on if you own your own ClipIt Button. Shared buttons can connect to a nearby phone that used them previously.") },
        confirmButton = {
            TextButton(onClick = {
                showAutoReconnectConfirmation = false
                bleViewModel.autoReconnect = true
            }) { Text("Turn On") }
        },
        dismissButton = {
            TextButton(onClick = { showAutoReconnectConfirmation = false }) { Text("Not Now") }
        }
    )
    bleViewModel.commandError?.let { error ->
        AlertDialog(
            onDismissRequest = bleViewModel::clearCommandError,
            title = { Text("ClipIt Button") },
            text = { Text(error) },
            confirmButton = {
                TextButton(onClick = bleViewModel::clearCommandError) { Text("OK") }
            }
        )
    }
}
