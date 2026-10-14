package com.clipitllc.clipitapp.ui

import android.net.Uri
import android.graphics.Bitmap
import android.content.Intent
import android.media.MediaMetadataRetriever
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.clipitllc.clipitapp.ui.theme.BlueMarble
import com.clipitllc.clipitapp.ui.theme.CosmosBlue
import com.clipitllc.clipitapp.ui.theme.CrimsonBlaze
import com.clipitllc.clipitapp.ui.theme.GochujangRed
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import kotlin.math.ceil

// MARK: - Models & Enums

enum class ClipFilter(val label: String, val icon: ImageVector, val accentColor: Color) {
    ALL("All", Icons.Default.GridView, GochujangRed),
    HIGHLIGHTS("Highlights", Icons.Default.Whatshot, CrimsonBlaze),
    FAVORITES("Favorites", Icons.Default.Favorite, CrimsonBlaze),
    REELS("Reels", Icons.Default.Movie, BlueMarble),
    FULL_RECORDINGS("Original Video", Icons.Default.PlayCircle, CosmosBlue)
}

enum class ClipCategoryType(val color: Color) {
    FULL_RECORDING(CosmosBlue),
    HIGHLIGHT(CrimsonBlaze),
    REEL(BlueMarble)
}

data class Clip(
    val id: String = UUID.randomUUID().toString(),
    val displayName: String,
    val filePath: String? = null,
    val durationLabel: String = "0:15",
    val isFavorite: Boolean = false,
    val isReel: Boolean = false,
    val highlightIndex: Int? = null,
    val isSecondaryAngle: Boolean = false,
    val timestamp: Long? = null,
    val sourceStartMs: Long? = null,
    val sourceEndMs: Long? = null,
    val isProcessing: Boolean = false,
    val recoveryKey: String? = null
)

data class Session(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val formattedDate: String,
    val durationLabel: String,
    val clips: List<Clip>,
    val createdAt: Long = System.currentTimeMillis(),
    val originalVideoAutoDeleteDisabled: Boolean = false,
    val isProcessing: Boolean = false,
    val processingProgress: Float = 0f,
    val recordingUri: String? = null,
    val recordingStartedAtMs: Long? = null,
    val recordingEndedAtMs: Long? = null,
    val highlightLengthMs: Long? = null
)

// MARK: - Main Clips Screen

