@file:Suppress("DEPRECATION") // PhoneStateListener is required below Android 12.

package com.clipitllc.clipitapp.services

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import androidx.annotation.RequiresApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

class CallMonitor(private val context: Context) {

    private val telephonyManager = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
    
    private val _isOnCall = MutableStateFlow(false)
    val isOnCall = _isOnCall.asStateFlow()

    private var callback: Any? = null

    fun startMonitoring() {
        if (callback != null) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val telephonyCallback = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) {
                    updateCallState(state)
                }
            }
            telephonyManager.registerTelephonyCallback(context.mainExecutor, telephonyCallback)
            callback = telephonyCallback
        } else {
            val listener = object : PhoneStateListener() {
                @Deprecated("Deprecated in Java")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                    updateCallState(state)
                }
            }
            telephonyManager.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            callback = listener
        }
    }

    fun stopMonitoring() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (callback as? TelephonyCallback)?.let {
                telephonyManager.unregisterTelephonyCallback(it)
            }
        } else {
            (callback as? PhoneStateListener)?.let {
                telephonyManager.listen(it, PhoneStateListener.LISTEN_NONE)
            }
        }
        callback = null
    }

    private fun updateCallState(state: Int) {
        _isOnCall.value = state != TelephonyManager.CALL_STATE_IDLE
    }
}
