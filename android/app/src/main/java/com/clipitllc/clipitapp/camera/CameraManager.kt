package com.clipitllc.clipitapp.camera

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.util.Size
import androidx.annotation.OptIn
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.*
import androidx.camera.view.PreviewView
import androidx.core.content.edit
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

enum class VideoQualityOption(val label: String, val quality: Quality) {
    HD_720P("720p HD", Quality.HD),
    HD_1080P("1080p HD", Quality.FHD),
    UHD_4K("4K", Quality.UHD)
}

sealed class CameraEvent {
    object RecordingStarted : CameraEvent()
    data class MovieFileReady(val fileUri: Uri, val highlights: List<Long>, val window: RecordingWindow) : CameraEvent()
    data class HighlightMarked(val timestamp: Long, val highlightIndex: Int) : CameraEvent()
    data class RecoveredHighlightMarked(val recoveryKey: String) : CameraEvent()
    data class HighlightExtracted(val fileUri: Uri, val sourceUri: Uri, val highlightIndex: Int, val timestamp: Long, val isFavorite: Boolean) : CameraEvent()
    data class ExtractionProgress(val sourceUri: Uri, val current: Int, val total: Int) : CameraEvent()
    data class Error(val message: String) : CameraEvent()
}

data class RecordingWindow(
    val sourceUri: String,
    val startedAtMs: Long,
    val endedAtMs: Long?,
    val highlightLengthMs: Long
) {
    fun contains(timeMs: Long): Boolean = timeMs >= startedAtMs - 500 &&
        timeMs <= (endedAtMs ?: System.currentTimeMillis()) + 500
}

class CameraManager(private val context: Context) {
    val isReady: Boolean get() = camera != null && videoCapture != null
    private val preferences = context.getSharedPreferences("clipit_settings", Context.MODE_PRIVATE)

    private val cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private val _isFrontCamera = MutableStateFlow(false)
    val isFrontCamera: StateFlow<Boolean> = _isFrontCamera.asStateFlow()

    private var preview: Preview? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var activeRecording: Recording? = null
    
    private var recordingStartTime: Long = 0
    private var activeWindow: RecordingWindow? = null
    private val recentWindows = ArrayDeque<RecordingWindow>()
    fun recordingWindowAt(timeMs: Long): RecordingWindow? =
        activeWindow?.takeIf { it.contains(timeMs) } ?: recentWindows.lastOrNull { it.contains(timeMs) }
    fun isActiveRecordingWindowAt(timeMs: Long): Boolean =
        _isRecording.value && activeWindow?.contains(timeMs) == true

    fun showRecoveredHighlightConfirmation(key: String) {
        scope.launch { _events.emit(CameraEvent.RecoveredHighlightMarked(key)) }
    }
    private val _highlights = mutableListOf<Long>()
    private val favoriteHighlightIndices = mutableSetOf<Int>()
    private val _extractionProgress = MutableStateFlow(0 to 0)
    val extractionProgress: StateFlow<Pair<Int, Int>> = _extractionProgress.asStateFlow()
    
    private val _bufferLengthSeconds = MutableStateFlow(preferences.getInt("highlight_length", 10).coerceIn(5, 60))
    val bufferLengthSeconds: StateFlow<Int> = _bufferLengthSeconds.asStateFlow()

    // State Flow mappings for Swift @Published
    private val _isRecording = MutableStateFlow(false)
    val isRecording: StateFlow<Boolean> = _isRecording.asStateFlow()

    private val _isExtracting = MutableStateFlow(false)
    val isExtracting: StateFlow<Boolean> = _isExtracting.asStateFlow()

    private val _zoomRatio = MutableStateFlow(1.0f)
    val zoomRatio: StateFlow<Float> = _zoomRatio.asStateFlow()

    private val _minZoom = MutableStateFlow(1.0f)
    val minZoom: StateFlow<Float> = _minZoom.asStateFlow()

