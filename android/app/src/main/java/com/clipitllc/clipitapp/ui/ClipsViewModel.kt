package com.clipitllc.clipitapp.ui

import android.app.Application
import android.content.ContentValues
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Color as AndroidColor
import androidx.core.graphics.createBitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.AtomicFile
import android.util.Log
import androidx.core.content.edit
import androidx.core.net.toUri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import com.clipitllc.clipitapp.services.RetentionScheduler
import com.clipitllc.clipitapp.camera.RecordingWindow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

enum class RecoveredClipResult { REGISTERED, AWAITING_RECORDING, RETRY, NO_RECORDING }

data class RecoveredExtractionProgress(val sessionId: String, val current: Int, val total: Int)

private data class RecoveredMarker(
    val key: String,
    val sourceUri: String,
    val pressedAtMs: Long,
    val startedAtMs: Long,
    val highlightLengthMs: Long,
    val isFavorite: Boolean = false
)

class ClipsViewModel(application: Application) : AndroidViewModel(application) {

    private val settings = application.getSharedPreferences("clipit_settings", Application.MODE_PRIVATE)
    private val metadataFile = AtomicFile(File(application.filesDir, "clipit_sessions.json"))
    private val recoveredMarkerFile = AtomicFile(File(application.filesDir, "clipit_recovered_markers.json"))
    private val recoveredMarkers = loadRecoveredMarkers().toMutableMap()
    private val recoveredExports = mutableSetOf<String>()
    private val _sessions = MutableStateFlow(loadSessions())
    val sessions: StateFlow<List<Session>> = _sessions.asStateFlow()
    private val _recoveredExtractionProgress = MutableStateFlow<RecoveredExtractionProgress?>(null)
    val recoveredExtractionProgress: StateFlow<RecoveredExtractionProgress?> = _recoveredExtractionProgress.asStateFlow()
    private var pendingHighlightLengthMs: Long = 10_000L

    init {
        reconcileRecoveredMarkers()
        applyOriginalVideoRetention()
        scheduleRetention()
        _sessions.value.filterNot { it.isProcessing }.forEach { processRecoveredClips(it.id) }
    }

    fun scheduleRetention() {
        RetentionScheduler.schedule(getApplication(), _sessions.value, retentionDays(), settings.getBoolean("notifications_enabled", false))
    }

