package com.clipitllc.clipitapp.ui

import android.content.Intent
import android.view.LayoutInflater
import android.widget.FrameLayout
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import androidx.core.content.FileProvider
import java.io.File
import androidx.core.net.toUri
import androidx.compose.animation.*
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateOffsetAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.ui.PlayerView
import com.clipitllc.clipitapp.R
import com.clipitllc.clipitapp.ui.theme.BlueMarble
import com.clipitllc.clipitapp.ui.theme.CosmosBlue
import com.clipitllc.clipitapp.ui.theme.CrimsonBlaze
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt
import kotlin.math.hypot

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ClipPagerDialog(
    clips: List<Clip>,
    originalPath: String?,
    initialClipId: String,
    onDismiss: () -> Unit,
    onDelete: (Clip) -> Unit,
    onRename: (Clip, String) -> Unit,
    onFavoriteToggle: (Clip) -> Unit,
    onTrim: (Clip, Long, Long, Boolean, (Boolean) -> Unit) -> Unit
) {
    val initialIndex = clips.indexOfFirst { it.id == initialClipId }.coerceAtLeast(0)
    val pagerState = rememberPagerState(initialPage = initialIndex) { clips.size }
    var zoomLocked by remember { mutableStateOf(false) }
    LaunchedEffect(pagerState.currentPage) { zoomLocked = false }
    
    var dragOffsetY by remember { mutableFloatStateOf(0f) }
    val backdropOpacity by remember {
        derivedStateOf { (1f - (dragOffsetY / 1000f).coerceIn(0f, 0.8f)) }
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false)
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = backdropOpacity))
                .pointerInput(zoomLocked) {
                    if (zoomLocked) return@pointerInput
                    detectVerticalDragGestures(
                        onVerticalDrag = { change, dragAmount ->
                            change.consume()
                            dragOffsetY += dragAmount
                        },
                        onDragEnd = {
                            if (dragOffsetY > 300f) {
                                onDismiss()
                            } else {
                                dragOffsetY = 0f
                            }
                        }
                    )
                }
                .offset { IntOffset(0, dragOffsetY.roundToInt().coerceAtLeast(0)) }
        ) {
            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxSize(),
                pageSpacing = 16.dp,
                userScrollEnabled = !zoomLocked
            ) { page ->
                ClipPlayerView(
                    clip = clips[page],
                    originalPath = originalPath,
                    isActive = pagerState.currentPage == page,
                    onZoomLockChanged = { if (pagerState.currentPage == page) zoomLocked = it },
                    onDismiss = onDismiss,
                    onDelete = { onDelete(clips[page]) },
                    onRename = { onRename(clips[page], it) },
                    onFavoriteToggle = { onFavoriteToggle(clips[page]) },
                    onTrim = { start, end, asNewClip, done -> onTrim(clips[page], start, end, asNewClip, done) }
                )
            }
        }
    }
}

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun ClipPlayerView(
    clip: Clip,
    originalPath: String?,
    isActive: Boolean,
    onZoomLockChanged: (Boolean) -> Unit,
    onDismiss: () -> Unit,
    onDelete: () -> Unit,
    onRename: (String) -> Unit,
    onFavoriteToggle: () -> Unit,
    onTrim: (Long, Long, Boolean, (Boolean) -> Unit) -> Unit
) {
    val context = LocalContext.current
    var showUI by remember { mutableStateOf(true) }
    var playbackRate by remember { mutableFloatStateOf(1.0f) }
    var showTrimEditor by remember { mutableStateOf(false) }
    var showRenameDialog by remember { mutableStateOf(false) }
    var showDeleteConfirmation by remember { mutableStateOf(false) }
    var showTrimError by remember { mutableStateOf(false) }
    var showEditUnavailable by remember { mutableStateOf(false) }
    var positionMs by remember { mutableLongStateOf(0L) }
    var durationMs by remember { mutableLongStateOf(0L) }
    var isPlaying by remember { mutableStateOf(false) }
    var isMuted by remember { mutableStateOf(false) }
    var isScrubbing by remember { mutableStateOf(false) }
    var scrubFraction by remember { mutableFloatStateOf(0f) }
    var wasPlayingBeforeScrub by remember { mutableStateOf(false) }
    var zoomScale by remember(clip.id) { mutableFloatStateOf(1f) }
    var zoomOffset by remember(clip.id) { mutableStateOf(Offset.Zero) }
    var animateZoom by remember(clip.id) { mutableStateOf(false) }
    val displayedScaleState = animateFloatAsState(zoomScale,
        animationSpec = if (animateZoom) spring(dampingRatio = 0.86f, stiffness = 620f) else snap(),
        label = "Clip zoom scale")
    val displayedOffsetState = animateOffsetAsState(zoomOffset,
        animationSpec = if (animateZoom) spring(dampingRatio = 0.86f, stiffness = 620f) else snap(),
        label = "Clip zoom position")
    var viewportSize by remember { mutableStateOf(IntSize.Zero) }
    var scrubFrame by remember(clip.id) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(isActive) {
        if (!isActive) {
            zoomScale = 1f
            zoomOffset = Offset.Zero
            animateZoom = false
            onZoomLockChanged(false)
        }
    }
    
    val exoPlayer = remember {
        ExoPlayer.Builder(context).build().apply {
            repeatMode = Player.REPEAT_MODE_OFF
            setSeekParameters(SeekParameters.EXACT)
        }
    }

    LaunchedEffect(clip.filePath, isActive) {
        if (isActive && !clip.filePath.isNullOrEmpty()) {
            val mediaItem = MediaItem.fromUri(clip.filePath.toUri())
            exoPlayer.setMediaItem(mediaItem)
            exoPlayer.prepare()
            exoPlayer.playWhenReady = true
            exoPlayer.setPlaybackSpeed(playbackRate)
        } else {
            exoPlayer.pause()
        }
    }
    LaunchedEffect(showTrimEditor) {
        if (showTrimEditor) {
            exoPlayer.pause()
        } else if (isActive && exoPlayer.mediaItemCount > 0) {
            exoPlayer.seekTo(0)
            exoPlayer.prepare()
        }
    }

    DisposableEffect(Unit) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED) {
                    exoPlayer.pause()
                    exoPlayer.seekTo(0)
                    positionMs = 0L
                    isPlaying = false
                }
            }
        }
        exoPlayer.addListener(listener)
        onDispose { exoPlayer.removeListener(listener); exoPlayer.release() }
    }

    LaunchedEffect(exoPlayer, isActive) {
        while (isActive) {
            if (!isScrubbing) positionMs = exoPlayer.currentPosition.coerceAtLeast(0L)
            durationMs = exoPlayer.duration.coerceAtLeast(0L)
            isPlaying = exoPlayer.isPlaying
            delay(150)
        }
    }

    LaunchedEffect(isScrubbing, clip.filePath) {
        val path = clip.filePath
        if (isScrubbing && !path.isNullOrEmpty()) {
            while (true) {
                val target = positionMs
                val frame = withContext(Dispatchers.IO) {
                    runCatching {
                        val retriever = MediaMetadataRetriever()
                        try {
                            retriever.setDataSource(context, path.toUri())
                            retriever.getFrameAtTime(target * 1000L, MediaMetadataRetriever.OPTION_CLOSEST)
                        } finally {
                            retriever.release()
                        }
                    }.getOrNull()
                }
                if (frame != null) scrubFrame = frame
                delay(50)
            }
        } else {
            scrubFrame = null
        }
    }

    val themeColor = when {
        clip.isReel -> BlueMarble
        clip.highlightIndex != null -> CrimsonBlaze
        else -> CosmosBlue
    }

    Box(modifier = Modifier.fillMaxSize().clipToBounds()) {
        if (!showTrimEditor) AndroidView(
            factory = { ctx ->
                (LayoutInflater.from(ctx).inflate(R.layout.zoomable_player_view, FrameLayout(ctx), false) as PlayerView).apply {
                    player = exoPlayer
                    useController = false
                }
            },
            update = { view ->
                // Read animation states inside AndroidView.update so Compose reruns this
                // callback on every frame. Transform the player container, as UIKit
                // transforms its videoView, rather than Media3's managed TextureView.
                val displayedScale = displayedScaleState.value
                val displayedOffset = displayedOffsetState.value
                view.scaleX = displayedScale.takeIf { it.isFinite() && it > 0f } ?: 1f
                view.scaleY = view.scaleX
                view.translationX = displayedOffset.x.takeIf { it.isFinite() } ?: 0f
                view.translationY = displayedOffset.y.takeIf { it.isFinite() } ?: 0f
            },
            modifier = Modifier.fillMaxSize()
        )

        // Compose must own the touch target. PlayerView consumes native touch events
        // before pointerInput on AndroidView can observe a double tap or pinch.
        if (!showTrimEditor) Box(
            modifier = Modifier.fillMaxSize()
                .onSizeChanged { viewportSize = it }
                .pointerInput(isActive) {
                    if (!isActive) return@pointerInput
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        var pinching = false
                        var startFrame = PlayerZoomMath.Frame(1f, PlayerZoomMath.Point(0f, 0f))
                        var startFocus = PlayerZoomMath.Point(0f, 0f)
                        var startDistance = 1f
                        var lastPanPoint: Offset? = null
                        fun aspect(): Float {
                            val video = exoPlayer.videoSize
                            val width = video.width.toFloat() * video.pixelWidthHeightRatio
                            return if (video.height > 0) width / video.height else 0f
                        }
                        fun centered(point: Offset) = PlayerZoomMath.Point(
                            point.x - viewportSize.width / 2f, point.y - viewportSize.height / 2f)
                        fun apply(frame: PlayerZoomMath.Frame) {
                            val bounded = PlayerZoomMath.clamp(frame, viewportSize.width.toFloat(),
                                viewportSize.height.toFloat(), aspect())
                            zoomScale = bounded.scale
                            zoomOffset = Offset(bounded.translation.x, bounded.translation.y)
                        }
                        do {
                            val event = awaitPointerEvent()
                            val pressed = event.changes.filter { it.pressed }
                            if (pressed.size >= 2) {
                                val first = pressed[0].position
                                val second = pressed[1].position
                                val center = (first + second) / 2f
                                val distance = hypot(first.x - second.x, first.y - second.y).coerceAtLeast(1f)
                                if (!pinching) {
                                    pinching = true
                                    animateZoom = false
                                    zoomScale = displayedScaleState.value
                                    zoomOffset = displayedOffsetState.value
                                    startFrame = PlayerZoomMath.Frame(zoomScale,
                                        PlayerZoomMath.Point(zoomOffset.x, zoomOffset.y))
                                    startFocus = centered(center)
                                    startDistance = distance
                                    onZoomLockChanged(true)
                                } else {
                                    apply(PlayerZoomMath.focusedPinch(startFrame, startFocus,
                                        centered(center), startFrame.scale * distance / startDistance))
                                }
                                lastPanPoint = null
                                event.changes.forEach { it.consume() }
                            } else if (pinching) {
                                pinching = false
                                if (zoomScale <= 1.05f) {
                                    animateZoom = true
                                    zoomScale = 1f
                                    zoomOffset = Offset.Zero
                                } else {
                                    animateZoom = false
                                    apply(PlayerZoomMath.Frame(zoomScale.coerceAtMost(5f),
                                        PlayerZoomMath.Point(zoomOffset.x, zoomOffset.y)))
                                }
                                onZoomLockChanged(zoomScale > 1.01f)
                                lastPanPoint = pressed.firstOrNull()?.position
                                event.changes.forEach { it.consume() }
                            } else if (pressed.size == 1 && zoomScale > 1.01f) {
                                val current = pressed[0].position
                                val previous = lastPanPoint ?: current
                                animateZoom = false
                                apply(PlayerZoomMath.Frame(zoomScale,
                                    PlayerZoomMath.Point(zoomOffset.x + current.x - previous.x,
                                        zoomOffset.y + current.y - previous.y)))
                                lastPanPoint = current
                                event.changes.forEach { it.consume() }
                            } else {
                                lastPanPoint = null
                            }
                        } while (event.changes.any { it.pressed })
                        if (zoomScale <= 1.05f) {
                            zoomScale = 1f
                            zoomOffset = Offset.Zero
                            onZoomLockChanged(false)
                        }
                    }
                }
                .pointerInput(isActive) {
                    if (!isActive) return@pointerInput
                    detectTapGestures(
                        onTap = { showUI = !showUI },
                        onDoubleTap = { tap ->
                            if (zoomScale > 1.01f) {
                                animateZoom = true
                                zoomScale = 1f
                                zoomOffset = Offset.Zero
                                onZoomLockChanged(false)
                            } else {
                                val video = exoPlayer.videoSize
                                val aspect = if (video.height > 0) video.width.toFloat() * video.pixelWidthHeightRatio / video.height else 0f
                                val focus = PlayerZoomMath.Point(tap.x - viewportSize.width / 2f,
                                    tap.y - viewportSize.height / 2f)
                                val target = PlayerZoomMath.clamp(PlayerZoomMath.doubleTap(focus),
                                    viewportSize.width.toFloat(), viewportSize.height.toFloat(), aspect)
                                animateZoom = true
                                zoomScale = target.scale
                                zoomOffset = Offset(target.translation.x, target.translation.y)
                                onZoomLockChanged(true)
                            }
                        }
                    )
                }
        ) {}

        if (isScrubbing && scrubFrame != null) {
            Image(scrubFrame!!.asImageBitmap(), contentDescription = null,
                modifier = Modifier.fillMaxSize().background(Color.Black), contentScale = ContentScale.Fit)
        }

        AnimatedVisibility(
            visible = showUI,
            enter = fadeIn(),
            exit = fadeOut()
        ) {
            Box(modifier = Modifier.fillMaxSize()) {
                // Top Bar
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .align(Alignment.TopCenter),
                    color = Color.White
                ) {
                    Row(
                        modifier = Modifier
                            .statusBarsPadding()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(
                            onClick = onDismiss,
                            modifier = Modifier
                                .size(34.dp)
                                .background(Color.Black.copy(alpha = 0.05f), CircleShape)
                        ) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = themeColor)
                        }
                        
                        Spacer(modifier = Modifier.weight(1f))
                        
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.clickable { showRenameDialog = true }
                        ) {
                            Text(
                                text = clip.displayName,
                                color = themeColor,
                                fontWeight = FontWeight.Bold,
                                fontSize = 15.sp
                            )
                            Spacer(modifier = Modifier.width(4.dp))
                            Icon(
                                Icons.Default.Edit,
                                contentDescription = "Rename",
                                modifier = Modifier.size(14.dp),
                                tint = themeColor
                            )
                        }
                        
                        Spacer(modifier = Modifier.weight(1f))
                        
                        Box(
                            modifier = Modifier
                                .size(width = 54.dp, height = 30.dp)
                                .background(Color.Black.copy(alpha = 0.05f), CircleShape)
                                .clickable {
                                    if (clip.highlightIndex != null && clip.sourceStartMs != null && originalPath == null)
                                        showEditUnavailable = true
                                    else showTrimEditor = true
                                },
                            contentAlignment = Alignment.Center
                        ) {
                            Text("Edit", color = themeColor, fontSize = 13.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }

                // Bottom Overlay
                Column(
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .background(Color.White)
                        .navigationBarsPadding()
                        .padding(bottom = 8.dp)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(
                            onClick = { if (exoPlayer.isPlaying) exoPlayer.pause() else exoPlayer.play() },
                            modifier = Modifier.size(42.dp).background(Color.Black.copy(alpha = 0.55f), CircleShape)
                        ) {
                            Icon(if (isPlaying) Icons.Default.PauseCircle else Icons.Default.PlayCircle,
                                contentDescription = if (isPlaying) "Pause" else "Play", tint = Color.White,
                                modifier = Modifier.size(38.dp))
                        }
                        IconButton(
                            onClick = { isMuted = !isMuted; exoPlayer.volume = if (isMuted) 0f else 1f },
                            modifier = Modifier.size(42.dp).background(Color.Black.copy(alpha = 0.55f), CircleShape)
                        ) {
                            Icon(if (isMuted) Icons.AutoMirrored.Filled.VolumeOff else Icons.AutoMirrored.Filled.VolumeUp,
                                contentDescription = if (isMuted) "Unmute" else "Mute", tint = Color.White)
                        }
                    }
                    Slider(
                        value = if (isScrubbing) scrubFraction else if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f,
                        onValueChange = { fraction ->
                            if (!isScrubbing) {
                                wasPlayingBeforeScrub = exoPlayer.isPlaying
                                exoPlayer.pause()
                                exoPlayer.setSeekParameters(SeekParameters.CLOSEST_SYNC)
                                isScrubbing = true
                            }
                            scrubFraction = fraction
                            val target = (fraction * durationMs).toLong()
                            positionMs = target
                            exoPlayer.seekTo(target)
                        },
                        onValueChangeFinished = {
                            exoPlayer.setSeekParameters(SeekParameters.EXACT)
                            exoPlayer.seekTo((scrubFraction * durationMs).toLong())
                            if (wasPlayingBeforeScrub) exoPlayer.play()
                            isScrubbing = false
                        },
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 24.dp),
                        colors = SliderDefaults.colors(thumbColor = themeColor, activeTrackColor = themeColor)
                    )
                    
                    // Action Bar
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 24.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(onClick = {
                            clip.filePath?.let { path ->
                                val source = path.toUri()
                                val shareUri = if (source.scheme == "file") {
                                    FileProvider.getUriForFile(context, "${context.packageName}.files", File(source.path ?: return@let))
                                } else source
                                val intent = Intent(Intent.ACTION_SEND).apply {
                                    type = "video/mp4"
                                    putExtra(Intent.EXTRA_STREAM, shareUri)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                context.startActivity(Intent.createChooser(intent, "Share Highlight"))
                            }
                        }) {
                            Icon(Icons.Default.Share, contentDescription = "Share", tint = themeColor)
                        }
                        
                        IconButton(onClick = onFavoriteToggle) {
                            Icon(
                                if (clip.isFavorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                                contentDescription = "Favorite",
                                tint = if (clip.isFavorite) CrimsonBlaze else themeColor
                            )
                        }
                        
                        Button(
                            onClick = {
                                playbackRate = when (playbackRate) {
                                    1.0f -> 0.5f
                                    0.5f -> 0.25f
                                    else -> 1.0f
                                }
                                exoPlayer.setPlaybackSpeed(playbackRate)
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = Color.Black.copy(alpha = 0.05f), contentColor = themeColor),
                            contentPadding = PaddingValues(horizontal = 12.dp),
                            modifier = Modifier.height(36.dp)
                        ) {
                            Icon(Icons.Default.Speed, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(4.dp))
                            Text("${playbackRate}x", fontSize = 12.sp, fontWeight = FontWeight.Bold)
                        }
                        
                        IconButton(onClick = { showDeleteConfirmation = true }) {
                            Icon(Icons.Default.Delete, contentDescription = "Delete", tint = themeColor)
                        }
                    }
                }
            }
        }
    }

    if (showRenameDialog) {
        RenameClipDialog(
            currentName = clip.displayName,
            onDismiss = { showRenameDialog = false },
            onSave = { newName ->
                onRename(newName)
                showRenameDialog = false
            }
        )
    }

    if (showTrimEditor) {
        HighlightTrimDialog(
            clip = clip,
            sourcePath = if (clip.highlightIndex != null && clip.sourceStartMs != null) originalPath else null,
            onDismiss = { showTrimEditor = false },
            onSave = { startMs, endMs, asNewClip, done ->
                onTrim(startMs, endMs, asNewClip) { success ->
                    if (success) showTrimEditor = false else showTrimError = true
                    done(success)
                }
            }
        )
    }
    if (showDeleteConfirmation) AlertDialog(
        onDismissRequest = { showDeleteConfirmation = false },
        title = { Text("Delete Clip?") },
        text = { Text("This clip will be removed from your library.") },
        confirmButton = { TextButton(onClick = { showDeleteConfirmation = false; onDelete(); onDismiss() }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { showDeleteConfirmation = false }) { Text("Cancel") } }
    )
    if (showTrimError) AlertDialog(
        onDismissRequest = { showTrimError = false },
        title = { Text("Could Not Save Highlight") },
        text = { Text("Please try again.") },
        confirmButton = { TextButton(onClick = { showTrimError = false }) { Text("OK") } }
    )
    if (showEditUnavailable) AlertDialog(
        onDismissRequest = { showEditUnavailable = false },
        title = { Text("Edit Unavailable") },
        text = { Text("You cannot edit this highlight since the full recording was deleted.") },
        confirmButton = { TextButton(onClick = { showEditUnavailable = false }) { Text("OK") } }
    )
}

@Composable
fun RenameClipDialog(currentName: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var draftName by remember { mutableStateOf(currentName) }
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(Unit) {
        delay(150)
        focusRequester.requestFocus()
        keyboard?.show()
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename Highlight") },
        text = {
            OutlinedTextField(
                value = draftName,
                onValueChange = { draftName = it },
                singleLine = true,
                modifier = Modifier.focusRequester(focusRequester)
            )
        },
        confirmButton = {
            Button(onClick = { onSave(draftName) }) {
                Text("Save")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}
