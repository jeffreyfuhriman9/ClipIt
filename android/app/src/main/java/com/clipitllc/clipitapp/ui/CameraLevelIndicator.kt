package com.clipitllc.clipitapp.ui

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay
import kotlin.math.PI

@Composable
internal fun CameraLevelIndicator(isLandscape: Boolean, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val filter = remember(isLandscape) { CameraLevelFilter() }
    var reading by remember(isLandscape) { mutableStateOf(LevelReading(false, false, 0.0)) }
    var targetOpacity by remember(isLandscape) { mutableFloatStateOf(0f) }
    val opacity by animateFloatAsState(targetOpacity,
        animationSpec = tween(if (reading.aligned && targetOpacity == 0f) 220 else 120),
        label = "Camera level fade")
    DisposableEffect(context, lifecycleOwner, isLandscape) {
        val manager = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val sensor = manager.getDefaultSensor(Sensor.TYPE_GRAVITY)
            ?: manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        var referenceAngle: Double? = null
        var registered = false
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                val x = event.values[0].toDouble()
                val y = event.values[1].toDouble()
                val newReference = CameraLevelFilter.referenceAngle(x, y, isLandscape)
                if (referenceAngle != newReference) {
                    filter.reset()
                    referenceAngle = newReference
                }
                reading = filter.update(x, y, newReference)
            }
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
        }
        fun stop() {
            manager.unregisterListener(listener)
            registered = false
            filter.reset()
            referenceAngle = null
            reading = LevelReading(false, false, 0.0)
        }
        fun start() {
            if (!registered && sensor != null) registered = manager.registerListener(listener, sensor, 16_667)
        }
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> start()
                Lifecycle.Event.ON_PAUSE, Lifecycle.Event.ON_STOP -> stop()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        if (lifecycleOwner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) start()
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            stop()
        }
    }

    LaunchedEffect(reading.visible, reading.aligned) {
        if (!reading.visible) targetOpacity = 0f
        else if (reading.aligned) {
            targetOpacity = 1f
            delay(160)
            targetOpacity = 0f
        } else targetOpacity = 1f
    }

    Box(modifier.size(width = 172.dp, height = 44.dp).alpha(opacity)
        .shadow(2.dp, CircleShape, ambientColor = Color.Black.copy(alpha = 0.6f)),
        contentAlignment = Alignment.Center) {
        if (reading.aligned) {
            Box(Modifier.width(172.dp).height(2.dp).background(Color.Yellow, CircleShape))
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(26.dp).height(2.dp).background(Color.White, CircleShape))
                Box(Modifier.width(8.dp))
                Box(Modifier.width(104.dp).height(2.dp)
                    .graphicsLayer(rotationZ = (-reading.rollRadians * 180.0 / PI).toFloat())
                    .background(Color.White, CircleShape))
                Box(Modifier.width(8.dp))
                Box(Modifier.width(26.dp).height(2.dp).background(Color.White, CircleShape))
            }
        }
    }
}
