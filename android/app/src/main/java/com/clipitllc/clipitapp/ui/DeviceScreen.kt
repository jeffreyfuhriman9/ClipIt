package com.clipitllc.clipitapp.ui

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.clipitllc.clipitapp.ble.BLEViewModel

@Composable
fun DeviceScreen(bleViewModel: BLEViewModel) {
    val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        if (results.values.all { it }) {
            bleViewModel.startScanning()
        }
    }

    LaunchedEffect(Unit) {
        permissionLauncher.launch(permissions)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text("Device Manager", style = MaterialTheme.typography.headlineMedium)

        Card(modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Status: ${bleViewModel.bleState.label}", style = MaterialTheme.typography.titleMedium)
                bleViewModel.remoteBatteryLevel?.let { battery ->
                    Text("Battery: $battery%", style = MaterialTheme.typography.bodyLarge)
                }
                if (bleViewModel.lastMessage.isNotEmpty()) {
                    Text("Last command: ${bleViewModel.lastMessage}", style = MaterialTheme.typography.bodySmall)
                }
                if (bleViewModel.bleState.isConnected) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Button(onClick = { bleViewModel.disconnect() }) {
                        Text("Disconnect")
                    }
                }
            }
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("Discovered Remotes", style = MaterialTheme.typography.titleMedium)
            Button(onClick = { bleViewModel.startScanning() }) {
                Text("Scan")
            }
        }

        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items(bleViewModel.discoveredDevices) { device ->
                Card(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(12.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column {
                            Text(device.name, style = MaterialTheme.typography.bodyLarge)
                            Text("RSSI: ${device.rssi} dBm", style = MaterialTheme.typography.bodySmall)
                        }
                        Button(onClick = { bleViewModel.connect(to = device) }) {
                            Text("Connect")
                        }
                    }
                }
            }
        }
    }
}