    private val _maxZoom = MutableStateFlow(5.0f)
    val maxZoom: StateFlow<Float> = _maxZoom.asStateFlow()


    private val _stabilizationEnabled = MutableStateFlow(true)
    val stabilizationEnabled: StateFlow<Boolean> = _stabilizationEnabled.asStateFlow()

    private val _currentQuality = MutableStateFlow(
        VideoQualityOption.entries.firstOrNull { it.name == preferences.getString("video_quality", null) }
            ?: VideoQualityOption.HD_1080P
    )
    val currentQuality: StateFlow<VideoQualityOption> = _currentQuality.asStateFlow()

    // Event Flow mapping for Swift PassthroughSubject
    private val _events = MutableSharedFlow<CameraEvent>()
    val events: SharedFlow<CameraEvent> = _events.asSharedFlow()

    private val scope = CoroutineScope(Dispatchers.Main)

    /**
     * Initializes CameraX and binds the Preview and VideoCapture use cases.
     */
    fun startCamera(
        lifecycleOwner: LifecycleOwner,
        previewView: PreviewView,
        quality: VideoQualityOption = _currentQuality.value
    ) {
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()

            // 1. Preview Use Case
            preview = Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }

            // 2. Video Capture Use Case with requested Quality
            val qualitySelector = QualitySelector.from(quality.quality)
            val recorder = Recorder.Builder()
                .setQualitySelector(qualitySelector)
                .setExecutor(cameraExecutor)
                .build()

            videoCapture = VideoCapture.Builder(recorder)
                .setVideoStabilizationEnabled(_stabilizationEnabled.value)
                .build()

            val cameraSelector = if (_isFrontCamera.value) CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA

            try {
                cameraProvider?.unbindAll()
                camera = null
                camera = cameraProvider?.bindToLifecycle(
                    lifecycleOwner,
                    cameraSelector,
                    preview,
                    videoCapture
                )

                observeCameraState(lifecycleOwner)
            } catch (exc: Exception) {
                scope.launch { _events.emit(CameraEvent.Error("Camera bind failed: ${exc.localizedMessage}")) }
            }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun observeCameraState(lifecycleOwner: LifecycleOwner) {
        camera?.cameraInfo?.zoomState?.observe(lifecycleOwner) { zoomState ->
            _zoomRatio.value = zoomState.zoomRatio
            _minZoom.value = zoomState.minZoomRatio
            _maxZoom.value = zoomState.maxZoomRatio
        }
        
    }

    fun setBufferLength(seconds: Int) {
        val length = seconds.coerceIn(5, 60) / 5 * 5
        _bufferLengthSeconds.value = length
        preferences.edit { putInt("highlight_length", length) }
    }

    fun selectVideoQuality(quality: VideoQualityOption) {
        if (_isRecording.value) return
        _currentQuality.value = quality
        preferences.edit { putString("video_quality", quality.name) }
    }

    /** Starts continuous recording in ClipIt's private library. */
    fun startRecording() {
        val videoCapture = this.videoCapture ?: return
        if (activeRecording != null) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            scope.launch { _events.emit(CameraEvent.Error("Camera and microphone access are required to record.")) }
            return
        }

        val recordingsDir = File(context.filesDir, "Recordings").apply { mkdirs() }
        val outputFile = File(recordingsDir, "ClipIt_${System.currentTimeMillis()}.mp4")
        val outputOptions = FileOutputOptions.Builder(outputFile).build()
        val outputUri = Uri.fromFile(outputFile)

        _highlights.clear()
        favoriteHighlightIndices.clear()
        _extractionProgress.value = 0 to 0
        recordingStartTime = System.currentTimeMillis()

