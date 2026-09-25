package com.spizganed.android_camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/**
 * Channel "lenny/android_camera":
 *   requestPermissions() -> bool (camera granted)
 *   start({host, port, token?}) -> {session: lenny_session* for Dart FFI, controls, lenses, exposure}
 *   stop()
 *   control({cmd, x, y, value}) -> int (LENNY_ACK_*): the phone's own camera buttons
 *   scanQr() -> String? (null = cancelled): Google code scanner, runs in the system UI
 * Native -> Dart: state(map) whenever the camera control state changes.
 */
class AndroidCameraPlugin :
    FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var pipeline: Pipeline? = null
    private val background = Executors.newSingleThreadExecutor()
    private val main = android.os.Handler(android.os.Looper.getMainLooper())

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
                val host = call.argument<String>("host")!!
                val port = call.argument<Int>("port")!!
                val token = call.argument<ByteArray>("token")
                val p = Pipeline(context)
                p.onStateChanged = { channel.invokeMethod("state", it.toMap()) }
                // Off the main thread: start() waits for the camera to probe lenses.
                background.execute {
                    try {
                        val session = p.start(host, port, token)
                        main.post {
                            pipeline = p
                            ContextCompat.startForegroundService(context, Intent(context, StreamService::class.java))
                            result.success(
                                mapOf(
                                    "session" to session, "controls" to p.caps, "lenses" to p.lensLabels,
                                    "exposure" to p.exposure.toList(),
                                ),
                            )
                        }
                    } catch (e: Exception) {
                        main.post { result.error("start", e.message, null) }
                    }
                }
            }
            "control" -> {
                val p = pipeline ?: return result.success(LennyNative.ACK_FAILED)
                result.success(
                    p.control(call.argument<Int>("cmd")!!, call.argument<Int>("x") ?: 0, call.argument<Int>("y") ?: 0,
                        call.argument<Int>("value") ?: 0),
                )
            }
            "scanQr" -> {
                val act = activity?.activity ?: return result.success(null)
                val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
                GmsBarcodeScanning.getClient(act, options).startScan()
                    .addOnSuccessListener { result.success(it.rawValue) }
                    .addOnCanceledListener { result.success(null) }
                    .addOnFailureListener { result.error("scan", it.message, null) }
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
