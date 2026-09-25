package com.spizganed.android_camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * Channel "lenny/android_camera":
 *   requestPermissions() -> bool (camera granted)
 *   start({host, port, token?}) -> int (lenny_session* for Dart FFI)
 *   stop()
 */
@ExperimentalCamera2Interop
class AndroidCameraPlugin :
    FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var pipeline: Pipeline? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "lenny/android_camera")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        stop()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestPermissions" -> requestPermissions(result)
            "start" -> {
                if (!hasCamera()) return result.error("permission", "Camera permission not granted", null)
                stop()
                try {
                    val p = Pipeline(context)
                    val session = p.start(
                        call.argument<String>("host")!!, call.argument<Int>("port")!!, call.argument<ByteArray>("token"),
                    )
                    pipeline = p
                    ContextCompat.startForegroundService(context, Intent(context, StreamService::class.java))
                    result.success(session)
                } catch (e: Exception) {
                    result.error("start", e.message, null)
                }
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun stop() {
        pipeline?.stop()
        pipeline = null
        context.stopService(Intent(context, StreamService::class.java))
    }

    private fun hasCamera() =
        ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun requestPermissions(result: MethodChannel.Result) {
        val act: Activity = activity?.activity ?: return result.success(hasCamera())
        val wanted = buildList {
            add(Manifest.permission.CAMERA)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS) // foreground notification
        }.filter { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }
        if (wanted.isEmpty()) return result.success(true)
        pendingPermission?.success(hasCamera())
        pendingPermission = result
        ActivityCompat.requestPermissions(act, wanted.toTypedArray(), REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_CODE) return false
        pendingPermission?.success(hasCamera())
        pendingPermission = null
        return true
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity?.removeRequestPermissionsResultListener(this)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    private companion object {
        const val REQUEST_CODE = 4747
    }
}
