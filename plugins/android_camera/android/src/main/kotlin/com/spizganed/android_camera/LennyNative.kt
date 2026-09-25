package com.spizganed.android_camera

import java.nio.ByteBuffer

/** Called on the core's I/O thread. Keep it quick; never throw (the JNI side treats exceptions as failures). */
interface SenderListener {
    /** Receiver asked for these settings. Return the effective [width, height, fpsNum, fpsDen, bitrateKbps]. */
    fun onStreamConfig(width: Int, height: Int, fpsNum: Int, fpsDen: Int, bitrateKbps: Int): IntArray

    /** Camera control (LENNY_CTL_*). Return LENNY_ACK_* (0 ok, 1 unsupported, 2 failed). */
    fun onControl(cmd: Int, x: Int, y: Int, value: Int): Int
}

/** Thin JNI surface over core/include/lenny/lenny.h (see src/main/cpp/lenny_jni.cpp). */
object LennyNative {
    init {
        System.loadLibrary("lenny_jni") // pulls in liblenny_core.so, the same copy Dart FFI opens
    }

    const val CTL_KEYFRAME_REQUEST = 10
    const val ACK_OK = 0
    const val ACK_UNSUPPORTED = 1
    const val FRAME_KEYFRAME = 1

    /** modes = flat [w, h, fpsNum, fpsDen, ...]. Returns 0 on failure. */
    @JvmStatic external fun create(
        deviceId: ByteArray, name: String, modes: IntArray, maxBitrateKbps: Int, controls: Int, listener: SenderListener,
    ): Long

    /** The lenny_session* inside a handle, for Dart FFI. */
    @JvmStatic external fun sessionPtr(handle: Long): Long
    @JvmStatic external fun connect(handle: Long, host: String, port: Int, token: ByteArray?): Int
    @JvmStatic external fun sendConfig(handle: Long, buf: ByteBuffer, offset: Int, size: Int): Int
    @JvmStatic external fun sendFrame(
        handle: Long, buf: ByteBuffer, offset: Int, size: Int, ptsUs: Long, orientation: Int, flags: Int,
    ): Int
    @JvmStatic external fun disconnect(handle: Long): Int
    @JvmStatic external fun destroy(handle: Long)
    @JvmStatic external fun nowUs(): Long
}
