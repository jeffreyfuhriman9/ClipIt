package com.clipitllc.clipitapp.ui

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.os.Build
import android.view.Surface
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.tooling.preview.Preview
import androidx.camera.view.PreviewView
import androidx.compose.animation.*
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.clipitllc.clipitapp.camera.CameraEvent
import com.clipitllc.clipitapp.camera.CameraManager
import com.clipitllc.clipitapp.camera.VideoQualityOption
import com.clipitllc.clipitapp.ui.theme.BlueMarble
import com.clipitllc.clipitapp.ui.theme.CosmosBlue
import com.clipitllc.clipitapp.ui.theme.CrimsonBlaze
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.TimeUnit

private data class ClipSavedConfirmation(
    val clipNumber: Int,
    val ordinaryIndex: Int? = null,
    val recoveryKey: String? = null,
    val isFavorite: Boolean = false
)

@Composable
fun CameraScreen(
    cameraManager: CameraManager? = null,
    buttonStatus: String = "Disconnected",
    buttonConnected: Boolean = false,
    recoveredExtractionProgress: RecoveredExtractionProgress? = null,
    onPermissionsReady: () -> Unit = {},
    onFavoriteRecoveredClip: (String) -> Boolean = { false }
) {
    val context = LocalContext.current
    val cameraManager = cameraManager ?: remember(context) { CameraManager(context) }
    val lifecycleOwner = LocalLifecycleOwner.current

    KeepScreenAwake()

    var hasPermissions by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED &&
                    ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        )
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        hasPermissions = permissions[Manifest.permission.CAMERA] == true &&
                permissions[Manifest.permission.RECORD_AUDIO] == true
    }

    LaunchedEffect(Unit) {
        if (!hasPermissions) {
            permissionLauncher.launch(
                arrayOf(
                    Manifest.permission.CAMERA,
                    Manifest.permission.RECORD_AUDIO,
                    Manifest.permission.READ_PHONE_STATE
                )
            )
        }
    }

    if (!hasPermissions) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("Camera and microphone access are required to record.")
        }
        return
    }
    LaunchedEffect(hasPermissions) { onPermissionsReady() }

    // Permission-dependent states and effects
    val isRecording by cameraManager.isRecording.collectAsState()
    val activity = context as? Activity
    DisposableEffect(isRecording, activity) {
        val window = activity?.window
        val originalBrightness = window?.attributes?.screenBrightness ?: -1f
        if (isRecording && context.getSharedPreferences("clipit_settings", Context.MODE_PRIVATE).getBoolean("dim_screen", false)) {
            window?.attributes = window?.attributes?.also { it.screenBrightness = 0.08f }
        }
        onDispose {
            window?.attributes = window?.attributes?.also { it.screenBrightness = originalBrightness }
        }
    }
    val isExtracting by cameraManager.isExtracting.collectAsState()
    val bufferLength by cameraManager.bufferLengthSeconds.collectAsState()
    val currentQuality by cameraManager.currentQuality.collectAsState()
    val zoomRatio by cameraManager.zoomRatio.collectAsState()
    val currentZoomRatio by rememberUpdatedState(zoomRatio)
    val minZoom by cameraManager.minZoom.collectAsState()
    val maxZoom by cameraManager.maxZoom.collectAsState()
    val currentMinZoom by rememberUpdatedState(minZoom)
    val currentMaxZoom by rememberUpdatedState(maxZoom)
    val isFrontCamera by cameraManager.isFrontCamera.collectAsState()
    val isLandscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
    val displayRotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        context.display?.rotation
    } else {
        @Suppress("DEPRECATION")
        (context as? Activity)?.windowManager?.defaultDisplay?.rotation
    }
    // Landscape left on iOS puts Record by the charging port at screen right.
    val controlsOnLeft = displayRotation == Surface.ROTATION_270

    var showSettings by remember { mutableStateOf(false) }
    val extractionProgress by cameraManager.extractionProgress.collectAsState()
    var recordingTimer by remember { mutableLongStateOf(0L) }
    var clipSavedConfirmation by remember { mutableStateOf<ClipSavedConfirmation?>(null) }
    var clipSavedCount by remember { mutableIntStateOf(0) }
    var previewView: PreviewView? by remember { mutableStateOf(null) }
    var focusPoint by remember { mutableStateOf<Offset?>(null) }
    var focusSequence by remember { mutableIntStateOf(0) }
    val focusScale = remember { Animatable(1.3f) }
    val focusOpacity = remember { Animatable(0f) }

    LaunchedEffect(focusSequence) {
        if (focusSequence == 0) return@LaunchedEffect
        focusScale.snapTo(1.3f)
        focusOpacity.snapTo(0f)
        launch { focusScale.animateTo(1f, spring(dampingRatio = 0.65f, stiffness = 630f)) }
        focusOpacity.animateTo(1f, tween(100))
        delay(1_100)
        focusOpacity.animateTo(0f, tween(300))
    }

    LaunchedEffect(clipSavedConfirmation?.clipNumber) {
        if (clipSavedConfirmation != null) {
            delay(5_000)
            clipSavedConfirmation = null
        }
    }
    
    LaunchedEffect(isRecording) {
        if (isRecording) {
            clipSavedConfirmation = null
            clipSavedCount = 0
            val startTime = System.currentTimeMillis()
            while (true) {
                recordingTimer = System.currentTimeMillis() - startTime
                delay(1000)
            }
        } else {
            recordingTimer = 0L
        }
    }

    LaunchedEffect(Unit) {
        cameraManager.events.collect { event ->
            when (event) {
                is CameraEvent.ExtractionProgress -> Unit
                is CameraEvent.HighlightMarked -> {
                    clipSavedCount = maxOf(clipSavedCount + 1, event.highlightIndex)
                    clipSavedConfirmation = ClipSavedConfirmation(clipSavedCount, ordinaryIndex = event.highlightIndex)
                }
                is CameraEvent.RecoveredHighlightMarked -> {
                    clipSavedCount += 1
                    clipSavedConfirmation = ClipSavedConfirmation(clipSavedCount, recoveryKey = event.recoveryKey)
                }
                else -> {}
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        AndroidView(
            factory = { ctx ->
                PreviewView(ctx).also { view ->
                    previewView = view
                    cameraManager.startCamera(lifecycleOwner, view)
                }
            },
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    detectTapGestures { offset ->
                        focusPoint = offset
                        focusSequence++
                        previewView?.let { view ->
                            cameraManager.focusAndExpose(view, offset.x, offset.y)
                        }
                    }
                }
                .pointerInput(Unit) {
                    detectTransformGestures { _, _, zoomChange, _ ->
                        if (zoomChange != 1f) {
                            cameraManager.setZoomRatio((currentZoomRatio * zoomChange).coerceIn(currentMinZoom, currentMaxZoom))
                        }
                    }
                }
        )

        // Gradient Shadows
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        colors = listOf(
                            Color.Black.copy(alpha = 0.24f),
                            Color.Transparent,
                            Color.Black.copy(alpha = 0.42f)
                        )
                    )
                )
        )

        CameraLevelIndicator(isLandscape,
            modifier = Modifier.align(Alignment.Center))

        // Top Overlay
        TopOverlayView(
            isRecording = isRecording,
            bufferLength = bufferLength,
            recordingTimer = recordingTimer,
            buttonStatus = buttonStatus,
            buttonConnected = buttonConnected,
            isLandscape = isLandscape,
            controlsOnLeft = controlsOnLeft
        )

        // Buttons Overlay
        Box(
            modifier = Modifier
                .fillMaxSize()
                .then(if (isLandscape) Modifier.navigationBarsPadding() else Modifier.padding(bottom = 150.dp))
        ) {
            // iOS places the highlight-length control beside the recording controls.
            IconButton(
                onClick = { showSettings = !showSettings },
                modifier = Modifier
                    .align(if (isLandscape && !controlsOnLeft) Alignment.TopEnd else if (isLandscape) Alignment.TopStart else Alignment.BottomStart)
                    .padding(start = if (isLandscape && !controlsOnLeft) 0.dp else 24.dp,
                        end = if (isLandscape && !controlsOnLeft) 36.dp else 0.dp,
                        top = if (isLandscape) 280.dp else 0.dp)
                    .size(54.dp)
                    .background(CrimsonBlaze.copy(alpha = 0.75f), CircleShape)
                    .border(1.dp, Color.White.copy(alpha = 0.25f), CircleShape)
                    .tourTarget(TourTarget.TIMING)
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Default.History, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                    Text("${bufferLength}s", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                }
            }

            val flipCamera = { previewView?.let { cameraManager.flipCamera(lifecycleOwner, it) }; Unit }
            val changeZoom = { ratio: Float -> cameraManager.setZoomRatio(ratio) }
            if (isLandscape) {
                Row(
                    modifier = Modifier
                        .align(if (controlsOnLeft) Alignment.TopStart else Alignment.TopEnd)
                        .padding(horizontal = 36.dp, vertical = 24.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    if (controlsOnLeft) {
                        CameraFlipControl(isFrontCamera, !isRecording, flipCamera)
                        CameraZoomControl(zoomRatio, minZoom, maxZoom, changeZoom)
                    } else {
                        CameraZoomControl(zoomRatio, minZoom, maxZoom, changeZoom)
                        CameraFlipControl(isFrontCamera, !isRecording, flipCamera)
                    }
                }
            } else {
                CameraFlipControl(isFrontCamera, !isRecording, flipCamera,
                    Modifier.align(Alignment.TopEnd).padding(end = 16.dp, top = 45.dp))
            }

            // Record & ClipIt Control Group
            val recordClick = { if (isRecording) cameraManager.stopRecording() else cameraManager.startRecording() }
            if (isLandscape) {
                Box(
                    modifier = Modifier
                        .align(if (controlsOnLeft) Alignment.CenterStart else Alignment.CenterEnd)
                        .padding(start = if (controlsOnLeft) 45.dp else 0.dp,
                            end = if (controlsOnLeft) 0.dp else 45.dp)
                        .size(80.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Box(Modifier.requiredSize(125.dp).offset(x = if (controlsOnLeft) 120.dp else (-120).dp)) {
                        ClipItButton(isRecording) { cameraManager.markHighlight() }
                    }
                    RecordButton(isRecording = isRecording, onClick = recordClick)
                }
            } else {
                Column(
                    modifier = Modifier.align(Alignment.BottomCenter),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    ClipItButton(isRecording) { cameraManager.markHighlight() }
                    RecordButton(isRecording = isRecording, onClick = recordClick)
                }
            }

            // Zoom Control
            if (!isLandscape) CameraZoomControl(zoomRatio, minZoom, maxZoom, changeZoom,
                Modifier.align(Alignment.BottomEnd).padding(end = 30.dp))
        }

        focusPoint?.let { point ->
            val halfSizePx = with(LocalDensity.current) { 35.dp.roundToPx() }
            FocusIndicator(
                modifier = Modifier.offset {
                    IntOffset(point.x.toInt() - halfSizePx, point.y.toInt() - halfSizePx)
                }.graphicsLayer {
                    scaleX = focusScale.value
                    scaleY = focusScale.value
                    alpha = focusOpacity.value
                }
            )
        }

        // Settings Panel
        AnimatedVisibility(
            visible = showSettings,
            enter = slideInVertically(initialOffsetY = { it }) + fadeIn(),
            exit = slideOutVertically(targetOffsetY = { it }) + fadeOut(),
            modifier = Modifier.align(Alignment.Center)
        ) {
            SettingsPanel(
                bufferLength = bufferLength,
                currentQuality = currentQuality,
                onBufferLengthChange = { cameraManager.setBufferLength(it) },
                onQualityChange = { quality -> previewView?.let { cameraManager.setVideoQuality(quality, lifecycleOwner, it) } },
                onClose = { showSettings = false }
            )
        }

        // Clip Saved Banner
        Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            val confirmation = clipSavedConfirmation
            AnimatedVisibility(
                visible = confirmation != null,
                enter = fadeIn(animationSpec = tween(200)),
                exit = fadeOut(animationSpec = tween(500))
            ) {
                if (confirmation != null) {
                    Surface(
                        color = Color.White.copy(alpha = 0.88f),
                        shape = CircleShape,
                        shadowElevation = 10.dp,
                        modifier = Modifier.padding(horizontal = 24.dp)
                    ) {
                        Row(
                            modifier = Modifier.padding(horizontal = 22.dp, vertical = 24.dp),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "Clip #${confirmation.clipNumber} saved!",
                                color = CrimsonBlaze,
                                fontSize = 20.sp,
                                fontWeight = FontWeight.Black,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            IconButton(
                                onClick = {
                                    val saved = confirmation.recoveryKey?.let(onFavoriteRecoveredClip)
                                        ?: confirmation.ordinaryIndex?.let {
                                            cameraManager.favoriteHighlight(it)
                                            true
                                        } ?: false
                                    if (saved) clipSavedConfirmation = confirmation.copy(isFavorite = true)
                                },
                                modifier = Modifier.size(32.dp)
                            ) {
                                Icon(
                                    imageVector = if (confirmation.isFavorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                                    contentDescription = if (confirmation.isFavorite) "Clip favorited" else "Favorite clip",
                                    tint = CrimsonBlaze,
                                    modifier = Modifier.size(24.dp)
                                )
                            }
                        }
                    }
                }
            }
        }

        // Extraction Progress Overlay
        if (isExtracting || recoveredExtractionProgress != null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.65f)),
                contentAlignment = Alignment.Center
            ) {
                ExtractionProgressView(
                    current = if (isExtracting) extractionProgress.first else recoveredExtractionProgress?.current ?: 0,
                    total = if (isExtracting) extractionProgress.second else recoveredExtractionProgress?.total ?: 0
                )
            }
        }
    }
}