    fun storageUsedBytes(): Long = _sessions.value.flatMap { it.clips }.sumOf { clip ->
        val uri = clip.filePath?.let(Uri::parse) ?: return@sumOf 0L
        try {
            if (uri.scheme == "file") File(uri.path ?: "").length()
            else getApplication<Application>().contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length.coerceAtLeast(0L) } ?: 0L
        } catch (_: Exception) { 0L }
    }

    private fun deleteVideo(path: String): Boolean = try {
        val uri = path.toUri()
        if (uri.scheme == "file") uri.path?.let { File(it).delete() } ?: false
        else getApplication<Application>().contentResolver.delete(uri, null, null) > 0
    } catch (error: Exception) {
        Log.e("ClipsViewModel", "Could not delete video", error)
        false
    }

    fun retentionDays(): Int = settings.getInt("original_video_retention_days", 0)

    fun setRetentionDays(days: Int) {
        settings.edit { putInt("original_video_retention_days", days) }
        applyOriginalVideoRetention()
        scheduleRetention()
    }

    fun disableOriginalVideoAutoDelete(sessionId: String) {
        publish(_sessions.value.map { if (it.id == sessionId) it.copy(originalVideoAutoDeleteDisabled = true) else it })
    }

    fun applyOriginalVideoRetention() {
        val days = retentionDays()
        if (days == 0) return
        val cutoff = System.currentTimeMillis() - days * 86_400_000L
        var changed = false
        val updated = _sessions.value.map { session ->
            if (session.createdAt > cutoff || session.originalVideoAutoDeleteDisabled ||
                session.clips.any { it.recoveryKey != null && it.filePath == null }) session else {
                val originals = session.clips.filter { it.highlightIndex == null && !it.isReel }
                if (originals.isNotEmpty()) changed = true
                val removed = originals.filter { clip -> clip.filePath?.let(::deleteVideo) ?: true }
                session.copy(clips = session.clips - removed.toSet())
            }
        }.filter { it.clips.isNotEmpty() }
        if (changed) publish(updated)
    }

    private fun publish(sessions: List<Session>) {
        _sessions.value = sessions
        try {
            val bytes = JSONArray().apply {
                sessions.forEach { session ->
                    put(JSONObject().apply {
                        put("id", session.id)
                        put("name", session.name)
                        put("formattedDate", session.formattedDate)
                        put("durationLabel", session.durationLabel)
                        put("createdAt", session.createdAt)
                        put("originalVideoAutoDeleteDisabled", session.originalVideoAutoDeleteDisabled)
                        put("recordingUri", session.recordingUri)
                        put("recordingStartedAtMs", session.recordingStartedAtMs)
                        put("recordingEndedAtMs", session.recordingEndedAtMs)
                        put("highlightLengthMs", session.highlightLengthMs)
                        put("clips", JSONArray().apply {
                            session.clips.forEach { clip ->
                                put(JSONObject().apply {
                                    put("id", clip.id)
                                    put("displayName", clip.displayName)
                                    put("filePath", clip.filePath)
                                    put("durationLabel", clip.durationLabel)
                                    put("isFavorite", clip.isFavorite)
                                    put("isReel", clip.isReel)
                                    put("highlightIndex", clip.highlightIndex)
                                    put("isSecondaryAngle", clip.isSecondaryAngle)
                                    put("timestamp", clip.timestamp)
                                    put("sourceStartMs", clip.sourceStartMs)
                                    put("sourceEndMs", clip.sourceEndMs)
                                    put("isProcessing", clip.isProcessing)
                                    put("recoveryKey", clip.recoveryKey)
                                })
                            }
                        })
                    })
                }
            }.toString().toByteArray(Charsets.UTF_8)
            val stream = metadataFile.startWrite()
            try {
                stream.write(bytes)
                metadataFile.finishWrite(stream)
            } catch (error: Exception) {
                metadataFile.failWrite(stream)
                throw error
            }
        } catch (error: Exception) {
            Log.e("ClipsViewModel", "Could not save library", error)
        }
        scheduleRetention()
    }

    private fun loadSessions(): List<Session> = try {
        val array = JSONArray(String(metadataFile.openRead().use { it.readBytes() }, Charsets.UTF_8))
        (0 until array.length()).map { index ->
            val session = array.getJSONObject(index)
            val clipsArray = session.getJSONArray("clips")
            Session(
                id = session.getString("id"),
                name = session.getString("name"),
                formattedDate = session.getString("formattedDate"),
                durationLabel = session.getString("durationLabel").replace("Moments", "Clips"),
                createdAt = session.optLong("createdAt", System.currentTimeMillis()),
                originalVideoAutoDeleteDisabled = session.optBoolean("originalVideoAutoDeleteDisabled", false),
                recordingUri = session.optString("recordingUri").takeIf { it.isNotEmpty() && it != "null" },
                recordingStartedAtMs = session.optLong("recordingStartedAtMs").takeIf { !session.isNull("recordingStartedAtMs") && it > 0 },
                recordingEndedAtMs = session.optLong("recordingEndedAtMs").takeIf { !session.isNull("recordingEndedAtMs") && it > 0 },
                highlightLengthMs = session.optLong("highlightLengthMs").takeIf { !session.isNull("highlightLengthMs") && it > 0 },
                clips = (0 until clipsArray.length()).map { clipIndex ->
                    val clip = clipsArray.getJSONObject(clipIndex)
                    Clip(
                        id = clip.getString("id"),
                        displayName = clip.getString("displayName").replace(Regex("^Moment (\\d+)$"), "Clip #$1"),
                        filePath = clip.optString("filePath").takeIf { it.isNotEmpty() && it != "null" },
                        durationLabel = clip.optString("durationLabel", "Clip"),
                        isFavorite = clip.optBoolean("isFavorite"),
                        isReel = clip.optBoolean("isReel"),
                        highlightIndex = if (clip.isNull("highlightIndex")) null else clip.optInt("highlightIndex"),
                        isSecondaryAngle = clip.optBoolean("isSecondaryAngle"),
                        timestamp = if (clip.isNull("timestamp")) null else clip.optLong("timestamp"),
                        sourceStartMs = if (clip.isNull("sourceStartMs")) null else clip.optLong("sourceStartMs"),
                        sourceEndMs = if (clip.isNull("sourceEndMs")) null else clip.optLong("sourceEndMs"),
                        isProcessing = clip.optBoolean("isProcessing"),
                        recoveryKey = clip.optString("recoveryKey").takeIf { it.isNotEmpty() && it != "null" }
                    )
                }
            )
        }
    } catch (error: Exception) {
        if (metadataFile.baseFile.exists()) Log.e("ClipsViewModel", "Could not read library", error)
        emptyList()
    }

    private fun loadRecoveredMarkers(): Map<String, RecoveredMarker> = try {
        val array = JSONArray(String(recoveredMarkerFile.openRead().use { it.readBytes() }, Charsets.UTF_8))
        (0 until array.length()).associate { index ->
            val item = array.getJSONObject(index)
            val marker = RecoveredMarker(item.getString("key"), item.getString("sourceUri"),
                item.getLong("pressedAtMs"), item.getLong("startedAtMs"), item.getLong("highlightLengthMs"),
                item.optBoolean("isFavorite"))
            marker.key to marker
        }
    } catch (error: Exception) {
        if (recoveredMarkerFile.baseFile.exists()) Log.e("ClipsViewModel", "Could not read recovered markers", error)
        emptyMap()
    }

    private fun saveRecoveredMarkers(): Boolean = try {
        val bytes = JSONArray().apply {
            recoveredMarkers.values.forEach { marker ->
                put(JSONObject().apply {
                    put("key", marker.key)
                    put("sourceUri", marker.sourceUri)
                    put("pressedAtMs", marker.pressedAtMs)
                    put("startedAtMs", marker.startedAtMs)
                    put("highlightLengthMs", marker.highlightLengthMs)
                    put("isFavorite", marker.isFavorite)
                })
            }
        }.toString().toByteArray(Charsets.UTF_8)
        val stream = recoveredMarkerFile.startWrite()
        try {
            stream.write(bytes)
            recoveredMarkerFile.finishWrite(stream)
        } catch (error: Exception) {
            recoveredMarkerFile.failWrite(stream)
            throw error
        }
        true
    } catch (error: Exception) {
        Log.e("ClipsViewModel", "Could not persist recovered marker", error)
        false
    }

    private fun originalSource(session: Session): String? = session.recordingUri ?: session.clips
        .firstOrNull { it.highlightIndex == null && !it.isReel }?.filePath

    private fun videoDurationMs(source: String): Long? = try {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(getApplication(), source.toUri())
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
        } finally { retriever.release() }
    } catch (_: Exception) { null }

    private fun sessionStartMs(session: Session): Long? = session.recordingStartedAtMs ?:
        originalSource(session)?.let(::videoDurationMs)?.let { session.createdAt - it }

    fun registerRecoveredButtonClip(key: String, pressedAtMs: Long, recordingWindow: RecordingWindow?): RecoveredClipResult {
        if (recoveredMarkers.containsKey(key) || _sessions.value.any { session ->
                session.clips.any { it.recoveryKey == key }
            }) return RecoveredClipResult.REGISTERED
        val now = System.currentTimeMillis()
        if (pressedAtMs > now + 500 || pressedAtMs < now - 48L * 60 * 60 * 1000)
            return RecoveredClipResult.NO_RECORDING

        val activeSource = recordingWindow?.takeIf { it.contains(pressedAtMs) }?.sourceUri
        val session = if (activeSource != null) {
            _sessions.value.firstOrNull { originalSource(it) == activeSource }
        } else _sessions.value.firstOrNull { candidate ->
            val start = sessionStartMs(candidate) ?: return@firstOrNull false
            RecoveryTiming.belongsToRecording(pressedAtMs, start,
                candidate.recordingEndedAtMs ?: candidate.createdAt)
        }
        val source = activeSource ?: session?.let(::originalSource)
            ?: return RecoveredClipResult.NO_RECORDING
        if (session != null && source.toUri().scheme == "file" &&
            source.toUri().path?.let(::File)?.isFile != true) return RecoveredClipResult.NO_RECORDING
        val startedAt = session?.let(::sessionStartMs) ?: recordingWindow?.startedAtMs
            ?: return RecoveredClipResult.RETRY
        val length = session?.highlightLengthMs ?: recordingWindow?.highlightLengthMs
            ?: settings.getInt("highlight_length", 10) * 1000L
        val marker = RecoveredMarker(key, source, pressedAtMs, startedAt, length)
        recoveredMarkers[key] = marker
        if (!saveRecoveredMarkers()) {
            recoveredMarkers.remove(key)
            return RecoveredClipResult.RETRY
        }
        if (session != null) {
            publish(_sessions.value.map { if (it.id == session.id) attachRecoveredMarkers(it) else it })
            if (!session.isProcessing) processRecoveredClips(session.id)
            return RecoveredClipResult.REGISTERED
        }
        return RecoveredClipResult.AWAITING_RECORDING
    }

    fun favoriteRecoveredMarker(key: String): Boolean {
        val marker = recoveredMarkers[key] ?: return false
        recoveredMarkers[key] = marker.copy(isFavorite = true)
        if (!saveRecoveredMarkers()) {
            recoveredMarkers[key] = marker
            return false
        }
        publish(_sessions.value.map { session ->
            session.copy(clips = session.clips.map { clip ->
                if (clip.recoveryKey == key) clip.copy(isFavorite = true) else clip
            })
        })
        return true
    }

    private fun attachRecoveredMarkers(session: Session): Session {
        val source = originalSource(session) ?: return session
        val existing = session.clips.mapNotNull { it.recoveryKey }.toSet()
        val additions = recoveredMarkers.values.filter { it.sourceUri == source && it.key !in existing }
            .map { marker ->
                val offset = RecoveryTiming.offsetMs(marker.pressedAtMs, marker.startedAtMs)
                Clip(
                    id = UUID.nameUUIDFromBytes(marker.key.toByteArray(Charsets.UTF_8)).toString(),
                    displayName = "Clip #1",
                    filePath = null,
                    durationLabel = formatTimestamp(minOf(offset, marker.highlightLengthMs)),
                    highlightIndex = 1,
                    timestamp = offset,
                    sourceStartMs = (offset - marker.highlightLengthMs).coerceAtLeast(0),
                    sourceEndMs = offset,
                    isProcessing = true,
                    isFavorite = marker.isFavorite,
                    recoveryKey = marker.key
                )
            }
        return if (additions.isEmpty()) session else renumberClips(session.copy(clips = session.clips + additions))
    }

    private fun renumberClips(session: Session): Session {
        val ordered = session.clips.filter { it.highlightIndex != null && !it.isReel && !it.isSecondaryAngle }
            .sortedWith(compareBy<Clip> { it.timestamp ?: Long.MAX_VALUE }.thenBy { it.id })
        val numbers = ordered.mapIndexed { index, clip -> clip.id to index + 1 }.toMap()
        return session.copy(
            clips = session.clips.map { clip ->
                val number = numbers[clip.id] ?: return@map clip
                clip.copy(highlightIndex = number,
                    displayName = if (clip.displayName.matches(Regex("Clip #\\d+"))) "Clip #$number" else clip.displayName)
            },
            durationLabel = "${ordered.size} Clips"
        )
    }

    private fun reconcileRecoveredMarkers() {
        val existingSources = _sessions.value.mapNotNull(::originalSource).toSet()
        val orphaned = recoveredMarkers.values.groupBy { it.sourceUri }
            .filterKeys { it !in existingSources }
            .mapNotNull { (source, markers) ->
                val file = source.toUri().path?.let(::File)
                val duration = if (file?.isFile == true) videoDurationMs(source) else null
                if (duration == null || duration <= 0) return@mapNotNull null
                val start = markers.minOf { it.startedAtMs }
                val ended = start + duration
                val date = Date(ended)
                attachRecoveredMarkers(Session(
                    name = "New Recording - ${SimpleDateFormat("h:mm a", Locale.getDefault()).format(date).lowercase(Locale.getDefault())}",
                    formattedDate = SimpleDateFormat("MMM dd, yyyy", Locale.getDefault()).format(date),
                    durationLabel = "0 Clips",
                    clips = listOf(Clip(displayName = "Original Video", filePath = source,
                        durationLabel = formatTimestamp(duration))),
                    createdAt = ended,
                    recordingUri = source,
                    recordingStartedAtMs = start,
                    recordingEndedAtMs = ended,
                    highlightLengthMs = markers.first().highlightLengthMs
                ))
            }
        val updated = (_sessions.value + orphaned).map(::attachRecoveredMarkers)
        if (updated != _sessions.value) publish(updated)
    }

    fun addRecording(uri: Uri, highlights: List<Long>, window: RecordingWindow): Int {
        pendingHighlightLengthMs = window.highlightLengthMs
        val dateFormat = SimpleDateFormat("MMM dd, yyyy", Locale.getDefault())
        val nameFormat = SimpleDateFormat("h:mm a", Locale.getDefault())
        val now = Date()
        
        val clips = mutableListOf<Clip>()
        
        // Add original video
        clips.add(
            Clip(
                displayName = "Original Video",
                filePath = uri.toString(),
                durationLabel = "0:00",
                highlightIndex = null
            )
        )
        
        // Highlights are now separate files being extracted. 
        // We'll add them as they come in via addExtractedHighlight.
        
        val newSession = Session(
            name = "New Recording - ${nameFormat.format(now).lowercase(Locale.getDefault())}",
            formattedDate = dateFormat.format(now),
            durationLabel = if (highlights.isEmpty()) "0 Clips" else "Processing...",
            clips = clips,
            isProcessing = highlights.isNotEmpty(),
            processingProgress = 0f,
            recordingUri = uri.toString(),
            recordingStartedAtMs = window.startedAtMs,
            recordingEndedAtMs = window.endedAtMs,
            highlightLengthMs = window.highlightLengthMs
        )
        
        val sessionWithRecoveredClips = attachRecoveredMarkers(newSession)
        publish(_sessions.value + sessionWithRecoveredClips)
        if (highlights.isEmpty()) processRecoveredClips(newSession.id)
        return sessionWithRecoveredClips.clips.count { it.recoveryKey != null }
    }

    fun updateExtractionProgress(sourceUri: Uri, current: Int, total: Int) {
        val currentSessions = _sessions.value
        if (currentSessions.isEmpty() || total == 0) return
        
        val lastSession = currentSessions.firstOrNull { it.recordingUri == sourceUri.toString() } ?: return
        val progress = current.toFloat() / total.toFloat()
        
        val updatedSession = lastSession.copy(
            processingProgress = progress,
            isProcessing = current < total
        )
        
        publish(currentSessions.map { if (it.id == lastSession.id) updatedSession else it })
        if (current >= total) processRecoveredClips(lastSession.id)
    }

    fun addExtractedHighlight(uri: Uri, sourceUri: Uri, highlightNumber: Int, triggerMs: Long, isFavorite: Boolean = false) {
        val currentSessions = _sessions.value
        if (currentSessions.isEmpty()) return
        
        val lastSession = currentSessions.firstOrNull { it.recordingUri == sourceUri.toString() } ?: return
        val newClip = Clip(
            displayName = "Clip #$highlightNumber",
            filePath = uri.toString(),
            durationLabel = "0:00",
            highlightIndex = highlightNumber,
            isFavorite = isFavorite,
            timestamp = triggerMs,
            sourceStartMs = (triggerMs - (lastSession.highlightLengthMs ?: pendingHighlightLengthMs)).coerceAtLeast(0L),
            sourceEndMs = triggerMs,
            isReel = false,
            isProcessing = false
        )
        
        val updatedSession = renumberClips(lastSession.copy(
            clips = lastSession.clips + newClip,
            durationLabel = "${lastSession.clips.count { it.highlightIndex != null } + 1} Clips"
        ))
        
        publish(currentSessions.map { if (it.id == lastSession.id) updatedSession else it })
    }

    @androidx.annotation.OptIn(UnstableApi::class)
    private fun processRecoveredClips(sessionId: String) {
        if (sessionId in recoveredExports) return
        val session = _sessions.value.firstOrNull { it.id == sessionId && !it.isProcessing } ?: return
        val recovered = session.clips.filter { it.recoveryKey != null }
        val clip = recovered.firstOrNull { it.filePath == null && it.isProcessing }
        if (clip == null) {
            if (_recoveredExtractionProgress.value?.sessionId == sessionId) _recoveredExtractionProgress.value = null
            return
        }
        val source = originalSource(session) ?: return
        val sourceFile = source.toUri().path?.let(::File) ?: return
        if (!sourceFile.isFile) return
        val start = clip.sourceStartMs ?: return
        val end = clip.sourceEndMs ?: return
        val duration = videoDurationMs(source) ?: return
        val safeEnd = end.coerceAtMost(duration)
        if (safeEnd <= start) return
        _recoveredExtractionProgress.value = RecoveredExtractionProgress(
            sessionId, recovered.count { it.filePath != null }, recovered.size
        )
        recoveredExports.add(sessionId)
        val app = getApplication<Application>()
        val temp = File(app.cacheDir, "recovered_${clip.id}.mp4")
        temp.delete()
        val mediaItem = MediaItem.Builder().setUri(source.toUri()).setClippingConfiguration(
            MediaItem.ClippingConfiguration.Builder()
                .setStartPositionMs(start)
                .setEndPositionMs(safeEnd)
                .build()
        ).build()
        val transformer = Transformer.Builder(app).build()
        transformer.addListener(object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                viewModelScope.launch(Dispatchers.Main) {
                    try {
                        if (_sessions.value.none { it.id == sessionId }) return@launch
                        val destination = File(File(app.filesDir, "Clips").apply { mkdirs() }, "ClipIt_Recovered_${clip.id}.mp4")
                        temp.copyTo(destination, overwrite = true)
                        publish(_sessions.value.map { current ->
                            if (current.id != sessionId) current else current.copy(clips = current.clips.map { existing ->
                                if (existing.id == clip.id) existing.copy(
                                    filePath = Uri.fromFile(destination).toString(),
                                    durationLabel = formatTimestamp(safeEnd - start),
                                    isProcessing = false
                                ) else existing
                            })
                        })
                    } catch (error: Exception) {
                        Log.e("ClipsViewModel", "Could not save recovered clip", error)
                    } finally {
                        temp.delete()
                        recoveredExports.remove(sessionId)
                        if (_sessions.value.firstOrNull { it.id == sessionId }?.clips?.any {
                                it.id == clip.id && it.filePath != null
                            } == true) processRecoveredClips(sessionId)
                        else if (_recoveredExtractionProgress.value?.sessionId == sessionId)
                            _recoveredExtractionProgress.value = null
                    }
                }
            }

            override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                viewModelScope.launch(Dispatchers.Main) {
                    temp.delete()
                    recoveredExports.remove(sessionId)
                    if (_recoveredExtractionProgress.value?.sessionId == sessionId)
                        _recoveredExtractionProgress.value = null
                    Log.e("ClipsViewModel", "Could not export recovered clip", exportException)
                }
            }
        })
        try { transformer.start(EditedMediaItem.Builder(mediaItem).build(), temp.absolutePath) }
        catch (error: Exception) {
            temp.delete()
            recoveredExports.remove(sessionId)
            if (_recoveredExtractionProgress.value?.sessionId == sessionId)
                _recoveredExtractionProgress.value = null
            Log.e("ClipsViewModel", "Could not start recovered clip export", error)
        }
    }

    private fun formatTimestamp(ms: Long): String {
        val seconds = (ms / 1000) % 60
        val minutes = (ms / (1000 * 60)) % 60
        return String.format(java.util.Locale.getDefault(), "%d:%02d", minutes, seconds)
    }
    
    fun deleteClip(sessionId: String, clipId: String) {
        val clip = _sessions.value.firstOrNull { it.id == sessionId }?.clips?.firstOrNull { it.id == clipId }
        clip?.recoveryKey?.let { key ->
            recoveredMarkers.remove(key)
            saveRecoveredMarkers()
        }
        clip?.filePath?.let(::deleteVideo)
        publish(_sessions.value.map { session ->
            if (session.id == sessionId) {
                session.copy(clips = session.clips.filter { it.id != clipId })
            } else {
                session
            }
        }.filter { it.clips.isNotEmpty() })
    }

    fun deleteSession(sessionId: String) {
        val session = _sessions.value.firstOrNull { it.id == sessionId } ?: return
        originalSource(session)?.let { source ->
            recoveredMarkers.entries.removeAll { it.value.sourceUri == source }
            saveRecoveredMarkers()
        }
        publish(_sessions.value.filterNot { it.id == sessionId })
        session.clips.mapNotNull { it.filePath }.distinct().forEach(::deleteVideo)
    }
    
    fun renameSession(sessionId: String, newName: String) {
        publish(_sessions.value.map { session ->
            if (session.id == sessionId) {
                session.copy(name = newName)
            } else {
                session
            }
        })
    }

    fun renameClip(clipId: String, newName: String) {
        publish(_sessions.value.map { session ->
            session.copy(clips = session.clips.map { clip ->
                if (clip.id == clipId) clip.copy(displayName = newName) else clip
            })
        })
    }

    fun toggleFavorite(clipId: String) {
        publish(_sessions.value.map { session ->
            session.copy(clips = session.clips.map { clip ->
                if (clip.id == clipId) clip.copy(isFavorite = !clip.isFavorite) else clip
            })
        })
    }

    @androidx.annotation.OptIn(UnstableApi::class)
    fun createReel(clips: List<Clip>, title: String, titleColor: Int, onComplete: (Boolean, String) -> Unit) {
        val sourceClips = clips.filter { it.filePath != null }
        if (sourceClips.isEmpty()) {
            onComplete(false, "Choose at least one saved highlight")
            return
        }
        val app = getApplication<Application>()
        val temp = File(app.cacheDir, "reel_${System.currentTimeMillis()}.mp4")
        val titleFile = if (title.isNotBlank()) createTitleCard(app, sourceClips.first(), title, titleColor) else null
        val items = buildList {
            if (titleFile != null) add(EditedMediaItem.Builder(
                MediaItem.Builder().setUri(Uri.fromFile(titleFile)).build()
            ).setDurationUs(3_000_000).setFrameRate(30).build())
            addAll(sourceClips.map { EditedMediaItem.Builder(MediaItem.fromUri(it.filePath!!)).build() })
        }
        // A still title card has no audio. Keep an audio track across that opening gap
        // so the muxer can accept the recorded clips' audio when they follow it.
        val composition = Composition.Builder(EditedMediaItemSequence(items))
            .experimentalSetForceAudioTrack(titleFile != null)
            .build()
        val transformer = Transformer.Builder(app).build()
        transformer.addListener(object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                    try {
                        val destination = File(File(app.filesDir, "Reels").apply { mkdirs() }, "ClipIt_Reel_${System.currentTimeMillis()}.mp4")
                        temp.copyTo(destination, overwrite = true)
                        val uri = Uri.fromFile(destination)
                        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                            val targetId = _sessions.value.firstOrNull { session -> session.clips.any { clip -> clip.id == sourceClips.first().id } }?.id
                            publish(_sessions.value.map { session ->
                                if (session.id == targetId) session.copy(clips = session.clips + Clip(
                                    displayName = title.trim().ifBlank { "ClipIt Highlight Reel" },
                                    filePath = uri.toString(),
                                    durationLabel = "Reel",
                                    isReel = true
                                )) else session
                            })
                            onComplete(true, "Reel saved")
                        }
                    } catch (error: Exception) {
                        Log.e("ClipsViewModel", "Could not save reel", error)
                        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { onComplete(false, "Could not save reel") }
                    } finally {
                        temp.delete()
                        titleFile?.delete()
                    }
                }
            }

            override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                temp.delete()
                titleFile?.delete()
                Log.e("ClipsViewModel", "Could not export reel (code ${exportException.errorCode})", exportException)
                onComplete(false, "Could not create reel. Please try again with different highlights.")
            }
        })
        try {
            transformer.start(composition, temp.absolutePath)
        } catch (error: Exception) {
            temp.delete()
            titleFile?.delete()
            Log.e("ClipsViewModel", "Could not start reel export", error)
            onComplete(false, error.localizedMessage ?: "Could not create reel")
        }
    }

    private fun createTitleCard(app: Application, firstClip: Clip, title: String, backgroundColor: Int): File? = try {
        val metadata = MediaMetadataRetriever()
        var landscape = false
        try {
            metadata.setDataSource(app, firstClip.filePath.orEmpty().toUri())
            val width = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 1080
            val height = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 1920
            val rotation = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            landscape = if (rotation % 180 == 0) width > height else height > width
        } finally { metadata.release() }
        val width = if (landscape) 1920 else 1080
        val height = if (landscape) 1080 else 1920
        val bitmap = createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(backgroundColor)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = if (backgroundColor == AndroidColor.WHITE || backgroundColor == AndroidColor.YELLOW) AndroidColor.BLACK else AndroidColor.WHITE
            textAlign = Paint.Align.CENTER
            textSize = if (landscape) 78f else 70f
            typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.BOLD)
        }
        val lines = title.trim().lines().take(6)
        val lineHeight = paint.textSize * 1.35f
        val startY = height / 2f - lineHeight * (lines.size - 1) / 2f
        lines.forEachIndexed { index, line -> canvas.drawText(line.take(35), width / 2f, startY + index * lineHeight, paint) }
        val file = File(app.cacheDir, "title_${System.currentTimeMillis()}.png")
        file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        file
    } catch (error: Exception) {
        Log.e("ClipsViewModel", "Could not create title card", error)
        null
    }

    @androidx.annotation.OptIn(UnstableApi::class)
    fun trimClip(clip: Clip, startMs: Long, endMs: Long, asNewClip: Boolean, onComplete: (Boolean) -> Unit) {
        val original = _sessions.value.firstOrNull { session -> session.clips.any { it.id == clip.id } }
            ?.clips?.firstOrNull { it.highlightIndex == null && !it.isReel }
        val useOriginal = clip.highlightIndex != null && clip.sourceStartMs != null && original?.filePath != null
        val source = (if (useOriginal) original?.filePath else clip.filePath) ?: run { onComplete(false); return }
        if (endMs <= startMs) { onComplete(false); return }
        val app = getApplication<Application>()
        val temp = File(app.cacheDir, "trim_${System.currentTimeMillis()}.mp4")
        val item = MediaItem.Builder().setUri(source).setClippingConfiguration(
            MediaItem.ClippingConfiguration.Builder()
                .setStartPositionMs(startMs)
                .setEndPositionMs(endMs)
                .build()
        ).build()
        val transformer = Transformer.Builder(app).build()
        transformer.addListener(object : Transformer.Listener {
            override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
                    try {
                        val destination = File(File(app.filesDir, "Clips").apply { mkdirs() }, "ClipIt_Trim_${System.currentTimeMillis()}.mp4")
                        temp.copyTo(destination, overwrite = true)
                        val uri = Uri.fromFile(destination)
                        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                            publish(_sessions.value.map { session ->
                                if (!session.clips.any { it.id == clip.id }) session else if (asNewClip) {
                                    val index = (session.clips.mapNotNull { it.highlightIndex }.maxOrNull() ?: 0) + 1
                                    session.copy(clips = session.clips + Clip(
                                        displayName = "Clip #$index", filePath = uri.toString(),
                                        durationLabel = formatTimestamp(endMs - startMs), highlightIndex = index,
                                        sourceStartMs = startMs, sourceEndMs = endMs, timestamp = endMs
                                    ))
                                } else session.copy(clips = session.clips.map { existing ->
                                    if (existing.id == clip.id) existing.copy(
                                        filePath = uri.toString(), durationLabel = formatTimestamp(endMs - startMs),
                                        sourceStartMs = if (useOriginal) startMs else existing.sourceStartMs,
                                        sourceEndMs = if (useOriginal) endMs else existing.sourceEndMs
                                    ) else existing
                                })
                            })
                            onComplete(true)
                        }
                    } catch (error: Exception) {
                        Log.e("ClipsViewModel", "Could not save trim", error)
                        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) { onComplete(false) }
                    } finally { temp.delete() }
                }
            }

            override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                temp.delete()
                Log.e("ClipsViewModel", "Could not export trim", exportException)
                onComplete(false)
            }
        })
        try { transformer.start(EditedMediaItem.Builder(item).build(), temp.absolutePath) }
        catch (error: Exception) {
            temp.delete()
            Log.e("ClipsViewModel", "Could not start trim", error)
            onComplete(false)
        }
    }
}