@Composable
fun ClipsScreen(
    sessions: List<Session> = emptyList(),
    clipsViewModel: ClipsViewModel,
    onDeleteClip: (sessionId: String, clipId: String) -> Unit = { _, _ -> },
    onRenameSession: (sessionId: String, newName: String) -> Unit = { _, _ -> }
) {
    val context = LocalContext.current
    val recoveredExtractionProgress by clipsViewModel.recoveredExtractionProgress.collectAsState()
    var selectedFilter by remember { mutableStateOf(ClipFilter.ALL) }
    LaunchedEffect(TourTargets.activeTarget) {
        if (TourTargets.activeTarget == TourTarget.REEL) selectedFilter = ClipFilter.HIGHLIGHTS
    }
    val visibleSessions = remember(sessions, selectedFilter) {
        if (selectedFilter == ClipFilter.ALL) sessions else sessions.filter { session ->
            session.clips.any { clip ->
                when (selectedFilter) {
                    ClipFilter.ALL -> true
                    ClipFilter.HIGHLIGHTS -> clip.highlightIndex != null && !clip.isReel && !clip.isSecondaryAngle
                    ClipFilter.FAVORITES -> clip.isFavorite
                    ClipFilter.REELS -> clip.isReel
                    ClipFilter.FULL_RECORDINGS -> clip.highlightIndex == null && !clip.isReel && !clip.isSecondaryAngle
                }
            }
        }
    }.sortedBy { it.createdAt }
    val listState = rememberLazyListState()
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            nowMs = System.currentTimeMillis()
            kotlinx.coroutines.delay(60_000)
        }
    }
    LaunchedEffect(visibleSessions.flatMap { session -> listOf(session.id) + session.clips.map { it.id } }, selectedFilter) {
        if (visibleSessions.isNotEmpty()) {
            listState.scrollToItem(visibleSessions.lastIndex)
            listState.scrollBy(100_000f)
        }
    }
    var isSelectionMode by remember { mutableStateOf(false) }
    var selectedClipIds by remember { mutableStateOf(setOf<String>()) }

    var isReelSelectionMode by remember { mutableStateOf(false) }
    var selectedReelClipIds by remember { mutableStateOf(setOf<String>()) }
    var showCreateReel by remember { mutableStateOf(false) }
    var reelTitle by remember { mutableStateOf("") }
    var reelColor by remember { mutableIntStateOf(android.graphics.Color.BLACK) }
    var reelOrder by remember { mutableStateOf(listOf<Clip>()) }
    var reelExporting by remember { mutableStateOf(false) }
    var reelError by remember { mutableStateOf<String?>(null) }

    var sessionBeingRenamed by remember { mutableStateOf<Session?>(null) }
    var sessionToDelete by remember { mutableStateOf<Session?>(null) }
    var activeClip by remember { mutableStateOf<Clip?>(null) }

    Scaffold(
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
        topBar = {
            Column(modifier = Modifier.background(Color.White)) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "ClipIt Library",
                        style = MaterialTheme.typography.headlineMedium.copy(
                            fontWeight = FontWeight.Bold,
                            color = CosmosBlue
                        )
                    )
                    if (sessions.isNotEmpty() && !isReelSelectionMode) {
                        TextButton(onClick = {
                            isSelectionMode = !isSelectionMode
                            if (!isSelectionMode) selectedClipIds = emptySet()
                        }) {
                            Text(
                                if (isSelectionMode) "Cancel" else "Select",
                                color = CrimsonBlaze,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                    } else if (isReelSelectionMode) {
                        TextButton(onClick = {
                            isReelSelectionMode = false
                            selectedReelClipIds = emptySet()
                        }) {
                            Text("Cancel", color = CosmosBlue, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }

                if (sessions.isNotEmpty() || TourTargets.activeTarget == TourTarget.LIBRARY ||
                    TourTargets.activeTarget == TourTarget.REEL) {
                    PillFilterBar(
                        selectedFilter = selectedFilter,
                        onFilterSelected = { filter ->
                            if (isReelSelectionMode && filter != ClipFilter.HIGHLIGHTS) {
                                isReelSelectionMode = false
                                selectedReelClipIds = emptySet()
                            }
                            selectedFilter = filter
                        }
                    )
                }

                if ((selectedFilter != ClipFilter.ALL && sessions.isNotEmpty() && !isSelectionMode) ||
                    TourTargets.activeTarget == TourTarget.REEL) {
                    CreateReelQuickBanner(
                        selectedCount = if (isReelSelectionMode) selectedReelClipIds.size else null,
                        onClick = {
                            if (isReelSelectionMode) {
                                reelOrder = sessions.flatMap { it.clips }.filter { it.id in selectedReelClipIds }
                                reelTitle = ""
                                showCreateReel = reelOrder.isNotEmpty()
                            } else {
                                selectedFilter = ClipFilter.HIGHLIGHTS
                                isReelSelectionMode = true
                                selectedReelClipIds = emptySet()
                            }
                        }
                    )
                }
            }
        },
        bottomBar = {
            if (isSelectionMode) {
                SelectionBottomBar(
                    selectedCount = selectedClipIds.size,
                    onShare = {
                        val uris = ArrayList<Uri>()
                        sessions.flatMap { it.clips }.filter { it.id in selectedClipIds }.forEach { clip ->
                            clip.filePath?.let { path ->
                                val source = path.toUri()
                                uris.add(if (source.scheme == "file")
                                    FileProvider.getUriForFile(context, "${context.packageName}.files", File(source.path ?: return@let))
                                    else source)
                            }
                        }
                        if (uris.isNotEmpty()) {
                            val intent = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                                type = "video/mp4"
                                putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            context.startActivity(Intent.createChooser(intent, "Share Highlights"))
                        }
                    },
                    onDelete = {
                        sessions.forEach { session ->
                            session.clips.filter { it.id in selectedClipIds }.forEach { clip ->
                                onDeleteClip(session.id, clip.id)
                            }
                        }
                        isSelectionMode = false
                        selectedClipIds = emptySet()
                    }
                )
            }
        }
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(Color.White)
        ) {
            if (visibleSessions.isEmpty()) {
                EmptyStateView(selectedFilter)
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    state = listState,
                    contentPadding = PaddingValues(bottom = 24.dp)
                ) {
                    itemsIndexed(visibleSessions, key = { _, item -> item.id }) { index, session ->
                        SessionCardView(
                            session = session,
                            retentionDays = clipsViewModel.retentionDays(),
                            nowMs = nowMs,
                            selectedFilter = selectedFilter,
                            isSelectionMode = isSelectionMode,
                            selectedClipIds = selectedClipIds,
                            isReelSelectionMode = isReelSelectionMode,
                            selectedReelClipIds = selectedReelClipIds,
                            onToggleSelect = { id ->
                                selectedClipIds = if (id in selectedClipIds) selectedClipIds - id else selectedClipIds + id
                            },
                            onToggleReelSelect = { id ->
                                selectedReelClipIds = if (id in selectedReelClipIds) selectedReelClipIds - id else selectedReelClipIds + id
                            },
                            onRenameClick = { sessionBeingRenamed = session },
                            onDeleteSessionClick = { sessionToDelete = session },
                            onDeleteClip = { clipId -> onDeleteClip(session.id, clipId) },
                            onDisableAutoDelete = { clipsViewModel.disableOriginalVideoAutoDelete(session.id) },
                            onClipClick = { clip -> activeClip = clip }
                        )

                        if (selectedFilter != ClipFilter.REELS && index < visibleSessions.size - 1) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(5.dp)
                                    .background(CosmosBlue)
                            )
                        }
                    }
                }
            }
        }
    }

    sessionBeingRenamed?.let { session ->
        RenameSessionDialog(
            currentName = session.name,
            onDismiss = { sessionBeingRenamed = null },
            onSave = { newName ->
                onRenameSession(session.id, newName)
                sessionBeingRenamed = null
            }
        )
    }

    sessionToDelete?.let { session ->
        AlertDialog(
            onDismissRequest = { sessionToDelete = null },
            title = { Text("Delete \"${session.name}\"?") },
            text = { Text("This will permanently remove this session and all associated clips.") },
            confirmButton = {
                TextButton(onClick = {
                    clipsViewModel.deleteSession(session.id)
                    selectedClipIds = selectedClipIds - session.clips.map { it.id }.toSet()
                    sessionToDelete = null
                }) { Text("Delete", color = CrimsonBlaze) }
            },
            dismissButton = {
                TextButton(onClick = { sessionToDelete = null }) { Text("Cancel") }
            }
        )
    }

    if (showCreateReel) {
        AlertDialog(
            onDismissRequest = { if (!reelExporting) showCreateReel = false },
            title = { Text("Create Reel") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedTextField(
                        value = reelTitle,
                        onValueChange = { reelTitle = it },
                        label = { Text("Title Slide (Optional)") },
                        placeholder = { Text("Team 1 vs Team 2\nGame 1") },
                        enabled = !reelExporting
                    )
                    Text("Title Card Color", fontWeight = FontWeight.SemiBold)
                    Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                        listOf(
                            android.graphics.Color.BLACK, android.graphics.Color.WHITE,
                            android.graphics.Color.RED, android.graphics.Color.rgb(255, 149, 0),
                            android.graphics.Color.YELLOW, android.graphics.Color.GREEN,
                            android.graphics.Color.BLUE, android.graphics.Color.rgb(175, 82, 222)
                        ).forEach { option ->
                            Box(modifier = Modifier.size(30.dp)
                                .background(Color(option), CircleShape)
                                .border(if (reelColor == option) 3.dp else 1.dp, if (reelColor == option) CosmosBlue else Color.Gray, CircleShape)
                                .clickable(enabled = !reelExporting) { reelColor = option })
                        }
                    }
                    Text("Clips Sequence (${reelOrder.size})", fontWeight = FontWeight.SemiBold)
                    reelOrder.forEachIndexed { index, clip ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(clip.displayName, modifier = Modifier.weight(1f), maxLines = 1)
                            IconButton(onClick = {
                                val reordered = reelOrder.toMutableList()
                                java.util.Collections.swap(reordered, index, index - 1)
                                reelOrder = reordered
                            }, enabled = index > 0 && !reelExporting) {
                                Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Move earlier")
                            }
                            IconButton(onClick = {
                                val reordered = reelOrder.toMutableList()
                                java.util.Collections.swap(reordered, index, index + 1)
                                reelOrder = reordered
                            }, enabled = index < reelOrder.lastIndex && !reelExporting) {
                                Icon(Icons.Default.KeyboardArrowDown, contentDescription = "Move later")
                            }
                        }
                    }
                    if (reelExporting) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    reelExporting = true
                    clipsViewModel.createReel(reelOrder, reelTitle, reelColor) { success, message ->
                        reelExporting = false
                        if (success) {
                            showCreateReel = false
                            isReelSelectionMode = false
                            selectedReelClipIds = emptySet()
                            selectedFilter = ClipFilter.REELS
                        } else reelError = message
                    }
                }, enabled = !reelExporting) { Text("Generate") }
            },
            dismissButton = {
                TextButton(onClick = { showCreateReel = false }, enabled = !reelExporting) { Text("Back") }
            }
        )
    }

    reelError?.let { error ->
        AlertDialog(onDismissRequest = { reelError = null }, title = { Text("Reel Export") }, text = { Text(error) }, confirmButton = {
            TextButton(onClick = { reelError = null }) { Text("OK") }
        })
    }

    activeClip?.let { clip ->
        val sessionClips = sessions.find { it.clips.any { c -> c.id == clip.id } }
            ?.let { visibleSessionClips(it.clips, selectedFilter) } ?: emptyList()
        val originalPath = sessionClips.firstOrNull { it.highlightIndex == null && !it.isReel }?.filePath
        ClipPagerDialog(
            clips = sessionClips,
            originalPath = originalPath,
            initialClipId = clip.id,
            onDismiss = { activeClip = null },
            onDelete = { clipToDelete ->
                sessions.find { it.clips.any { c -> c.id == clipToDelete.id } }?.let { session ->
                    onDeleteClip(session.id, clipToDelete.id)
                }
            },
            onRename = { clipToRename, newName ->
                clipsViewModel.renameClip(clipToRename.id, newName)
            },
            onFavoriteToggle = { clipToFavorite ->
                clipsViewModel.toggleFavorite(clipToFavorite.id)
            },
            onTrim = { clipToTrim, startMs, endMs, asNewClip, done ->
                clipsViewModel.trimClip(clipToTrim, startMs, endMs, asNewClip, done)
            }
        )
    }
    recoveredExtractionProgress?.let { progress ->
        Dialog(
            onDismissRequest = {},
            properties = DialogProperties(usePlatformDefaultWidth = false)
        ) {
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.65f)), contentAlignment = Alignment.Center) {
                ExtractionProgressView(current = progress.current, total = progress.total)
            }
        }
    }
}