@Composable
private fun FocusIndicator(modifier: Modifier = Modifier) {
    val red = Color(0xFFAE1F23)
    Box(modifier.size(70.dp).border(1.2.dp, red, RoundedCornerShape(6.dp))) {
        Box(Modifier.align(Alignment.TopCenter).width(1.5.dp).height(7.dp).background(red))
        Box(Modifier.align(Alignment.BottomCenter).width(1.5.dp).height(7.dp).background(red))
        Box(Modifier.align(Alignment.CenterStart).width(7.dp).height(1.5.dp).background(red))
        Box(Modifier.align(Alignment.CenterEnd).width(7.dp).height(1.5.dp).background(red))
    }
}

@Composable
private fun CameraFlipControl(
    isFrontCamera: Boolean,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    IconButton(onClick = onClick, enabled = enabled,
        modifier = modifier.size(54.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape)
            .border(0.8.dp, Color.White.copy(alpha = 0.25f), CircleShape)) {
        Icon(Icons.Default.Cameraswitch,
            contentDescription = if (isFrontCamera) "Switch to back camera" else "Switch to front camera",
            tint = Color.White)
    }
}

@Composable
private fun CameraZoomControl(
    zoomRatio: Float,
    minZoom: Float,
    maxZoom: Float,
    onZoomChange: (Float) -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier
            .pointerInput(zoomRatio, minZoom, maxZoom) {
                detectDragGesturesAfterLongPress { change, dragAmount ->
                    change.consume()
                    onZoomChange(zoomRatio - dragAmount.y / 100f)
                }
            }
            .clickable {
                val next = listOf(0.5f, 1f, 2f, 3f, 5f)
                    .firstOrNull { it > zoomRatio + 0.05f && it <= maxZoom } ?: minZoom
                onZoomChange(next)
            },
        color = Color.Black.copy(alpha = 0.45f),
        shape = CircleShape,
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.25f))
    ) {
        Text(String.format(LocalConfiguration.current.locales[0], "%.1fx", zoomRatio),
            color = Color.White,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
            style = MaterialTheme.typography.labelMedium)
    }
}

