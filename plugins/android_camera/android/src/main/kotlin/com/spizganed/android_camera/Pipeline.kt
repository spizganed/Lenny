package com.spizganed.android_camera

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import android.util.Range
import android.util.Size
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.security.SecureRandom
import java.util.concurrent.Executor

/**
 * Camera -> H.264 -> core. The camera's only use case is a Preview whose surface is the encoder's input surface, so
 * frames stay on the GPU until MediaCodec hands us the encoded bytes.
 *
 * Threads: the core calls onStreamConfig/onControl on its I/O thread; camera binding happens on the main thread;
 * encoder output is handled on "lenny-encoder".
 */
@SuppressLint("UnsafeOptInUsageError")
@ExperimentalCamera2Interop
class Pipeline(private val context: Context) : SenderListener, LifecycleOwner {
    private val registry = LifecycleRegistry(this)
    override val lifecycle: Lifecycle get() = registry

    private val main = Handler(Looper.getMainLooper())
    private val codecThread = HandlerThread("lenny-encoder").apply { start() }
    private val codecHandler = Handler(codecThread.looper)
    private val codecExecutor = Executor { codecHandler.post(it) }

    @Volatile private var handle = 0L
    private var provider: ProcessCameraProvider? = null
    @Volatile private var encoder: MediaCodec? = null
    @Volatile private var orientation = 0 // 0..3, quarter turns clockwise to upright
    @Volatile private var ptsOffsetUs = 0L // camera clock -> core clock (CLOCK_MONOTONIC)

    /** Returns the lenny_session* for Dart FFI. */
    fun start(host: String, port: Int, token: ByteArray?): Long {
        handle = LennyNative.create(deviceId(context), Build.MODEL, MODES, MAX_BITRATE_KBPS, 0, this)
        check(handle != 0L) { "lenny_sender_create failed" }
        main.post { registry.currentState = Lifecycle.State.RESUMED }
        LennyNative.connect(handle, host, port, token)
        return LennyNative.sessionPtr(handle)
    }

    /** Main thread. */
    fun stop() {
        provider?.unbindAll() // surface released -> encoder released in the provideSurface callback
        registry.currentState = Lifecycle.State.DESTROYED
        // Destroy on the encoder thread: every sendFrame runs there, so none can race the free.
        codecHandler.post {
            val h = handle
            handle = 0L
            LennyNative.disconnect(h)
            LennyNative.destroy(h)
            codecThread.quitSafely()
        }
    }

    override fun onStreamConfig(width: Int, height: Int, fpsNum: Int, fpsDen: Int, bitrateKbps: Int): IntArray {
        val fps = (fpsNum / maxOf(fpsDen, 1)).coerceIn(15, 30)
        val bitrate = bitrateKbps.coerceIn(1000, MAX_BITRATE_KBPS)
        main.post { bindCamera(width, height, fps, bitrate) }
        // ponytail: reports the requested size; CameraX may pick a close one. The SPS carries the real size and the
        // receiver's decoder follows it. Report the actual size once STREAM_START can be re-sent (M3).
        return intArrayOf(width, height, fps, 1, bitrate)
    }

    override fun onControl(cmd: Int, x: Int, y: Int, value: Int): Int = when (cmd) {
        LennyNative.CTL_KEYFRAME_REQUEST -> {
            encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
            LennyNative.ACK_OK // no encoder yet = the first frame will be a keyframe anyway
        }
        else -> LennyNative.ACK_UNSUPPORTED // focus/torch/lens arrive in M3
    }