// MARK: - Header Filter Pill Bar

@Composable
fun PillFilterBar(
    selectedFilter: ClipFilter,
    onFilterSelected: (ClipFilter) -> Unit
) {
    LazyRow(
        modifier = Modifier.tourTarget(TourTarget.LIBRARY),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        items(ClipFilter.entries.toTypedArray()) { filter ->
            val isSelected = selectedFilter == filter
            Surface(
                onClick = { onFilterSelected(filter) },
                shape = CapsuleShape,
                color = if (isSelected) filter.accentColor else Color.White,
                border = androidx.compose.foundation.BorderStroke(1.5.dp, filter.accentColor)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    Icon(
                        imageVector = filter.icon,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                        tint = if (isSelected) Color.White else filter.accentColor
                    )
                    Text(
                        text = filter.label,
                        style = MaterialTheme.typography.labelMedium.copy(
                            fontWeight = FontWeight.SemiBold,
                            color = if (isSelected) Color.White else filter.accentColor
                        )
                    )
                }
            }
        }
    }
}

// MARK: - Banner

@Composable
fun CreateReelQuickBanner(selectedCount: Int? = null, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        enabled = selectedCount == null || selectedCount > 0,
        shape = RoundedCornerShape(12.dp),
        color = Color.Unspecified,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .tourTarget(TourTarget.REEL)
    ) {
        Row(
            modifier = Modifier
                .background(
                    brush = Brush.horizontalGradient(listOf(CrimsonBlaze, BlueMarble)),
                    shape = RoundedCornerShape(12.dp)
                )
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp)
            ) {
                Icon(if (selectedCount == null) Icons.Default.AddCircle else Icons.Default.Movie, contentDescription = null, tint = Color.White)
                Text(
                    if (selectedCount == null) "Create ClipIt Reel" else "Create Reel ($selectedCount)",
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    fontSize = 15.sp
                )
            }
            Icon(Icons.Default.ChevronRight, contentDescription = null, tint = Color.White.copy(alpha = 0.8f))
        }
    }
}