@Composable
fun TopOverlayView(isRecording: Boolean, bufferLength: Int, recordingTimer: Long, buttonStatus: String, buttonConnected: Boolean, isLandscape: Boolean, controlsOnLeft: Boolean) {
    val minutes = (recordingTimer / 1000) / 60
    val seconds = (recordingTimer / 1000) % 60
    val timerText = String.format(LocalConfiguration.current.locales[0], "%02d:%02d", minutes, seconds)

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = if (isLandscape) 24.dp else 45.dp)
            .padding(horizontal = if (isLandscape) 36.dp else 16.dp)
    ) {
        Surface(
            modifier = Modifier.align(if (isLandscape && controlsOnLeft) Alignment.TopEnd else Alignment.TopStart),
            color = Color.Black.copy(alpha = 0.35f),
            shape = CircleShape
        ) {
            Row(
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)
            ) {
                Box(
                    modifier = Modifier.size(7.dp).background(
                        if (buttonConnected) Color.Green else CrimsonBlaze,
                        CircleShape
                    )
                )
                Text(
                    text = if (buttonConnected) "ClipIt Button\nConnected" else "ClipIt Button\nDisconnected",
                    color = Color.White,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    lineHeight = 15.sp,
                    textAlign = TextAlign.Center
                )
            }
        }

        if (isRecording) {
            Surface(
                modifier = Modifier.align(Alignment.TopCenter).padding(top = 12.dp),
                color = Color.Black.copy(alpha = 0.35f),
                shape = CircleShape
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Box(modifier = Modifier.size(8.dp).background(CrimsonBlaze, CircleShape))
                    Text(
                        timerText,
                        color = Color.White,
                        style = MaterialTheme.typography.labelMedium.copy(fontWeight = FontWeight.Bold)
                    )
                }
            }
        }
    }
}

