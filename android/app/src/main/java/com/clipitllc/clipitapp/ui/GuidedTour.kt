package com.clipitllc.clipitapp.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipitllc.clipitapp.R
import com.clipitllc.clipitapp.ui.theme.BlueMarble
import com.clipitllc.clipitapp.ui.theme.CosmosBlue
import com.clipitllc.clipitapp.ui.theme.CrimsonBlaze

internal enum class TourTarget { RECORD, CLIP_IT, TIMING, LIBRARY, REEL, DEVICE, RETENTION, DIM_SCREEN }

internal object TourTargets {
    val frames = mutableStateMapOf<TourTarget, Rect>()
    var activeTarget by mutableStateOf<TourTarget?>(null)
}

internal fun Modifier.tourTarget(target: TourTarget): Modifier = onGloballyPositioned {
    TourTargets.frames[target] = it.boundsInWindow()
}

private data class TourStep(val title: String, val message: String, val tab: AppTab, val target: TourTarget?)

private val steps = listOf(
    TourStep("Welcome to ClipIt", "A quick tour will show you how to record, save highlights, make reels, and connect to your ClipIt Button!", AppTab.RECORD, null),
    TourStep("Start with Record", "Tap this button to start recording. Tap it again to stop and save the session. If you have a physical ClipIt Button, hold for 3 seconds to start/stop recordings remotely.", AppTab.RECORD, TourTarget.RECORD),
    TourStep("Clip the highlights", "While recording, tap the ClipIt Button to save a highlight. If you have a physical ClipIt Button, it functions the same.", AppTab.RECORD, TourTarget.CLIP_IT),
    TourStep("Choose your highlight length", "Tap this button to change how much footage is saved around a highlight, from 5 to 60 seconds.", AppTab.RECORD, TourTarget.TIMING),
    TourStep("Your clips, filtered", "Use the filters to find Highlights, Favorites, Reels, or Original Videos within your ClipIt Library.", AppTab.CLIPS, TourTarget.LIBRARY),
    TourStep("Create a highlight reel", "Tap Create ClipIt Reel, choose highlights in the order you want them to play, then generate your reel. This will string your clips together for you.", AppTab.CLIPS, TourTarget.REEL),
    TourStep("Connect your ClipIt Button", "Turn on your ClipIt Button and keep it nearby. On this screen, scan and select it when it appears. Its connection and battery status show here. Rename your device if you'd like!", AppTab.DEVICE, TourTarget.DEVICE),
    TourStep("Take control of your storage", "Original Videos use the most storage. Set automatic deletion to Never or after 1, 3, 7, 14, or 30 days. Your highlights and reels remain saved in the Library.", AppTab.SETTINGS, TourTarget.RETENTION),
    TourStep("Record for longer", "Turn on Dim Screen While Recording to lower screen brightness during a session and help save battery. You're ready to capture your first moment!", AppTab.SETTINGS, TourTarget.DIM_SCREEN)
)