// MARK: - Session Section Card

@Composable
fun SessionCardView(
    session: Session,
    retentionDays: Int,
    nowMs: Long,
    selectedFilter: ClipFilter,
    isSelectionMode: Boolean,
    selectedClipIds: Set<String>,
    isReelSelectionMode: Boolean,
    selectedReelClipIds: Set<String>,
    onToggleSelect: (String) -> Unit,
    onToggleReelSelect: (String) -> Unit,
    onRenameClick: () -> Unit,
    onDeleteSessionClick: () -> Unit,
    onDeleteClip: (String) -> Unit,
    onDisableAutoDelete: () -> Unit,
    onClipClick: (Clip) -> Unit
) {
    var showRetentionInfo by remember { mutableStateOf(false) }
    val filteredClips = remember(session, selectedFilter) {
        visibleSessionClips(session.clips, selectedFilter)
    }

    Column(modifier = Modifier.padding(vertical = 12.dp)) {
        if (selectedFilter != ClipFilter.REELS) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Row(
                        modifier = Modifier.clickable(onClick = onRenameClick),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Text(
                            text = displaySessionName(session.name),
                            style = MaterialTheme.typography.titleLarge.copy(
                                fontWeight = FontWeight.Bold,
                                color = CosmosBlue
                            )
                        )
                        Icon(Icons.Default.Edit, contentDescription = "Rename session", modifier = Modifier.size(14.dp), tint = GochujangRed)
                    }
                    Text(
                        text = "${session.formattedDate} • ${session.durationLabel}",
                        style = MaterialTheme.typography.bodySmall.copy(color = CosmosBlue)
                    )
                }
                if (isSelectionMode) {
                    IconButton(
                        onClick = onDeleteSessionClick,
                        modifier = Modifier
                            .size(36.dp)
                            .background(CrimsonBlaze.copy(alpha = 0.15f), CircleShape)
                    ) {
                        Icon(
                            Icons.Default.Delete,
                            contentDescription = "Delete ${session.name} session",
                            modifier = Modifier.size(16.dp),
                            tint = CrimsonBlaze
                        )
                    }
                } else {
                    Spacer(modifier = Modifier.size(36.dp))
                }
            }
        }

        if (session.isProcessing) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                Text(
                    "Saving Your Clips...",
                    style = MaterialTheme.typography.labelSmall,
                    color = CrimsonBlaze,
                    fontWeight = FontWeight.Bold
                )
                LinearProgressIndicator(
                    progress = { session.processingProgress },
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(4.dp)
                        .clip(CircleShape),
                    color = CrimsonBlaze,
                    trackColor = CrimsonBlaze.copy(alpha = 0.1f)
                )
            }
        }

        if (filteredClips.isNotEmpty()) {
            BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
            val rows = (filteredClips.size + 2) / 3
            val cellSize = (maxWidth - 12.dp) / 3
            LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                modifier = Modifier
                    .fillMaxWidth()
                    .height(cellSize * rows + 2.dp * (rows - 1) + 16.dp)
                    .padding(horizontal = 4.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
                userScrollEnabled = false
            ) {
                items(filteredClips, key = { it.id }) { clip ->
                    val category = when {
                        clip.isReel -> ClipCategoryType.REEL
                        clip.highlightIndex != null -> ClipCategoryType.HIGHLIGHT
                        else -> ClipCategoryType.FULL_RECORDING
                    }

                    UnifiedGridCardView(
                        clip = clip,
                        category = category,
                        remainingLabel = if (category == ClipCategoryType.FULL_RECORDING && retentionDays > 0 && !session.originalVideoAutoDeleteDisabled) {
                            val remaining = (session.createdAt + retentionDays * 86_400_000L - nowMs).coerceAtLeast(0L)
                            if (remaining >= 86_400_000L) "${ceil(remaining / 86_400_000.0).toInt()}d"
                            else "${ceil(remaining / 3_600_000.0).toInt().coerceIn(1, 23)}h"
                        } else null,
                        onRetentionClick = { showRetentionInfo = true },
                        isSelected = clip.id in selectedClipIds,
                        isReelSelected = clip.id in selectedReelClipIds,
                        isSelectionMode = isSelectionMode,
                        isReelSelectionMode = isReelSelectionMode,
                        onClick = {
                            if (isSelectionMode) onToggleSelect(clip.id)
                            else if (isReelSelectionMode) onToggleReelSelect(clip.id)
                            else onClipClick(clip)
                        }
                    )
                }
            }
            }
        }
    }
    if (showRetentionInfo) AlertDialog(
        onDismissRequest = { showRetentionInfo = false },
        title = { Text("Original Video Auto-Delete") },
        text = { Text("Automatic deletion is enabled for this original video to save storage. Disable auto-delete to keep it. Your saved highlights and reels will remain in the library.") },
        confirmButton = { TextButton(onClick = { onDisableAutoDelete(); showRetentionInfo = false }) { Text("Disable Auto-Delete", color = CrimsonBlaze) } },
        dismissButton = { TextButton(onClick = { showRetentionInfo = false }) { Text("OK") } }
    )
}

