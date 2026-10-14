package com.clipitllc.clipitapp.ui

import android.util.Log
import android.content.Context
import androidx.core.content.edit
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.SmartButton
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.zIndex
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import android.content.res.Configuration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.painterResource
import androidx.lifecycle.viewmodel.compose.viewModel
import com.clipitllc.clipitapp.ble.BLEViewModel
import com.clipitllc.clipitapp.ble.ButtonProtocol
import com.clipitllc.clipitapp.R
import com.clipitllc.clipitapp.camera.CameraEvent
import com.clipitllc.clipitapp.camera.CameraManager
import com.clipitllc.clipitapp.services.RetentionScheduler
import com.clipitllc.clipitapp.services.CallMonitor
import java.io.File
import kotlinx.coroutines.delay

enum class AppTab(val label: String, val icon: ImageVector) {
    RECORD("Record", Icons.Default.Videocam),
    CLIPS("Library", Icons.Default.Movie),
    DEVICE("Device", Icons.Default.SmartButton),
    SETTINGS("Settings", Icons.Default.Settings)
}

@Composable
fun MainScreen() {
    val context = LocalContext.current
    val isLandscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val preferences = remember { context.getSharedPreferences("clipit_settings", Context.MODE_PRIVATE) }
    var showGuidedTour by remember { mutableStateOf(!preferences.getBoolean("has_seen_guided_tour", false)) }
    var showSplash by rememberSaveable { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        delay(1200)
        showSplash = false
    }
    var selectedTab by rememberSaveable { mutableStateOf(AppTab.RECORD) }
    BackHandler(enabled = selectedTab != AppTab.RECORD) { selectedTab = AppTab.RECORD }

    val cameraManager = remember { CameraManager(context) }
    val callMonitor = remember { CallMonitor(context) }
    val bleViewModel: BLEViewModel = viewModel()
    LaunchedEffect(bleViewModel) {
        if (bleViewModel.autoReconnect) bleViewModel.startScanning()
    }
    val clipsViewModel: ClipsViewModel = viewModel()
    val isRecording by cameraManager.isRecording.collectAsState()
    val isOnCall by callMonitor.isOnCall.collectAsState()
    DisposableEffect(selectedTab) {
        callMonitor.startMonitoring()
        onDispose { callMonitor.stopMonitoring() }
    }
    LaunchedEffect(isOnCall, isRecording) {
        if (isOnCall && isRecording) cameraManager.stopRecording()
    }
    val sessions by clipsViewModel.sessions.collectAsState()
    val recoveredExtractionProgress by clipsViewModel.recoveredExtractionProgress.collectAsState()

    // Listen for incoming hardware button events from BLEViewModel
    LaunchedEffect(Unit) {
        bleViewModel.toggleRecordTrigger.collect {
            if (isRecording) {
                cameraManager.stopRecording()
                bleViewModel.sendRemoteCommand("RECORDING_STATE 0")
            } else {
                cameraManager.startRecording()
            }
        }
    }

    LaunchedEffect(Unit) {
        bleViewModel.startRecordTrigger.collect { if (!isRecording && cameraManager.isReady) cameraManager.startRecording() }
    }
    LaunchedEffect(Unit) {
        bleViewModel.stopRecordTrigger.collect { if (isRecording) cameraManager.stopRecording() }
    }
    LaunchedEffect(Unit) {
        bleViewModel.reliableCommandTrigger.collect { command ->
            if (command.kind == 'C' && command.pressedAtMs != null) {
                when (clipsViewModel.registerRecoveredButtonClip(
                    command.key, command.pressedAtMs,
                    cameraManager.recordingWindowAt(command.pressedAtMs)
                )) {
                    RecoveredClipResult.REGISTERED -> {
                        bleViewModel.reportClipTransferStatus("Registered button tap ${command.sequence}; clip processing may continue.")
                        bleViewModel.acknowledge(command, true)
                    }
                    RecoveredClipResult.AWAITING_RECORDING -> {
                        bleViewModel.reportClipTransferStatus("Received button tap ${command.sequence}; awaiting its recording file.")
                        bleViewModel.acknowledge(command, true)
                        if (cameraManager.isActiveRecordingWindowAt(command.pressedAtMs))
                            cameraManager.showRecoveredHighlightConfirmation(command.key)
                    }
                    RecoveredClipResult.RETRY -> {
                        bleViewModel.reportClipTransferStatus("Received button tap ${command.sequence}; waiting to save it.")
                        bleViewModel.retryWhenRecordingIsReady(command)
                    }
                    RecoveredClipResult.NO_RECORDING -> {
                        bleViewModel.reportClipTransferStatus("Button tap ${command.sequence} could not be matched to recorded video.")
                        bleViewModel.acknowledge(command, false)
                    }
                }
            } else {
                val accepted = when (command.kind) {
                    'C' -> if (isRecording) { cameraManager.markHighlight(); true } else false
                    'S' -> if (!isRecording && cameraManager.isReady) { cameraManager.startRecording(); true } else false
                    'T' -> if (isRecording) { cameraManager.stopRecording(); true } else false
                    else -> false
                }
                bleViewModel.acknowledge(command, accepted)
                if (!accepted) bleViewModel.sendRemoteCommand("COMMAND_FAILED")
            }
        }
    }
    LaunchedEffect(Unit) {
        bleViewModel.connectionReady.collect {
            bleViewModel.sendRemoteCommand(ButtonProtocol.recordingStateCommand(cameraManager.isRecording.value))
        }
    }

    LaunchedEffect(Unit) {
        bleViewModel.clipTrigger.collect {
            if (isRecording) {
                Log.d("MainScreen", "BLE ClipIt Triggered")
                cameraManager.markHighlight()
            }
        }
    }
    
    // Listen for camera events
    LaunchedEffect(Unit) {
        cameraManager.events.collect { event ->
            when (event) {
                CameraEvent.RecordingStarted -> bleViewModel.sendRemoteCommand(ButtonProtocol.recordingStateCommand(true))
                is CameraEvent.MovieFileReady -> {
                    bleViewModel.sendRemoteCommand(ButtonProtocol.recordingStateCommand(false))
                    val recovered = clipsViewModel.addRecording(event.fileUri, event.highlights, event.window)
                    if (recovered > 0) bleViewModel.reportClipTransferStatus(
                        "Registered $recovered buffered button ${if (recovered == 1) "tap" else "taps"}; video clips are processing.")
                }
                is CameraEvent.HighlightExtracted -> {
                    clipsViewModel.addExtractedHighlight(event.fileUri, event.sourceUri, event.highlightIndex, event.timestamp, event.isFavorite)
                }
                is CameraEvent.ExtractionProgress -> {
                    clipsViewModel.updateExtractionProgress(event.sourceUri, event.current, event.total)
                    if (event.current == event.total && event.total > 0) {
                        RetentionScheduler.clipReady(context, event.total)
                    }
                }
                is CameraEvent.Error -> {
                    bleViewModel.sendRemoteCommand("COMMAND_FAILED")
                    bleViewModel.sendRemoteCommand("RECORDING_STATE 0")
                }
                else -> {}
            }
        }
    }

    Scaffold(
        bottomBar = {
            if (isLandscape) {
                Row(Modifier.fillMaxWidth().height(50.dp).zIndex(2f)
                    .background(if (selectedTab == AppTab.RECORD) Color.Transparent else Color.White),
                    verticalAlignment = Alignment.CenterVertically) {
                    AppTab.entries.forEach { tab ->
                        val selected = selectedTab == tab
                        val color = if (selectedTab == AppTab.RECORD) Color.White.copy(alpha = if (selected) 1f else 0.8f)
                            else if (selected) com.clipitllc.clipitapp.ui.theme.CosmosBlue else Color.Gray
                        Column(Modifier.weight(1f).clickable { selectedTab = tab },
                            horizontalAlignment = Alignment.CenterHorizontally) {
                            Icon(tab.icon, contentDescription = tab.label, tint = color, modifier = Modifier.size(20.dp))
                            Text(tab.label, color = color, fontSize = 10.sp,
                                fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
                        }
                    }
                }
            } else {
            NavigationBar(
                modifier = Modifier.zIndex(2f),
                containerColor = if (selectedTab == AppTab.RECORD) Color.Transparent else Color.White,
                tonalElevation = 0.dp
            ) {
                AppTab.entries.forEach { tab ->
                    NavigationBarItem(
                        selected = selectedTab == tab,
                        onClick = { selectedTab = tab },
                        label = { Text(tab.label) },
                        icon = { Icon(tab.icon, contentDescription = tab.label) },
                        colors = if (selectedTab == AppTab.RECORD) NavigationBarItemDefaults.colors(
                            selectedIconColor = Color.White,
                            selectedTextColor = Color.White,
                            unselectedIconColor = Color.White.copy(alpha = 0.8f),
                            unselectedTextColor = Color.White.copy(alpha = 0.8f),
                            indicatorColor = com.clipitllc.clipitapp.ui.theme.CrimsonBlaze.copy(alpha = 0.75f)
                        ) else NavigationBarItemDefaults.colors(
                            selectedIconColor = com.clipitllc.clipitapp.ui.theme.CosmosBlue,
                            selectedTextColor = com.clipitllc.clipitapp.ui.theme.CosmosBlue,
                            indicatorColor = com.clipitllc.clipitapp.ui.theme.CrimsonBlaze.copy(alpha = 0.1f)
                        )
                    )
                }
            }
            }
        }
    ) { innerPadding ->
        Box(modifier = if (selectedTab == AppTab.RECORD) Modifier.fillMaxSize() else Modifier.padding(innerPadding)) {
            when (selectedTab) {
                AppTab.RECORD -> CameraScreen(
                    cameraManager = cameraManager,
                    buttonStatus = bleViewModel.bleState.label,
                    buttonConnected = bleViewModel.bleState.isConnected,
                    recoveredExtractionProgress = recoveredExtractionProgress,
                    onPermissionsReady = callMonitor::startMonitoring,
                    onFavoriteRecoveredClip = clipsViewModel::favoriteRecoveredMarker
                )
                AppTab.CLIPS -> ClipsScreen(
                    sessions = sessions,
                    clipsViewModel = clipsViewModel,
                    onDeleteClip = clipsViewModel::deleteClip,
                    onRenameSession = clipsViewModel::renameSession
                )
                AppTab.DEVICE -> BLEDeviceScreen(
                    bleViewModel = bleViewModel,
                    onBack = null
                )
                AppTab.SETTINGS -> SettingsScreen(
                    cameraManager = cameraManager,
                    bleViewModel = bleViewModel,
                    clipsViewModel = clipsViewModel,
                    onReplayTutorial = { selectedTab = AppTab.RECORD; showGuidedTour = true }
                )
            }
        }
    }
    if (showGuidedTour && !showSplash) {
        GuidedTour(onTabChange = { selectedTab = it }, onFinish = {
            preferences.edit { putBoolean("has_seen_guided_tour", true) }
            showGuidedTour = false
            selectedTab = AppTab.RECORD
        })
    }
    if (showSplash) {
        Box(Modifier.fillMaxSize().background(Color.White), contentAlignment = Alignment.Center) {
            Image(
                painter = painterResource(R.drawable.clipit_launch),
                contentDescription = null,
                contentScale = ContentScale.Fit,
                modifier = Modifier.fillMaxSize()
            )
        }
    }
}