@Composable
fun GuidedTour(onTabChange: (AppTab) -> Unit, onFinish: () -> Unit) {
    var index by remember { mutableIntStateOf(0) }
    var confirmSkip by remember { mutableStateOf(false) }
    var overlayOrigin by remember { mutableStateOf(Offset.Zero) }
    val step = steps[index]
    val density = LocalDensity.current
    LaunchedEffect(index) {
        TourTargets.activeTarget = step.target
        onTabChange(step.tab)
    }
    DisposableEffect(Unit) { onDispose { TourTargets.activeTarget = null; TourTargets.frames.clear() } }

    val frame = step.target?.let(TourTargets.frames::get)
    val highlight = frame?.let {
        Rect(it.left - overlayOrigin.x, it.top - overlayOrigin.y,
            it.right - overlayOrigin.x, it.bottom - overlayOrigin.y)
    }?.let {
        val padding = with(density) { 7.dp.toPx() }
        Rect(it.left - padding, it.top - padding, it.right + padding, it.bottom + padding)
    }

    Box(Modifier.fillMaxSize().pointerInput(Unit) { detectTapGestures { } }
        .onGloballyPositioned { overlayOrigin = it.boundsInWindow().topLeft }) {
        Canvas(Modifier.fillMaxSize()) {
            val visible = highlight?.takeIf {
                it.right > 0 && it.bottom > 0 && it.left < size.width && it.top < size.height
            }
            val mask = Path().apply {
                fillType = PathFillType.EvenOdd
                addRect(Rect(Offset.Zero, size))
                if (visible != null) addRoundRect(RoundRect(visible, CornerRadius(20.dp.toPx())))
            }
            drawPath(mask, Color.Black.copy(alpha = 0.78f))
            if (visible != null) {
                drawRoundRect(CrimsonBlaze, topLeft = visible.topLeft, size = visible.size,
                    cornerRadius = CornerRadius(20.dp.toPx()), style = Stroke(3.dp.toPx()))
            }
        }

        val targetBelowMiddle = highlight?.center?.y?.let { it > with(density) { 350.dp.toPx() } } == true
        if (highlight != null) {
            Icon(if (targetBelowMiddle) Icons.Default.ArrowDownward else Icons.Default.ArrowUpward,
                contentDescription = null, tint = CrimsonBlaze,
                modifier = Modifier.align(Alignment.TopStart).offset {
                    androidx.compose.ui.unit.IntOffset(
                        (highlight.center.x - with(density) { 12.dp.toPx() }).toInt(),
                        (if (targetBelowMiddle) highlight.top - with(density) { 42.dp.toPx() }
                        else highlight.bottom + with(density) { 18.dp.toPx() }).toInt()
                    )
                })
        }

        TextButton(onClick = { confirmSkip = true },
            modifier = Modifier.align(Alignment.TopEnd).statusBarsPadding().padding(top = 12.dp, end = 20.dp)) {
            Text("Skip", color = Color.White, fontWeight = FontWeight.SemiBold)
        }

        Surface(
            modifier = Modifier.align(if (targetBelowMiddle) Alignment.TopCenter else Alignment.BottomCenter)
                .padding(horizontal = 18.dp, vertical = 70.dp).widthIn(max = 440.dp).fillMaxWidth(),
            shape = RoundedCornerShape(20.dp), color = Color.White, shadowElevation = 12.dp
        ) {
            Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (index == 0) Image(painterResource(R.drawable.clipit_icon), contentDescription = "ClipIt app icon",
                        modifier = Modifier.size(48.dp))
                    Text("CLIPIT TOUR  ·  ${index + 1} OF ${steps.size}",
                        color = BlueMarble, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
                Text(step.title, color = CosmosBlue, fontSize = 25.sp, fontWeight = FontWeight.Bold)
                Text(step.message, color = CosmosBlue.copy(alpha = 0.8f), fontSize = 15.sp, lineHeight = 21.sp)
                Box(Modifier.fillMaxWidth().height(5.dp)
                    .background(CrimsonBlaze.copy(alpha = 0.13f), CircleShape)) {
                    Box(Modifier.fillMaxWidth((index + 1f) / steps.size).fillMaxHeight()
                        .background(CrimsonBlaze, CircleShape))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (index > 0) OutlinedButton(onClick = { index-- }, modifier = Modifier.weight(1f)) {
                        Text("Back")
                    }
                    Button(onClick = { if (index == steps.lastIndex) onFinish() else index++ },
                        modifier = Modifier.weight(1f),
                        colors = ButtonDefaults.buttonColors(containerColor = CrimsonBlaze)) {
                        Text(if (index == steps.lastIndex) "Get Started" else "Next")
                    }
                }
            }
        }
    }

    if (confirmSkip) AlertDialog(
        onDismissRequest = { confirmSkip = false },
        title = { Text("Skip the tutorial?") },
        text = { Text("You can watch it again anytime in Settings → About.") },
        confirmButton = { TextButton(onClick = onFinish) { Text("Skip Tutorial") } },
        dismissButton = { TextButton(onClick = { confirmSkip = false }) { Text("Keep Learning") } }
    )
}
