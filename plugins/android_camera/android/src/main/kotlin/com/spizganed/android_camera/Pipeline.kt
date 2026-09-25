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
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.FocusMeteringAction
import androidx.camera.core.Preview
import androidx.camera.core.SurfaceOrientedMeteringPointFactory
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import java.security.SecureRandom
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

/**
 * Camera -> H.264 -> core, plus camera controls. The camera's only use case is a Preview whose surface is the
 * encoder's input surface, so frames stay on the GPU until MediaCodec hands us the encoded bytes.
 *
 * Threads: the core calls onStreamConfig/onControl/onBitrate on its I/O thread; everything that touches CameraX
 * (binding, controls, [state]) runs on the main thread; encoder output is handled on "lenny-encoder".
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
    private lateinit var provider: ProcessCameraProvider
    private lateinit var lenses: List<CameraInfo>
    private var camera: Camera? = null
    private var preview: Preview? = null
    private var bound: Settings? = null
    @Volatile private var encoder: MediaCodec? = null
    @Volatile private var orientation = 0 // 0..3, quarter turns clockwise to upright
    @Volatile private var ptsOffsetUs = 0L // camera clock -> core clock (CLOCK_MONOTONIC)
    @Volatile private var ptsCalibrated = false
    /** LENNY_CAP_* union over all lenses, lens labels, exposure range [min, max, step] in EV*1000 (after start). */
    @Volatile var caps = 0
        private set
    var lensLabels: List<String> = emptyList()
        private set
    var exposure: IntArray = IntArray(0)
        private set

    /** Current camera control state. Main thread only. */
    val state = ControlState()

    /** Called with [state] after every change, on the main thread (the Flutter side shows it). */
    var onStateChanged: ((ControlState) -> Unit)? = null

    private data class Settings(val width: Int, val height: Int, val fps: Int, val bitrateKbps: Int, val lens: Int)

    /** Any thread except main (it waits for CameraX). Returns the lenny_session* for Dart FFI. */
    fun start(host: String, port: Int, token: ByteArray?): Long {
        provider = ProcessCameraProvider.getInstance(context).get(10, TimeUnit.SECONDS)
        // Back cameras first, so lens 0 is the usual main camera.
        lenses = provider.availableCameraInfos.sortedBy { if (it.lensFacing == CameraSelector.LENS_FACING_BACK) 0 else 1 }
        check(lenses.isNotEmpty()) { "no camera" }
        val (lensArray, labels) = describeLenses()
        caps = capabilities()
        lensLabels = labels.toList()
        exposure = exposureRange()
        handle = LennyNative.create(
            deviceId(context), Build.MODEL, MODES, MAX_BITRATE_KBPS, caps, lensArray, labels, exposure, this,
        )
        check(handle != 0L) { "lenny_sender_create failed" }
        main.post { registry.currentState = Lifecycle.State.RESUMED }
        LennyNative.connect(handle, host, port, token)
        return LennyNative.sessionPtr(handle)
    }

    /** Main thread. */
    fun stop() {
        provider.unbindAll() // surface released -> encoder released in the provideSurface callback
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

    // ---- core callbacks (I/O thread) --------------------------------------------------------------------------

    override fun onStreamConfig(width: Int, height: Int, fpsNum: Int, fpsDen: Int, bitrateKbps: Int): IntArray {
        val fps = (fpsNum / maxOf(fpsDen, 1)).coerceIn(15, 30)
        val bitrate = bitrateKbps.coerceIn(1000, MAX_BITRATE_KBPS)
        main.post {
            // New stream (first connect or reconnect): back to Auto, except what the user set on the phone itself.
            resetRemoteOverrides()
            bindCamera(Settings(width, height, fps, bitrate, state.lens))
        }
        return intArrayOf(width, height, fps, 1, bitrate)
    }

    override fun onControl(cmd: Int, x: Int, y: Int, value: Int): Int {
        if (cmd == LennyNative.CTL_KEYFRAME_REQUEST) {
            encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
            // The core asks for a keyframe at every stream (re)start: also a good moment to tell the receiver
            // what the camera is doing.
            main.post { publishState() }
            return LennyNative.ACK_OK // no encoder yet = the first frame will be a keyframe anyway
        }
        if (!supported(cmd, value)) return LennyNative.ACK_UNSUPPORTED
        main.post { apply(cmd, x, y, value, local = false) }
        return LennyNative.ACK_OK
    }

    override fun onBitrate(kbps: Int) {
        encoder?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, kbps * 1000) })
    }

    // ---- controls (main thread) -----------------------------------------------------------------------------

    /** The phone's own UI. Same code path as remote controls; these survive reconnects. */
    fun control(cmd: Int, x: Int, y: Int, value: Int): Int {
        if (!supported(cmd, value)) return LennyNative.ACK_UNSUPPORTED
        apply(cmd, x, y, value, local = true)
        return LennyNative.ACK_OK
    }

    private fun supported(cmd: Int, value: Int): Boolean = when (cmd) {
        LennyNative.CTL_FOCUS_AT, LennyNative.CTL_FOCUS_AUTO -> caps and LennyNative.CAP_FOCUS != 0
        LennyNative.CTL_FOCUS_LOCK -> caps and LennyNative.CAP_FOCUS_LOCK != 0
        LennyNative.CTL_EXPOSURE_COMP -> caps and LennyNative.CAP_EXPOSURE_COMP != 0
        LennyNative.CTL_EXPOSURE_LOCK -> caps and LennyNative.CAP_EXPOSURE_LOCK != 0
        LennyNative.CTL_WB_LOCK -> caps and LennyNative.CAP_WB_LOCK != 0
        LennyNative.CTL_TORCH -> caps and LennyNative.CAP_TORCH != 0
        LennyNative.CTL_SELECT_LENS -> caps and LennyNative.CAP_LENS != 0 && value in lenses.indices
        LennyNative.CTL_ZOOM -> caps and LennyNative.CAP_ZOOM != 0
        LennyNative.CTL_RESET_AUTO -> true
        else -> false
    }

    private fun apply(cmd: Int, x: Int, y: Int, value: Int, local: Boolean) {
        if (local) state.local += cmd else state.local -= cmd
        val cam = camera
        val control = cam?.cameraControl
        when (cmd) {
            LennyNative.CTL_FOCUS_AT -> focusAt(x / 65535f, y / 65535f)
            LennyNative.CTL_FOCUS_LOCK -> {
                state.focusLocked = value != 0
                if (state.focusLocked) focusAt(state.focusX, state.focusY) else control?.cancelFocusAndMetering()
                state.afMode = if (state.focusLocked) ControlState.AF_LOCKED else ControlState.AF_CONTINUOUS
            }
            LennyNative.CTL_FOCUS_AUTO -> {
                state.focusLocked = false
                state.afMode = ControlState.AF_CONTINUOUS
                control?.cancelFocusAndMetering()
            }
            LennyNative.CTL_EXPOSURE_COMP -> {
                val exp = cam?.cameraInfo?.exposureState
                if (exp != null && exp.isExposureCompensationSupported) {
                    val step = exp.exposureCompensationStep.toFloat()
                    val index = (value / 1000f / step).roundToInt()
                        .coerceIn(exp.exposureCompensationRange.lower, exp.exposureCompensationRange.upper)
                    control?.setExposureCompensationIndex(index)
                    state.exposureEvMilli = (index * step * 1000).roundToInt()
                }
            }
            LennyNative.CTL_EXPOSURE_LOCK -> {
                state.aeLock = value != 0
                applyLocks()
            }
            LennyNative.CTL_WB_LOCK -> {
                state.awbLock = value != 0
                applyLocks()
            }
            LennyNative.CTL_TORCH -> {
                state.torch = value != 0 && cam?.cameraInfo?.hasFlashUnit() == true
                control?.enableTorch(state.torch)
            }
            LennyNative.CTL_SELECT_LENS -> if (value != state.lens) {
                state.lens = value
                state.torch = false // the new lens may have no flash; start it dark
                bound?.let { bindCamera(it.copy(lens = value)) }
            }
            LennyNative.CTL_ZOOM -> {
                val zs = cam?.cameraInfo?.zoomState?.value
                val ratio = (value / 100f).coerceIn(zs?.minZoomRatio ?: 1f, zs?.maxZoomRatio ?: 1f)
                control?.setZoomRatio(ratio)
                state.zoom100 = (ratio * 100).roundToInt()
            }
            LennyNative.CTL_RESET_AUTO -> {
                state.local.clear()
                resetAll()
            }
        }
        publishState()
    }

    /** upright (u, v) in 0..1 -> buffer coordinates, then tap-to-focus. Auto-cancels back to continuous AF after 5 s
     *  unless focus lock is on. */
    private fun focusAt(u: Float, v: Float) {
        val p = preview ?: return
        state.focusX = u
        state.focusY = v
        // Inverse of the receiver's upright rotation (quarter turns clockwise).
        val (bx, by) = when (orientation) {
            1 -> v to 1f - u
            2 -> 1f - u to 1f - v
            3 -> 1f - v to u
            else -> u to v
        }
        val point = SurfaceOrientedMeteringPointFactory(1f, 1f, p).createPoint(bx, by)
        val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
            .apply { if (state.focusLocked) disableAutoCancel() else setAutoCancelDuration(5, TimeUnit.SECONDS) }
            .build()
        state.afMode = ControlState.AF_FOCUSING
        val result = camera?.cameraControl?.startFocusAndMetering(action) ?: return
        result.addListener({
            state.afMode = if (state.focusLocked) ControlState.AF_LOCKED else ControlState.AF_CONTINUOUS
            publishState()
        }, ContextCompat.getMainExecutor(context))
    }

    private fun applyLocks() {
        val cam = camera ?: return
        Camera2CameraControl.from(cam.cameraControl).addCaptureRequestOptions(
            CaptureRequestOptions.Builder()
                .setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, state.aeLock)
                .setCaptureRequestOption(CaptureRequest.CONTROL_AWB_LOCK, state.awbLock)
                .build(),
        )
    }

    /** "Auto, always": continuous AF, auto exposure, auto WB, no torch, 1x. Lens stays. */
    private fun resetAll() {
        val control = camera?.cameraControl
        state.focusLocked = false
        state.afMode = ControlState.AF_CONTINUOUS
        state.exposureEvMilli = 0
        state.aeLock = false
        state.awbLock = false
        state.torch = false
        state.zoom100 = 100
        control?.cancelFocusAndMetering()
        if (camera?.cameraInfo?.exposureState?.isExposureCompensationSupported == true) control?.setExposureCompensationIndex(0)
        control?.enableTorch(false)
        control?.setZoomRatio(1f)
        applyLocks()
    }

    private fun resetRemoteOverrides() {
        val keep = state.local.toSet()
        val saved = state.copy()
        resetAll()
        // Re-apply the phone user's own choices on top of Auto.
        if (LennyNative.CTL_FOCUS_LOCK in keep && saved.focusLocked) apply(LennyNative.CTL_FOCUS_LOCK, 0, 0, 1, true)
        if (LennyNative.CTL_EXPOSURE_COMP in keep) apply(LennyNative.CTL_EXPOSURE_COMP, 0, 0, saved.exposureEvMilli, true)
        if (LennyNative.CTL_EXPOSURE_LOCK in keep) apply(LennyNative.CTL_EXPOSURE_LOCK, 0, 0, saved.aeLock.int, true)
        if (LennyNative.CTL_WB_LOCK in keep) apply(LennyNative.CTL_WB_LOCK, 0, 0, saved.awbLock.int, true)
        if (LennyNative.CTL_TORCH in keep) apply(LennyNative.CTL_TORCH, 0, 0, saved.torch.int, true)
        if (LennyNative.CTL_ZOOM in keep) apply(LennyNative.CTL_ZOOM, 0, 0, saved.zoom100, true)
        state.local.retainAll(keep)
    }

    private fun publishState() {
        onStateChanged?.invoke(state)
        if (handle != 0L) LennyNative.sendControlState(handle, state.toArray()) // not streaming -> ignored
    }

    // ---- camera + encoder -------------------------------------------------------------------------------------

    private fun bindCamera(s: Settings) {
        if (registry.currentState == Lifecycle.State.DESTROYED) return
        if (s == bound && camera != null) return // reconnect with the same settings: keep the running camera
        provider.unbindAll()
        val info = lenses[s.lens.coerceIn(lenses.indices)]
        val chars = Camera2CameraInfo.from(info)
        val builder = Preview.Builder().setResolutionSelector(
            ResolutionSelector.Builder().setResolutionStrategy(
                ResolutionStrategy(Size(s.width, s.height), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER),
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
                fpsRange(chars.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES), s.fps)
                    ?.let { setCaptureRequestOption(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
            }
        val p = builder.build()
        p.setSurfaceProvider(codecExecutor) { request ->
            val size = request.resolution
            val codec = try {
                createEncoder(size.width, size.height, s.fps, s.bitrateKbps)
            } catch (e: Exception) {
                Log.w(TAG, "encoder setup failed", e)
                request.willNotProvideSurface()
                return@setSurfaceProvider
            }
            val surface = codec.createInputSurface()
            codec.start()
            encoder = codec
            // Tell the receiver when the camera picked a different size than it asked for.
            if (size.width != s.width || size.height != s.height) {
                LennyNative.updateStream(handle, size.width, size.height, s.fps, s.bitrateKbps)
            }
            request.setTransformationInfoListener(codecExecutor) { orientation = it.rotationDegrees / 90 }
            request.provideSurface(surface, codecExecutor) {
                if (encoder === codec) encoder = null
                runCatching { codec.stop() }
                codec.release()
                surface.release()
            }
        }
        ptsCalibrated = false // new camera: its timestamp clock may differ (see calibratePts)
        val selector = CameraSelector.Builder().addCameraFilter { infos -> infos.filter { it == info } }.build()
        camera = provider.bindToLifecycle(this, selector, p)
        preview = p
        bound = s
        // A rebind resets the camera's controls; put back what's currently set.
        if (state.torch) camera?.cameraControl?.enableTorch(true)
        if (state.zoom100 != 100) camera?.cameraControl?.setZoomRatio(state.zoom100 / 100f)
        if (state.exposureEvMilli != 0) apply(LennyNative.CTL_EXPOSURE_COMP, 0, 0, state.exposureEvMilli, LennyNative.CTL_EXPOSURE_COMP in state.local)
        applyLocks()
    }

    private fun createEncoder(width: Int, height: Int, fps: Int, bitrateKbps: Int): MediaCodec {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // short GOP: a lost decoder recovers within 1 s
            setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
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
                        if (!ptsCalibrated) calibratePts(info.presentationTimeUs)
                        // A capture time in the future is impossible, so this camera's clock is off (the emulator's
                        // front camera). Checked per frame, not once: the first frame after a switch encodes slowest.
                        val now = LennyNative.nowUs()
                        if (info.presentationTimeUs - ptsOffsetUs > now) ptsOffsetUs = info.presentationTimeUs - now
                        val key = if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) LennyNative.FRAME_KEYFRAME else 0
                        // Copied into the core's queue; never waits on the network. Not streaming -> dropped.
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

    /**
     * Camera timestamps are either MONOTONIC (the core's clock) or BOOTTIME, and SENSOR_INFO_TIMESTAMP_SOURCE isn't
     * reliable on every device (the emulator's front camera gets it wrong). So check the first frame: it was captured
     * a few ms ago, so whichever clock puts it closest to "now" is the right one.
     */
    private fun calibratePts(ptsUs: Long) {
        val now = LennyNative.nowUs()
        val bootOffset = (SystemClock.elapsedRealtimeNanos() - System.nanoTime()) / 1000
        val ageMono = now - ptsUs
        val ageBoot = now - (ptsUs - bootOffset)
        ptsOffsetUs = when {
            kotlin.math.abs(ageMono) <= kotlin.math.abs(ageBoot) && kotlin.math.abs(ageMono) < 2_000_000 -> 0L
            kotlin.math.abs(ageBoot) < 2_000_000 -> bootOffset
            else -> {
                // Some other time base entirely. Count from encoder output instead: latency then excludes capture and
                // encode time, but stays meaningful.
                Log.w(TAG, "unknown camera clock: pts=$ptsUs now=$now boot=$bootOffset")
                ptsUs - now
            }
        }
        ptsCalibrated = true
    }

    // ---- capabilities (CAPS) ----------------------------------------------------------------------------------

    private fun describeLenses(): Pair<IntArray, Array<String>> {
        var back = 0
        var front = 0
        val flat = IntArray(lenses.size * 2)
        val labels = lenses.mapIndexed { i, info ->
            val facing = when (info.lensFacing) {
                CameraSelector.LENS_FACING_BACK -> 0
                CameraSelector.LENS_FACING_FRONT -> 1
                else -> 2
            }
            flat[2 * i] = i
            flat[2 * i + 1] = facing
            when (facing) {
                0 -> if (++back == 1) "Back" else "Back $back"
                1 -> if (++front == 1) "Front" else "Front $front"
                else -> "External"
            }
        }.toTypedArray()
        return flat to labels
    }

    /** Union over all lenses; per-lens gaps are handled when a control is applied. */
    private fun capabilities(): Int {
        var c = 0
        for (info in lenses) {
            val ch = Camera2CameraInfo.from(info)
            val af = ch.getCameraCharacteristic(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
            if (af?.contains(CameraMetadata.CONTROL_AF_MODE_AUTO) == true) {
                c = c or LennyNative.CAP_FOCUS or LennyNative.CAP_FOCUS_LOCK
            }
            if (info.exposureState.isExposureCompensationSupported) c = c or LennyNative.CAP_EXPOSURE_COMP
            if (ch.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true) {
                c = c or LennyNative.CAP_EXPOSURE_LOCK
            }
            if (ch.getCameraCharacteristic(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true) {
                c = c or LennyNative.CAP_WB_LOCK
            }
            if (info.hasFlashUnit()) c = c or LennyNative.CAP_TORCH
            val maxZoom = ch.getCameraCharacteristic(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
            if (maxZoom > 1f) c = c or LennyNative.CAP_ZOOM
        }
        if (lenses.size > 1) c = c or LennyNative.CAP_LENS
        return c
    }

    private fun exposureRange(): IntArray {
        val exp = lenses.first().exposureState
        if (!exp.isExposureCompensationSupported) return IntArray(0)
        val step = exp.exposureCompensationStep.toFloat()
        return intArrayOf(
            (exp.exposureCompensationRange.lower * step * 1000).roundToInt(),
            (exp.exposureCompensationRange.upper * step * 1000).roundToInt(),
            (step * 1000).roundToInt(),
        )
    }

    companion object {
        private const val TAG = "lenny"
        private const val MAX_BITRATE_KBPS = 20000
        private val MODES = intArrayOf(1280, 720, 30, 1, 1920, 1080, 30, 1)

        private val Boolean.int get() = if (this) 1 else 0

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

/** Mirrors lenny_control_state, plus what the phone needs to remember. Main thread only. */
data class ControlState(
    var afMode: Int = AF_CONTINUOUS,
    var focusLocked: Boolean = false,
    var focusX: Float = 0.5f,
    var focusY: Float = 0.5f,
    var exposureEvMilli: Int = 0,
    var aeLock: Boolean = false,
    var awbLock: Boolean = false,
    var torch: Boolean = false,
    var lens: Int = 0,
    var zoom100: Int = 100,
    /** Controls last set from the phone's own UI. They survive reconnects; remote ones reset to Auto. */
    val local: MutableSet<Int> = mutableSetOf(),
) {
    fun toArray() = intArrayOf(
        afMode, exposureEvMilli, if (aeLock) 1 else 0, if (awbLock) 1 else 0, if (torch) 1 else 0, lens, zoom100,
    )

    fun toMap(): Map<String, Any> = mapOf(
        "afMode" to afMode, "focusLocked" to focusLocked, "exposureEvMilli" to exposureEvMilli, "aeLock" to aeLock,
        "awbLock" to awbLock, "torch" to torch, "lens" to lens, "zoom100" to zoom100,
    )

    companion object {
        const val AF_CONTINUOUS = 0
        const val AF_LOCKED = 1
        const val AF_FOCUSING = 2
    }
}
