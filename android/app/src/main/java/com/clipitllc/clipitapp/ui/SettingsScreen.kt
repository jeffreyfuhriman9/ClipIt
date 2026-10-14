package com.clipitllc.clipitapp.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.edit
import androidx.core.content.ContextCompat
import androidx.activity.compose.BackHandler
import androidx.compose.ui.platform.LocalContext
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipitllc.clipitapp.ble.BLEViewModel
import com.clipitllc.clipitapp.camera.CameraManager
import com.clipitllc.clipitapp.camera.VideoQualityOption
import com.clipitllc.clipitapp.ui.theme.CosmosBlue
import com.clipitllc.clipitapp.ui.theme.CrimsonBlaze
import com.clipitllc.clipitapp.ui.theme.GochujangRed
import com.clipitllc.clipitapp.ui.theme.BlueMarble

sealed class SettingsNavigation {
    object Main : SettingsNavigation()
    object BLE : SettingsNavigation()
    object About : SettingsNavigation()
    object FAQ : SettingsNavigation()
    object DeveloperNote : SettingsNavigation()
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    cameraManager: CameraManager,
    bleViewModel: BLEViewModel,
    clipsViewModel: ClipsViewModel,
    onReplayTutorial: () -> Unit
) {
    var navigationState by remember { mutableStateOf<SettingsNavigation>(SettingsNavigation.Main) }
    BackHandler(enabled = navigationState != SettingsNavigation.Main) {
        navigationState = when (navigationState) {
            SettingsNavigation.FAQ, SettingsNavigation.DeveloperNote -> SettingsNavigation.About
            else -> SettingsNavigation.Main
        }
    }

    AnimatedContent(
        targetState = navigationState,
        transitionSpec = {
            if (targetState == SettingsNavigation.Main) {
                slideInHorizontally { -it } + fadeIn() togetherWith slideOutHorizontally { it } + fadeOut()
            } else {
                slideInHorizontally { it } + fadeIn() togetherWith slideOutHorizontally { -it } + fadeOut()
            }
        },
        label = "SettingsNav"
    ) { state ->
        when (state) {
            SettingsNavigation.Main -> MainSettingsList(
                cameraManager = cameraManager,
                clipsViewModel = clipsViewModel,
                onNavigate = { navigationState = it }
            )
            SettingsNavigation.BLE -> BLEDeviceScreen(
                bleViewModel = bleViewModel,
                onBack = { navigationState = SettingsNavigation.Main }
            )
            SettingsNavigation.About -> AboutScreen(
                onNavigate = { navigationState = it },
                onBack = { navigationState = SettingsNavigation.Main },
                onReplayTutorial = { navigationState = SettingsNavigation.Main; onReplayTutorial() }
            )
            SettingsNavigation.FAQ -> FAQScreen(
                onBack = { navigationState = SettingsNavigation.About }
            )
            SettingsNavigation.DeveloperNote -> DeveloperNoteScreen(
                onBack = { navigationState = SettingsNavigation.About }
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MainSettingsList(
    cameraManager: CameraManager,
    clipsViewModel: ClipsViewModel,
    onNavigate: (SettingsNavigation) -> Unit
) {
    val context = LocalContext.current
    val preferences = remember { context.getSharedPreferences("clipit_settings", Context.MODE_PRIVATE) }
    var dimScreen by remember { mutableStateOf(preferences.getBoolean("dim_screen", false)) }
    var notificationsEnabled by remember { mutableStateOf(preferences.getBoolean("notifications_enabled", false)) }
    val notificationPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        notificationsEnabled = granted
        preferences.edit { putBoolean("notifications_enabled", granted) }
        clipsViewModel.scheduleRetention()
    }
    var retentionDays by remember { mutableIntStateOf(clipsViewModel.retentionDays()) }
    var showRetentionMenu by remember { mutableStateOf(false) }
    val bufferLength by cameraManager.bufferLengthSeconds.collectAsState()
    val currentQuality by cameraManager.currentQuality.collectAsState()
    val listState = rememberLazyListState()
    LaunchedEffect(TourTargets.activeTarget) {
        when (TourTargets.activeTarget) {
            TourTarget.RETENTION -> listState.animateScrollToItem(8)
            TourTarget.DIM_SCREEN -> listState.animateScrollToItem(3)
            else -> Unit
        }
    }

    Scaffold(
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            TopAppBar(
                title = { Text("Settings", fontWeight = FontWeight.Bold) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.White,
                    titleContentColor = CosmosBlue
                )
            )
        }
    ) { innerPadding ->
        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(Color(0xFFF2F2F7)) // iOS SystemGroupedBackground
        ) {
            item { SectionHeader("Recording") }
            item {
                SettingsRow(
                    icon = Icons.Default.Timer,
                    iconColor = CrimsonBlaze,
                    label = "ClipIt Highlight Length"
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        IconButton(onClick = { cameraManager.setBufferLength(bufferLength - 5) }, enabled = bufferLength > 5) {
                            Icon(Icons.Default.Remove, contentDescription = "Shorter highlight")
                        }
                        Text("${bufferLength}s", color = Color.Gray, fontSize = 14.sp)
                        IconButton(onClick = { cameraManager.setBufferLength(bufferLength + 5) }, enabled = bufferLength < 60) {
                            Icon(Icons.Default.Add, contentDescription = "Longer highlight")
                        }
                    }
                }
            }
            item {
                var showQualityMenu by remember { mutableStateOf(false) }
                SettingsRow(
                    icon = Icons.Default.VideoCameraBack,
                    iconColor = Color.Green,
                    label = "Video Quality",
                    onClick = { showQualityMenu = true }
                ) {
                    Box {
                        Text(currentQuality.label, color = Color.Gray, fontSize = 14.sp)
                        DropdownMenu(
                            expanded = showQualityMenu,
                            onDismissRequest = { showQualityMenu = false }
                        ) {
                            VideoQualityOption.entries.forEach { option ->
                                DropdownMenuItem(
                                    text = { Text(option.label) },
                                    onClick = {
                                        cameraManager.selectVideoQuality(option)
                                        showQualityMenu = false
                                    }
                                )
                            }
                        }
                    }
                }
            }
            item {
                SettingsRow(
                    icon = Icons.Default.BrightnessLow,
                    iconColor = Color(0xFFFF9500),
                    label = "Dim Screen While Recording",
                    modifier = Modifier.tourTarget(TourTarget.DIM_SCREEN)
                ) {
                    Switch(checked = dimScreen, onCheckedChange = {
                        dimScreen = it
                        preferences.edit { putBoolean("dim_screen", it) }
                    })
                }
            }

            item { SectionHeader("Notifications") }
            item {
                SettingsRow(icon = Icons.Default.NotificationsActive, iconColor = CrimsonBlaze, label = "Notifications") {
                    Switch(checked = notificationsEnabled, onCheckedChange = { enabled ->
                        if (enabled && Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        } else {
                            notificationsEnabled = enabled
                            preferences.edit { putBoolean("notifications_enabled", enabled) }
                            clipsViewModel.scheduleRetention()
                        }
                    })
                }
            }
            item { SectionHeader("Storage") }
            item {
                SettingsRow(icon = Icons.Default.Storage, iconColor = CosmosBlue, label = "Storage Used") {
                    Text(android.text.format.Formatter.formatShortFileSize(context, clipsViewModel.storageUsedBytes()), color = Color.Gray, fontSize = 14.sp)
                }
            }
            item {
                SettingsRow(icon = Icons.Default.DeleteOutline, iconColor = Color.Gray,
                    label = "Delete Original Videos", modifier = Modifier.tourTarget(TourTarget.RETENTION)) {
                    Box {
                        TextButton(onClick = { showRetentionMenu = true }) {
                            Text(if (retentionDays == 0) "Never" else "After $retentionDays ${if (retentionDays == 1) "day" else "days"}")
                        }
                        DropdownMenu(expanded = showRetentionMenu, onDismissRequest = { showRetentionMenu = false }) {
                            listOf(0, 1, 3, 7, 14, 30).forEach { days ->
                                DropdownMenuItem(text = { Text(if (days == 0) "Never" else "After $days ${if (days == 1) "day" else "days"}") }, onClick = {
                                    retentionDays = days
                                    clipsViewModel.setRetentionDays(days)
                                    showRetentionMenu = false
                                })
                            }
                        }
                    }
                }
            }

            item { SectionHeader("Bluetooth") }
            item {
                SettingsRow(
                    icon = Icons.Default.Bluetooth,
                    iconColor = GochujangRed,
                    label = "ClipIt Button",
                    onClick = { onNavigate(SettingsNavigation.BLE) }
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Configure", color = Color.Gray, fontSize = 14.sp)
                        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = Color.LightGray)
                    }
                }
            }

            item { SectionHeader("Account") }
            item {
                SettingsRow(icon = Icons.Default.Star, iconColor = Color(0xFFAF52DE), label = "Subscription") {
                    Text("Free", color = Color.Gray, fontSize = 14.sp)
                }
            }
            item {
                SettingsRow(icon = Icons.Default.Cloud, iconColor = BlueMarble, label = "Cloud Storage") {
                    Text("Coming soon...", color = Color.Gray, fontSize = 14.sp)
                }
            }
            item { SectionHeader("About") }
            item {
                SettingsRow(
                    icon = Icons.Default.Info,
                    iconColor = CosmosBlue,
                    label = "About",
                    onClick = { onNavigate(SettingsNavigation.About) }
                ) {
                    Icon(Icons.Default.ChevronRight, contentDescription = null, tint = Color.LightGray)
                }
            }

            item {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 24.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        "2026 ClipIt LLC • Version 1.0",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.Gray
                    )
                }
            }
        }
    }
}

@Composable
fun SectionHeader(title: String) {
    Text(
        text = title.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        color = Color.Gray,
        modifier = Modifier.padding(start = 16.dp, top = 24.dp, bottom = 8.dp)
    )
}

@Composable
fun SettingsRow(
    icon: ImageVector,
    iconColor: Color,
    label: String,
    onClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    trailing: @Composable () -> Unit = {}
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .clickable(enabled = onClick != null) { onClick?.invoke() },
        color = Color.White
    ) {
        Box {
            Row(
                modifier = Modifier
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Surface(
                    color = iconColor,
                    shape = RoundedCornerShape(7.dp),
                    modifier = Modifier.size(28.dp)
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(
                            imageVector = icon,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
                Text(text = label, style = MaterialTheme.typography.bodyMedium)
                Spacer(modifier = Modifier.weight(1f))
                trailing()
            }
            HorizontalDivider(
                modifier = Modifier
                    .padding(start = 56.dp)
                    .align(Alignment.BottomStart),
                color = Color(0xFFC6C6C8),
                thickness = 0.5.dp
            )
        }
    }
}