        try {
            activeRecording = videoCapture.output
            .prepareRecording(context, outputOptions)
            .withAudioEnabled()
            .start(ContextCompat.getMainExecutor(context)) { recordEvent ->
                when (recordEvent) {
                    is VideoRecordEvent.Start -> {
                        recordingStartTime = System.currentTimeMillis()
                        activeWindow = RecordingWindow(outputUri.toString(), recordingStartTime, null,
                            _bufferLengthSeconds.value * 1000L)
                        _isRecording.value = true
                        scope.launch { _events.emit(CameraEvent.RecordingStarted) }
                    }
                    is VideoRecordEvent.Finalize -> {
                        _isRecording.value = false
                        activeRecording = null
                        val currentWindow = activeWindow ?: RecordingWindow(outputUri.toString(), recordingStartTime,
                            null, _bufferLengthSeconds.value * 1000L)
                        val window = currentWindow.copy(endedAtMs = currentWindow.endedAtMs ?: System.currentTimeMillis())
                        activeWindow = null
                        if (!recordEvent.hasError()) {
                            recentWindows.addLast(window)
                            while (recentWindows.size > 4) recentWindows.removeFirst()
                            val savedUri = Uri.fromFile(outputFile)
                            scope.launch { 
                                _events.emit(CameraEvent.MovieFileReady(savedUri, _highlights.toList(), window))
                                extractHighlights(savedUri, _highlights.toList(), favoriteHighlightIndices.toSet())
                            }
                        } else {
                            scope.launch {
                                _events.emit(CameraEvent.Error("Recording error code: ${recordEvent.error}"))
                            }
                        }
                    }
                }
            }
        } catch (exception: SecurityException) {
            activeRecording = null
            outputFile.delete()
            scope.launch { _events.emit(CameraEvent.Error("Camera or microphone permission was revoked.")) }
        }
    }

    /**
     * Extracts highlight clips from the main video using Media3 Transformer.
     */
    @OptIn(UnstableApi::class)
    private fun extractHighlights(sourceUri: Uri, highlights: List<Long>, favorites: Set<Int>) {
        if (highlights.isEmpty()) {
            _isExtracting.value = false
            return
        }
        
        _extractionProgress.value = 0 to highlights.size
        _isExtracting.value = true
        scope.launch(Dispatchers.Default) {
            val total = highlights.size
            
            // Sequential extraction to avoid hardware codec limits
            for (index in highlights.indices) {
                val timestampMs = highlights[index]
                
                val startMs = (timestampMs - (_bufferLengthSeconds.value * 1000L)).coerceAtLeast(0)
                val endMs = timestampMs
                
                val mediaItem = MediaItem.Builder()
                    .setUri(sourceUri)
                    .setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionMs(startMs)
                            .setEndPositionMs(endMs)
                            .build()
                    )
                    .build()
                
                val editedMediaItem = EditedMediaItem.Builder(mediaItem).build()
                val tempFile = File(context.cacheDir, "clipit_temp_${index}_${System.currentTimeMillis()}.mp4")
                
                // Use a CompletableDeferred to wait for each extraction
                val deferred = CompletableDeferred<Unit>()
                
                val listener = object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        val extractedUri = saveExtractedHighlight(tempFile, index + 1)
                        scope.launch(Dispatchers.Main) {
                            if (extractedUri != null) _events.emit(CameraEvent.HighlightExtracted(
                                extractedUri, sourceUri, index + 1, timestampMs, index + 1 in favorites))
                            _extractionProgress.value = index + 1 to total
                            _events.emit(CameraEvent.ExtractionProgress(sourceUri, index + 1, total))
                            deferred.complete(Unit)
                        }
                    }

                    override fun onError(composition: Composition, exportResult: ExportResult, exportException: androidx.media3.transformer.ExportException) {
                        Log.e("CameraManager", "Transformer error: ${exportException.message}")
                        if (tempFile.exists()) tempFile.delete()
                        scope.launch(Dispatchers.Main) {
                            _extractionProgress.value = index + 1 to total
                            _events.emit(CameraEvent.ExtractionProgress(sourceUri, index + 1, total))
                            deferred.complete(Unit)
                        }
                    }
                }
                
                scope.launch(Dispatchers.Main) {
                    try {
                        val transformer = Transformer.Builder(context).build()
                        transformer.addListener(listener)
                        transformer.start(editedMediaItem, tempFile.absolutePath)
                    } catch (error: Exception) {
                        Log.e("CameraManager", "Could not start highlight export", error)
                        tempFile.delete()
                        _extractionProgress.value = index + 1 to total
                        _events.emit(CameraEvent.ExtractionProgress(sourceUri, index + 1, total))
                        deferred.complete(Unit)
                    }
                }
                
                // Wait for this clip to finish before starting the next one
                deferred.await()
            }
            
            _isExtracting.value = false
        }
    }

    private fun saveExtractedHighlight(tempFile: File, highlightNumber: Int): Uri? {
        val outputName = "ClipIt_Clip_${highlightNumber}_${System.currentTimeMillis()}.mp4"
        try {
            val destination = File(File(context.filesDir, "Clips").apply { mkdirs() }, outputName)
            tempFile.copyTo(destination, overwrite = true)
            tempFile.delete()
            return Uri.fromFile(destination)
        } catch (e: Exception) {
            Log.e("CameraManager", "Failed to save highlight: ${e.message}")
            return null
        }
    }

    /**
     * Marks a highlight at the current timestamp.
     */
    fun markHighlight() {
        if (_isRecording.value) {
            val timestamp = System.currentTimeMillis() - recordingStartTime
            _highlights.add(timestamp)
            val index = _highlights.size
            scope.launch { _events.emit(CameraEvent.HighlightMarked(timestamp, index)) }
        }
    }

    fun favoriteHighlight(index: Int) {
        if (index in 1.._highlights.size) favoriteHighlightIndices.add(index)
    }

    /**
     * Stops the continuous recording output.
     */
    fun stopRecording() {
        activeWindow = activeWindow?.copy(endedAtMs = System.currentTimeMillis())
        activeRecording?.stop()
        activeRecording = null
    }

    /**
     * Tap to focus and expose at screen point coordinates.
     */
    fun focusAndExpose(previewView: PreviewView, x: Float, y: Float) {
        val cameraControl = camera?.cameraControl ?: return
        val factory = previewView.meteringPointFactory
        val point = factory.createPoint(x, y)

        val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
            .setAutoCancelDuration(3, java.util.concurrent.TimeUnit.SECONDS)
            .build()

        cameraControl.startFocusAndMetering(action)
    }

    /**
     * Updates the camera hardware zoom ratio directly.
     */
    fun setZoomRatio(ratio: Float) {
        val clampedRatio = ratio.coerceIn(_minZoom.value, _maxZoom.value)
        camera?.cameraControl?.setZoomRatio(clampedRatio)
    }

    fun flipCamera(lifecycleOwner: LifecycleOwner, previewView: PreviewView) {
        if (_isRecording.value) return
        val next = if (_isFrontCamera.value) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
        try {
            if (cameraProvider?.hasCamera(next) != true) return
            _isFrontCamera.value = !_isFrontCamera.value
            startCamera(lifecycleOwner, previewView)
        } catch (error: Exception) {
            Log.e("CameraManager", "Could not switch camera", error)
        }
    }

    /**
     * Toggles video stabilization. Rebinds CameraX pipeline.
     */
    fun setStabilizationEnabled(enabled: Boolean, lifecycleOwner: LifecycleOwner, previewView: PreviewView) {
        if (_stabilizationEnabled.value == enabled) return
        _stabilizationEnabled.value = enabled
        startCamera(lifecycleOwner, previewView)
    }

    /**
     * Set target video quality resolution. Rebinds CameraX pipeline.
     */
    fun setVideoQuality(
        quality: VideoQualityOption,
        lifecycleOwner: LifecycleOwner,
        previewView: PreviewView
    ) {
        if (_currentQuality.value == quality || _isRecording.value) return
        selectVideoQuality(quality)
        startCamera(lifecycleOwner, previewView, quality)
    }

    fun release() {
        cameraExecutor.shutdown()
    }
}
