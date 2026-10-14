package com.clipitllc.clipitapp.ui

import androidx.core.net.toUri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.ui.PlayerView
import com.clipitllc.clipitapp.ui.theme.CosmosBlue
import com.clipitllc.clipitapp.ui.theme.CrimsonBlaze
import kotlinx.coroutines.delay
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun HighlightTrimDialog(
    clip: Clip,
    sourcePath: String?,
    onDismiss: () -> Unit,
    onSave: (Long, Long, Boolean, (Boolean) -> Unit) -> Unit
) {
    val context = LocalContext.current
    val isLandscape = LocalConfiguration.current.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
    var trimStart by remember(clip.id) { mutableLongStateOf(if (sourcePath != null) clip.sourceStartMs ?: 0 else 0) }
    var trimEnd by remember(clip.id) { mutableLongStateOf(if (sourcePath != null) clip.sourceEndMs ?: 10_000 else 10_000) }
    var durationMs by remember(clip.id) { mutableLongStateOf(maxOf(10_000, clip.sourceEndMs ?: 0)) }
    var playheadMs by remember(clip.id) { mutableLongStateOf(trimStart) }
    var isDragging by remember { mutableStateOf(false) }
    var isPlaying by remember { mutableStateOf(false) }
    var isSaving by remember { mutableStateOf(false) }
    var showSaveOptions by remember { mutableStateOf(false) }
    var lockedWindow by remember { mutableStateOf<Pair<Long, Long>?>(null) }
    val player = remember(context) {
        ExoPlayer.Builder(context).build().apply {
            setSeekParameters(SeekParameters.EXACT)
        }
    }

    LaunchedEffect(clip.filePath, sourcePath) {
        val path = sourcePath ?: clip.filePath
        if (path != null) {
            player.setMediaItem(MediaItem.fromUri(path.toUri()))
            player.prepare()
        }
    }
    DisposableEffect(player) { onDispose { player.release() } }
    LaunchedEffect(player, clip.id) {
        var loaded = false
        while (true) {
            val actualDuration = player.duration
            if (!loaded && actualDuration > 0) {
                loaded = true
                durationMs = actualDuration
                trimStart = trimStart.coerceIn(0, (actualDuration - 1_000).coerceAtLeast(0))
                trimEnd = if (sourcePath != null) {
                    (clip.sourceEndMs ?: actualDuration).coerceIn(trimStart + 1_000, actualDuration)
                } else actualDuration
                playheadMs = trimStart
                player.seekTo(trimStart)
                player.play()
            }
            if (!isDragging) {
                val current = player.currentPosition.coerceAtLeast(0)
                if (player.isPlaying && current >= trimEnd) {
                    player.pause()
                    player.seekTo(trimStart)
                    playheadMs = trimStart
                } else {
                    playheadMs = current.coerceIn(trimStart, trimEnd)
                }
            }
            isPlaying = player.isPlaying
            delay(30)
        }
    }

    fun seekPreview(time: Long) {
        val target = time.coerceIn(trimStart, trimEnd)
        player.pause()
        isPlaying = false
        isDragging = true
        playheadMs = target
        player.seekTo(target)
    }

    val windowStart = lockedWindow?.first ?: (trimStart - 15_000).coerceAtLeast(0)
    val windowEnd = lockedWindow?.second ?: (trimEnd + 15_000).coerceAtMost(durationMs)
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Scaffold(
            contentWindowInsets = WindowInsets(0, 0, 0, 0),
            topBar = {
                Box(Modifier.fillMaxWidth().height(56.dp).background(Color.White)) {
                    Text(clip.displayName, fontWeight = FontWeight.SemiBold, maxLines = 1, fontSize = 16.sp,
                        color = Color.Black, textAlign = TextAlign.Center,
                        modifier = Modifier.align(Alignment.Center).fillMaxWidth().padding(horizontal = 96.dp))
                    TextButton(onClick = onDismiss, modifier = Modifier.align(Alignment.CenterStart)) {
                        Text("Cancel", color = Color.DarkGray)
                    }
                    Box(Modifier.align(Alignment.CenterEnd)) {
                        Box {
                            TextButton(onClick = {
                                if (clip.highlightIndex == null) showSaveOptions = true
                                else {
                                    isSaving = true
                                    onSave(trimStart, trimEnd, false) { isSaving = false }
                                }
                            }, enabled = !isSaving && trimEnd - trimStart >= 1_000) {
                                Text(if (isSaving) "Saving..." else "Save", color = CrimsonBlaze, fontWeight = FontWeight.SemiBold)
                            }
                            DropdownMenu(expanded = showSaveOptions, onDismissRequest = { showSaveOptions = false }) {
                                DropdownMenuItem(text = { Text("Save Video") }, onClick = {
                                    showSaveOptions = false
                                    isSaving = true
                                    onSave(trimStart, trimEnd, false) { isSaving = false }
                                })
                                DropdownMenuItem(text = { Text("Save Video as New Clip") }, onClick = {
                                    showSaveOptions = false
                                    isSaving = true
                                    onSave(trimStart, trimEnd, true) { isSaving = false }
                                })
                            }
                        }
                    }
                }
            }
        ) { padding ->
            Column(Modifier.fillMaxSize().padding(padding).background(Color.White)) {
                Box(
                    Modifier.fillMaxWidth()
                        .weight(1f)
                        .background(Color(0xFF0F0F0F))
                ) {
                    AndroidView(
                        factory = { ctx -> PlayerView(ctx).apply { this.player = player; useController = false } },
                        modifier = Modifier.fillMaxSize()
                    )
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = if (isLandscape) 4.dp else 10.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    TrimTimeLabel("Start", trimStart, CrimsonBlaze, Modifier.weight(1f))
                    VerticalDivider(Modifier.height(36.dp), color = Color.LightGray)
                    TrimTimeLabel("Playhead", playheadMs, Color.Black, Modifier.weight(1f))
                    VerticalDivider(Modifier.height(36.dp), color = Color.LightGray)
                    TrimTimeLabel("End", trimEnd, CrimsonBlaze, Modifier.weight(1f))
                }
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = if (isLandscape) 48.dp else 20.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    MacroTimeline(durationMs, trimStart, trimEnd, windowStart, windowEnd, playheadMs) { time ->
                        val length = trimEnd - trimStart
                        val start = (time - length / 2).coerceIn(0, (durationMs - length).coerceAtLeast(0))
                        trimStart = start
                        trimEnd = start + length
                        seekPreview(start)
                    }
                    Row(
                        Modifier.fillMaxWidth().height(64.dp).background(Color(0xFFBFBFBF), RoundedCornerShape(8.dp)),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Box(Modifier.width(64.dp).fillMaxHeight().clickable {
                            if (player.isPlaying) {
                                player.pause()
                            } else {
                                if (playheadMs >= trimEnd - 30) {
                                    playheadMs = trimStart
                                    player.seekTo(trimStart)
                                }
                                isDragging = false
                                player.play()
                            }
                        }, contentAlignment = Alignment.Center) {
                            Icon(if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                contentDescription = if (isPlaying) "Pause" else "Play",
                                tint = CrimsonBlaze, modifier = Modifier.size(28.dp))
                        }
                        VerticalDivider(Modifier.height(64.dp), thickness = 2.dp, color = Color.White.copy(alpha = 0.28f))
                        MicroTimeline(
                            durationMs, trimStart, trimEnd, windowStart, windowEnd, playheadMs,
                            Modifier.weight(1f).padding(start = 10.dp, end = 12.dp),
                            onPlayhead = { seekPreview(it) },
                            onStartDrag = { lockedWindow = windowStart to windowEnd },
                            onStartDelta = { delta ->
                                trimStart = (trimStart + delta).coerceIn(0, trimEnd - 1_000)
                                seekPreview(trimStart)
                            },
                            onEndDelta = { delta ->
                                trimEnd = (trimEnd + delta).coerceIn(trimStart + 1_000, durationMs)
                                seekPreview(trimEnd)
                            },
                            onHandleEnd = { lockedWindow = null }
                        )
                    }
                }
                HorizontalDivider(Modifier.padding(top = if (isLandscape) 6.dp else 14.dp))
                Row(
                    Modifier.fillMaxWidth().padding(top = 8.dp, bottom = if (isLandscape) 8.dp else 18.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text("◷", color = CosmosBlue, fontSize = 16.sp)
                    Spacer(Modifier.width(6.dp))
                    Text("Clip duration: ${formatPreciseTime(trimEnd - trimStart)}", color = CosmosBlue, fontSize = 14.sp)
                }
                if (isSaving) LinearProgressIndicator(Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun TrimTimeLabel(label: String, timeMs: Long, color: Color, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, fontSize = 11.sp, color = Color.Gray)
        Text(formatPreciseTime(timeMs), color = color, fontWeight = FontWeight.SemiBold,
            fontSize = 15.sp, textAlign = TextAlign.Center)
    }
}

@Composable
private fun MacroTimeline(
    durationMs: Long, startMs: Long, endMs: Long, windowStartMs: Long, windowEndMs: Long,
    playheadMs: Long, onMove: (Long) -> Unit
) {
    BoxWithConstraints(Modifier.fillMaxWidth().height(18.dp)) {
        val width = maxWidth
        val widthPx = with(LocalDensity.current) { width.toPx() }.coerceAtLeast(1f)
        val move by rememberUpdatedState(onMove)
        fun fraction(time: Long) = (time.toFloat() / durationMs.coerceAtLeast(1)).coerceIn(0f, 1f)
        Box(Modifier.fillMaxSize()
            .pointerInput(widthPx) {
                detectDragGestures(onDragStart = { move((it.x / widthPx * durationMs).toLong()) },
                    onDrag = { change, _ -> change.consume(); move((change.position.x / widthPx * durationMs).toLong()) })
            }
            .pointerInput(widthPx) { detectTapGestures { move((it.x / widthPx * durationMs).toLong()) } }
        ) {
            Box(Modifier.fillMaxWidth().height(14.dp).align(Alignment.Center).background(Color(0xFF383838), RoundedCornerShape(3.dp)))
            Box(Modifier.offset(x = width * fraction(startMs)).width(width * (fraction(endMs) - fraction(startMs)))
                .height(14.dp).align(Alignment.CenterStart).background(Color.Yellow))
            Box(Modifier.offset(x = width * fraction(windowStartMs))
                .width(width * (fraction(windowEndMs) - fraction(windowStartMs))).fillMaxHeight()
                .border(1.5.dp, Color.White, RoundedCornerShape(3.dp))
                .background(Color.White.copy(alpha = 0.15f)))
            Box(Modifier.offset(x = width * fraction(playheadMs)).width(2.dp).fillMaxHeight().background(Color.White))
        }
    }
}

@Composable
private fun MicroTimeline(
    durationMs: Long, startMs: Long, endMs: Long, windowStartMs: Long, windowEndMs: Long,
    playheadMs: Long, modifier: Modifier, onPlayhead: (Long) -> Unit,
    onStartDrag: () -> Unit, onStartDelta: (Long) -> Unit,
    onEndDelta: (Long) -> Unit, onHandleEnd: () -> Unit
) {
    BoxWithConstraints(modifier.fillMaxHeight()) {
        val width = maxWidth
        val widthPx = with(LocalDensity.current) { width.toPx() }.coerceAtLeast(1f)
        val span = (windowEndMs - windowStartMs).coerceAtLeast(1)
        fun fraction(time: Long) = ((time - windowStartMs).toFloat() / span).coerceIn(0f, 1f)
        val startX = width * fraction(startMs)
        val endX = width * fraction(endMs)
        val playheadX = width * fraction(playheadMs)
        val playheadAction by rememberUpdatedState(onPlayhead)
        val startAction by rememberUpdatedState(onStartDrag)
        val startDeltaAction by rememberUpdatedState(onStartDelta)
        val endDeltaAction by rememberUpdatedState(onEndDelta)
        val handleEndAction by rememberUpdatedState(onHandleEnd)
        val localStart by rememberUpdatedState(startMs)
        val localEnd by rememberUpdatedState(endMs)
        val localWindowStart by rememberUpdatedState(windowStartMs)
        val localSpan by rememberUpdatedState(span)
        fun seekAt(x: Float) {
            val time = localWindowStart + (x.coerceIn(0f, widthPx) / widthPx * localSpan).toLong()
            playheadAction(time.coerceIn(localStart, localEnd))
        }
        Box(Modifier.fillMaxWidth().height(52.dp).align(Alignment.Center).background(Color(0xFF525252), RoundedCornerShape(8.dp))
            .pointerInput(widthPx) {
                detectDragGestures(onDragStart = { seekAt(it.x) }, onDrag = { change, _ ->
                    change.consume(); seekAt(change.position.x)
                })
            }
            .pointerInput(widthPx) { detectTapGestures { seekAt(it.x) } })
        Box(Modifier.offset(x = startX).width((endX - startX).coerceAtLeast(0.dp))
            .height(52.dp).align(Alignment.CenterStart)
            .border(6.dp, Color.Yellow, RoundedCornerShape(6.dp)))
        Box(Modifier.offset(x = playheadX).width(3.dp).height(54.dp)
            .align(Alignment.CenterStart).background(Color.White, RoundedCornerShape(8.dp)))
        val dragStart by rememberUpdatedState(onStartDrag)
        val dragEnd by rememberUpdatedState(onHandleEnd)
        Box(Modifier.offset(x = startX - 9.dp).width(18.dp).height(60.dp)
            .align(Alignment.CenterStart).background(Color.Yellow, RoundedCornerShape(8.dp))
            .pointerInput(widthPx) {
                detectDragGestures(onDragStart = { dragStart() }, onDragEnd = { dragEnd() },
                    onDragCancel = { dragEnd() }, onDrag = { change, delta ->
                        change.consume(); startDeltaAction((delta.x / widthPx * localSpan).toLong())
                    })
            }, contentAlignment = Alignment.Center) { Text("‹", color = Color.Black, fontSize = 24.sp, fontWeight = FontWeight.Bold) }
        Box(Modifier.offset(x = endX - 9.dp).width(18.dp).height(60.dp)
            .align(Alignment.CenterStart).background(Color.Yellow, RoundedCornerShape(8.dp))
            .pointerInput(widthPx) {
                detectDragGestures(onDragStart = { startAction() }, onDragEnd = { handleEndAction() },
                    onDragCancel = { handleEndAction() }, onDrag = { change, delta ->
                        change.consume(); endDeltaAction((delta.x / widthPx * localSpan).toLong())
                    })
            }, contentAlignment = Alignment.Center) { Text("›", color = Color.Black, fontSize = 24.sp, fontWeight = FontWeight.Bold) }
    }
}

fun formatPreciseTime(ms: Long): String {
    val seconds = ms.coerceAtLeast(0) / 1000
    val hundredths = (ms.coerceAtLeast(0) % 1000) / 10
    return String.format(Locale.getDefault(), "%02d:%02d.%02d", seconds / 60, seconds % 60, hundredths)
}