@Composable
private fun ClipItButton(isRecording: Boolean, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        enabled = isRecording,
        shape = CircleShape,
        modifier = Modifier.size(125.dp).border(2.dp, Color.White.copy(alpha = if (isRecording) 0.4f else 0.2f), CircleShape)
            .tourTarget(TourTarget.CLIP_IT),
        colors = ButtonDefaults.buttonColors(containerColor = CrimsonBlaze,
            disabledContainerColor = Color.White.copy(alpha = 0.2f)),
        elevation = ButtonDefaults.buttonElevation(defaultElevation = 8.dp)
    ) {
        Text("ClipIt", color = Color.White.copy(alpha = if (isRecording) 1f else 0.5f), fontWeight = FontWeight.Bold, fontSize = 20.sp)
    }
}

@Composable
fun RecordButton(isRecording: Boolean, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .size(76.dp)
            .border(4.dp, Color.White, CircleShape)
            .padding(4.dp)
            .tourTarget(TourTarget.RECORD)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick
            ),
        contentAlignment = Alignment.Center
    ) {
        val shape = if (isRecording) RoundedCornerShape(8.dp) else CircleShape
        val size = if (isRecording) 32.dp else 62.dp
        
        Box(
            modifier = Modifier
                .size(size)
                .background(CrimsonBlaze, shape)
        )
    }
}