    private fun bindCamera(width: Int, height: Int, fps: Int, bitrateKbps: Int) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            if (registry.currentState == Lifecycle.State.DESTROYED) return@addListener
            val p = future.get().also { provider = it }
            p.unbindAll()
            val info = CameraSelector.DEFAULT_BACK_CAMERA.filter(p.availableCameraInfos).firstOrNull()
            if (info == null) {
                Log.w(TAG, "no back camera")
                return@addListener
            }
            val chars = Camera2CameraInfo.from(info)
            val builder = Preview.Builder().setResolutionSelector(
                ResolutionSelector.Builder().setResolutionStrategy(
                    ResolutionStrategy(Size(width, height), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
                ).build(),
            )
            // "Auto, always" defaults (prompt's quality bar): continuous video AF, auto exposure/ISO, auto WB,
            // anti-banding for indoor lights, and a fixed AE fps range so low light doesn't drop the frame rate.
            Camera2Interop.Extender(builder)
                .setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                .setCaptureRequestOption(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
                .setCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
                .setCaptureRequestOption(
                    CaptureRequest.CONTROL_AE_ANTIBANDING_MODE, CameraMetadata.CONTROL_AE_ANTIBANDING_MODE_AUTO,
                )
                .apply {
                    fpsRange(chars.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES), fps)
                        ?.let { setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                }
            val preview = builder.build()
            preview.setSurfaceProvider(codecExecutor) { request ->
                val size = request.resolution
                val codec = try {
                    createEncoder(size.width, size.height, fps, bitrateKbps)
                } catch (e: Exception) {
                    Log.w(TAG, "encoder setup failed", e)
                    request.willNotProvideSurface()
                    return@setSurfaceProvider
                }
                val surface = codec.createInputSurface()
                codec.start()
                encoder = codec
                request.setTransformationInfoListener(codecExecutor) { orientation = it.rotationDegrees / 90 }
                request.provideSurface(surface, codecExecutor) {
                    if (encoder === codec) encoder = null
                    runCatching { codec.stop() }
                    codec.release()
                    surface.release()
                }
            }
            // SENSOR_TIMESTAMP is either BOOTTIME ("REALTIME") or MONOTONIC. The core's clock is MONOTONIC.
            val realtime = chars.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE) ==
                CameraMetadata.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME
            ptsOffsetUs = if (realtime) (SystemClock.elapsedRealtimeNanos() - System.nanoTime()) / 1000 else 0L
            p.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview)
        }, ContextCompat.getMainExecutor(context))
    }

    private fun createEncoder(width: Int, height: Int, fps: Int, bitrateKbps: Int): MediaCodec {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // short GOP: a lost decoder recovers within 1 s
            if (Build.VERSION.SDK_INT >= 29) setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit // surface input

            override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                val buf = try { codec.getOutputBuffer(index) } catch (e: IllegalStateException) { return }
                if (buf != null && info.size > 0 && handle != 0L) {
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                        LennyNative.sendConfig(handle, buf, info.offset, info.size)
                    } else {
                        val key = if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) LennyNative.FRAME_KEYFRAME else 0
                        // Not streaming yet / link down -> the core returns an error and the frame is dropped. Fine.
                        LennyNative.sendFrame(
                            handle, buf, info.offset, info.size, info.presentationTimeUs - ptsOffsetUs, orientation, key,
                        )
                    }
                }
                runCatching { codec.releaseOutputBuffer(index, false) }
            }

            override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) {
                Log.w(TAG, "encoder error", e)
            }
            override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) = Unit
        }, codecHandler)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        return codec
    }

    companion object {
        private const val TAG = "lenny"
        private const val MAX_BITRATE_KBPS = 20000
        private val MODES = intArrayOf(1280, 720, 30, 1, 1920, 1080, 30, 1)

        /** Exact [fps, fps] if the camera has it, else the narrowest range that still reaches fps. */
        private fun fpsRange(ranges: Array<Range<Int>>?, fps: Int): Range<Int>? =
            ranges?.firstOrNull { it.lower == fps && it.upper == fps }
                ?: ranges?.filter { it.upper >= fps }?.minByOrNull { it.upper - it.lower }

        /** Random 16 bytes, persisted per install (HELLO device_id; how the desktop remembers this phone). */
        fun deviceId(context: Context): ByteArray {
            val prefs = context.getSharedPreferences("lenny", Context.MODE_PRIVATE)
            prefs.getString("device_id", null)?.let { return Base64.decode(it, Base64.NO_WRAP) }
            val id = ByteArray(16).also { SecureRandom().nextBytes(it) }
            prefs.edit().putString("device_id", Base64.encodeToString(id, Base64.NO_WRAP)).apply()
            return id
        }
    }
}