private fun displaySessionName(name: String): String {
    val match = Regex("^Session (\\d{2}/\\d{2}) (\\d{2}):(\\d{2})$").matchEntire(name)
        ?: return name
    val hour = match.groupValues[2].toInt()
    return "Session ${match.groupValues[1]} ${if (hour % 12 == 0) 12 else hour % 12}:${match.groupValues[3]} ${if (hour < 12) "AM" else "PM"}"
}

// MARK: - Grid Video Card Thumbnail

@Composable
fun UnifiedGridCardView(
    clip: Clip,
    category: ClipCategoryType,
    remainingLabel: String?,
    onRetentionClick: () -> Unit,
    isSelected: Boolean,
    isReelSelected: Boolean,
    isSelectionMode: Boolean,
    isReelSelectionMode: Boolean,
    onClick: () -> Unit
) {
    val preview = rememberVideoPreview(clip.filePath)

    Box(
        modifier = Modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(6.dp))
            .background(category.color.copy(alpha = 0.25f))
            .border(
                width = if (isReelSelectionMode && isReelSelected) 4.dp else 2.dp,
                color = if (isReelSelectionMode && isReelSelected) BlueMarble else category.color,
                shape = RoundedCornerShape(6.dp)
            )
            .clickable { onClick() }
    ) {
        if (preview?.bitmap != null) {
            Image(
                bitmap = preview.bitmap.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop
            )
        } else if (preview == null && clip.filePath != null) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(modifier = Modifier.size(24.dp), color = CosmosBlue)
            }
        } else {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Icon(Icons.Default.Videocam, contentDescription = "Video preview unavailable", tint = Color.White.copy(alpha = 0.65f))
            }
        }

        // Gradient Scrims
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(40.dp)
                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.6f), Color.Transparent)))
        )
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(60.dp)
                .align(Alignment.BottomCenter)
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.85f))))
        )

        // Overlay UI Elements
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(6.dp),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                if (isSelectionMode) {
                    Icon(
                        imageVector = if (isSelected) Icons.Default.CheckCircle else Icons.Outlined.Circle,
                        contentDescription = null,
                        tint = if (isSelected) category.color else Color.White,
                        modifier = Modifier.size(20.dp)
                    )
                } else if (isReelSelectionMode) {
                    Icon(
                        imageVector = if (isReelSelected) Icons.Default.CheckCircle else Icons.Outlined.Circle,
                        contentDescription = null,
                        tint = if (isReelSelected) BlueMarble else Color.White,
                        modifier = Modifier.size(20.dp)
                    )
                } else if (clip.isFavorite) {
                    Icon(
                        imageVector = Icons.Default.Favorite,
                        contentDescription = null,
                        tint = CrimsonBlaze,
                        modifier = Modifier
                            .size(16.dp)
                            .background(Color.Black.copy(alpha = 0.5f), CircleShape)
                            .padding(2.dp)
                    )
                } else {
                    Spacer(modifier = Modifier.size(1.dp))
                }

                if (!isSelectionMode && !isReelSelectionMode) {
                    Surface(
                        color = Color.Black.copy(alpha = 0.65f),
                        shape = CapsuleShape
                    ) {
                        Text(
                            text = preview?.durationLabel ?: clip.durationLabel.takeIf { it.contains(':') } ?: "0:00",
                            color = Color.White,
                            style = MaterialTheme.typography.labelSmall.copy(
                                fontSize = 9.sp,
                                fontWeight = FontWeight.Bold
                            ),
                            modifier = Modifier.padding(horizontal = 5.dp, vertical = 2.dp)
                        )
                    }
                }
            }

            Text(
                text = clip.displayName.replace(Regex("^Moment (\\d+)$"), "Clip #$1"),
                modifier = Modifier,
                color = Color.White,
                style = MaterialTheme.typography.labelMedium.copy(
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp
                ),
                maxLines = 2
            )
        }
        if (remainingLabel != null) {
            Surface(
                onClick = onRetentionClick,
                modifier = Modifier.align(Alignment.TopStart)
                    .padding(start = if (isSelectionMode || isReelSelectionMode || clip.isFavorite) 34.dp else 8.dp, top = 8.dp),
                color = Color.Black.copy(alpha = 0.7f), shape = CircleShape
            ) {
                Row(modifier = Modifier.padding(horizontal = 7.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Timer, contentDescription = null, tint = Color.White, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.width(3.dp))
                    Text(remainingLabel, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

// MARK: - Helpers & Bottom Bars

private data class VideoPreview(val bitmap: Bitmap?, val durationLabel: String?)

@Composable
private fun rememberVideoPreview(filePath: String?): VideoPreview? {
    val context = LocalContext.current
    var preview by remember(filePath) { mutableStateOf<VideoPreview?>(null) }
    LaunchedEffect(filePath) {
        if (!filePath.isNullOrEmpty()) {
            preview = withContext(Dispatchers.IO) {
                val retriever = MediaMetadataRetriever()
                try {
                    val uri = if (filePath.contains("://")) filePath.toUri() else Uri.fromFile(File(filePath))
                    retriever.setDataSource(context, uri)
                    val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
                    val frame = retriever.getFrameAtTime((durationMs / 2).coerceAtLeast(0L) * 1000,
                        MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                    val totalSeconds = (durationMs / 1000).coerceAtLeast(0L)
                    val label = if (totalSeconds >= 3600) "%d:%02d:%02d".format(totalSeconds / 3600, totalSeconds / 60 % 60, totalSeconds % 60)
                        else "%d:%02d".format(totalSeconds / 60, totalSeconds % 60)
                    VideoPreview(frame, label)
                } catch (e: Exception) {
                    VideoPreview(null, null)
                } finally {
                    retriever.release()
                }
            }
        }
    }
    return preview
}

@Composable
fun SelectionBottomBar(selectedCount: Int, onShare: () -> Unit, onDelete: () -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = MaterialTheme.colorScheme.surfaceVariant,
        tonalElevation = 8.dp
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 28.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = onShare, enabled = selectedCount > 0) {
                Icon(Icons.Default.Share, contentDescription = "Share")
            }
            IconButton(onClick = onDelete, enabled = selectedCount > 0) {
                Icon(Icons.Default.Delete, contentDescription = "Delete", tint = CrimsonBlaze)
            }
        }
    }
}

@Composable
fun EmptyStateView(filter: ClipFilter = ClipFilter.ALL) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(top = 100.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Icon(if (filter == ClipFilter.REELS) Icons.Default.Movie else Icons.Default.VideoLibrary, contentDescription = null, modifier = Modifier.size(48.dp), tint = Color.Gray)
        Text(if (filter == ClipFilter.REELS) "No Reels Yet" else "No Clips Yet", style = MaterialTheme.typography.titleMedium.copy(fontWeight = FontWeight.Bold), color = CosmosBlue)
        Text(if (filter == ClipFilter.REELS) "Create a reel from your highlights to see it here." else "Head to Record to start capturing highlights.", style = MaterialTheme.typography.bodyMedium, color = Color.Gray)
    }
}

@Composable
fun RenameSessionDialog(currentName: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
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
        title = { Text("Rename Session") },
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

val CapsuleShape = RoundedCornerShape(50)