@Composable
fun SettingsPanel(
    bufferLength: Int,
    currentQuality: VideoQualityOption,
    onBufferLengthChange: (Int) -> Unit,
    onQualityChange: (VideoQualityOption) -> Unit,
    onClose: () -> Unit
) {
    var qualityMenuExpanded by remember { mutableStateOf(false) }
    Surface(
        modifier = Modifier
            .widthIn(max = 380.dp)
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        color = Color.Black.copy(alpha = 0.82f),
        shape = RoundedCornerShape(18.dp)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text("ClipIt Highlight Length", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 15.sp)
                TextButton(onClick = onClose) { Text("Done", color = Color.White) }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Slider(
                    value = bufferLength.toFloat(),
                    onValueChange = { onBufferLengthChange((it / 5).toInt() * 5) },
                    valueRange = 5f..60f,
                    steps = 10,
                    colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = CrimsonBlaze, inactiveTrackColor = Color.White.copy(alpha = 0.12f))
                )
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(5, 10, 15, 20, 30, 60).forEach { option ->
                        val isSelected = bufferLength == option
                        Surface(
                            onClick = { onBufferLengthChange(option) },
                            modifier = Modifier.weight(1f),
                            color = if (isSelected) CrimsonBlaze else CrimsonBlaze.copy(alpha = 0.25f),
                            shape = CircleShape
                        ) {
                            Text("${option}s", color = Color.White, modifier = Modifier.padding(vertical = 7.dp), textAlign = TextAlign.Center, fontSize = 12.sp)
                        }
                    }
                }
            }
            Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Video Quality", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                Box {
                    Surface(onClick = { qualityMenuExpanded = true }, color = Color.White.copy(alpha = 0.15f), shape = CircleShape) {
                        Text(currentQuality.label, color = Color.White, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp), fontSize = 12.sp)
                    }
                    DropdownMenu(expanded = qualityMenuExpanded, onDismissRequest = { qualityMenuExpanded = false }) {
                        VideoQualityOption.entries.forEach { quality ->
                            DropdownMenuItem(text = { Text(quality.label) }, onClick = {
                                onQualityChange(quality)
                                qualityMenuExpanded = false
                            })
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ExtractionProgressView(current: Int, total: Int) {
    Surface(
        modifier = Modifier.width(280.dp),
        color = Color(0xFF1E1E1E),
        shape = RoundedCornerShape(24.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.1f))
    ) {
        Column(
            modifier = Modifier.padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            Icon(
                Icons.Default.Movie,
                contentDescription = null,
                modifier = Modifier.size(48.dp),
                tint = CrimsonBlaze
            )
            
            Text(
                "Saving Your Clips!",
                color = Color.White,
                fontWeight = FontWeight.Bold,
                fontSize = 18.sp
            )
            
            Text(
                "Extracting highlight $current of $total...",
                color = Color.White.copy(alpha = 0.8f),
                fontSize = 14.sp
            )
            
            LinearProgressIndicator(
                progress = { current.toFloat() / total.toFloat() },
                modifier = Modifier.fillMaxWidth().height(8.dp).clip(CircleShape),
                color = CrimsonBlaze,
                trackColor = Color.White.copy(alpha = 0.1f)
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
fun CameraScreenPreview() {
    MaterialTheme {
        CameraScreen(cameraManager = null)
    }
}
