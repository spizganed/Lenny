// JNI bridge: Kotlin (LennyNative) <-> lenny_core C ABI. Encoded frames go straight from MediaCodec's direct
// ByteBuffer into the core; nothing is copied into the JVM heap.
#include <android/log.h>
#include <jni.h>

#include <vector>

#include "lenny/lenny.h"

#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, "lenny", __VA_ARGS__)

namespace {

JavaVM* g_vm = nullptr;

// Core callbacks arrive on the core's I/O thread, which the JVM doesn't know. Attach it once and detach when the
// thread exits (a thread_local destructor), otherwise the thread leaks a JNIEnv or aborts on exit.
JNIEnv* env_for_thread() {
    JNIEnv* env = nullptr;
    if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) == JNI_OK) return env;
    thread_local struct Detacher {
        bool attached = false;
        ~Detacher() {
            if (attached) g_vm->DetachCurrentThread();
        }
    } detacher;
    if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return nullptr;
    detacher.attached = true;
    return env;
}

// A Kotlin exception must never unwind into the core; log and fall back to a safe answer.
bool clear_exception(JNIEnv* env, const char* where) {
    if (!env->ExceptionCheck()) return false;
    LOGW("exception in %s", where);
    env->ExceptionDescribe();
    env->ExceptionClear();
    return true;
}

struct Ctx {
    lenny_session* session = nullptr;
    jobject listener = nullptr;  // global ref to SenderListener
    jmethodID on_stream_config = nullptr;
    jmethodID on_control = nullptr;
};

void on_stream_config(void* user, const lenny_stream_settings* req, lenny_stream_settings* eff) {
    auto* ctx = static_cast<Ctx*>(user);
    JNIEnv* env = env_for_thread();
    if (!env) return;
    auto arr = static_cast<jintArray>(env->CallObjectMethod(ctx->listener, ctx->on_stream_config, jint(req->mode.width),
                                                            jint(req->mode.height), jint(req->mode.fps_num),
                                                            jint(req->mode.fps_den), jint(req->bitrate_kbps)));
    if (clear_exception(env, "onStreamConfig") || !arr) return;
    if (env->GetArrayLength(arr) == 5) {
        jint v[5];
        env->GetIntArrayRegion(arr, 0, 5, v);
        eff->mode = {uint16_t(v[0]), uint16_t(v[1]), uint16_t(v[2]), uint16_t(v[3])};
        eff->bitrate_kbps = uint32_t(v[4]);
    }
    env->DeleteLocalRef(arr);
}

int32_t on_control(void* user, const lenny_control* c) {
    auto* ctx = static_cast<Ctx*>(user);
    JNIEnv* env = env_for_thread();
    if (!env) return LENNY_ACK_FAILED;
    jint r = env->CallIntMethod(ctx->listener, ctx->on_control, jint(c->cmd), jint(c->x), jint(c->y), jint(c->value));
    return clear_exception(env, "onControl") ? LENNY_ACK_FAILED : r;
}

Ctx* ctx_of(jlong h) { return reinterpret_cast<Ctx*>(h); }

const uint8_t* direct(JNIEnv* env, jobject buf, jint offset) {
    auto* p = static_cast<uint8_t*>(env->GetDirectBufferAddress(buf));
    return p ? p + offset : nullptr;
}

}  // namespace

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
    g_vm = vm;
    return JNI_VERSION_1_6;
}

JNIEXPORT jlong JNICALL Java_com_spizganed_android_1camera_LennyNative_create(JNIEnv* env, jclass, jbyteArray device_id,
                                                                             jstring name, jintArray modes,
                                                                             jint max_bitrate, jint controls,
                                                                             jobject listener) {
    if (!device_id || env->GetArrayLength(device_id) != LENNY_DEVICE_ID_SIZE || !name || !modes || !listener) return 0;
    auto* ctx = new Ctx;
    jclass cls = env->GetObjectClass(listener);
    ctx->on_stream_config = env->GetMethodID(cls, "onStreamConfig", "(IIIII)[I");
    ctx->on_control = env->GetMethodID(cls, "onControl", "(IIII)I");
    if (!ctx->on_stream_config || !ctx->on_control) {
        clear_exception(env, "create");
        delete ctx;
        return 0;
    }
    ctx->listener = env->NewGlobalRef(listener);

    lenny_sender_config cfg{};
    env->GetByteArrayRegion(device_id, 0, LENNY_DEVICE_ID_SIZE, reinterpret_cast<jbyte*>(cfg.identity.device_id));
    const char* cname = env->GetStringUTFChars(name, nullptr);
    cfg.identity.device_name = cname;
    cfg.identity.platform = LENNY_PLATFORM_ANDROID;
    std::vector<lenny_mode> m;
    const jsize n = env->GetArrayLength(modes) / 4;
    jint* mv = env->GetIntArrayElements(modes, nullptr);
    for (jsize i = 0; i < n; ++i)
        m.push_back({uint16_t(mv[4 * i]), uint16_t(mv[4 * i + 1]), uint16_t(mv[4 * i + 2]), uint16_t(mv[4 * i + 3])});
    env->ReleaseIntArrayElements(modes, mv, JNI_ABORT);
    cfg.modes = m.data();
    cfg.mode_count = m.size();
    cfg.max_bitrate_kbps = uint32_t(max_bitrate);
    cfg.controls = uint32_t(controls);

    lenny_sender_callbacks cb{};
    cb.user = ctx;
    cb.on_stream_config = on_stream_config;
    cb.on_control = on_control;
    ctx->session = lenny_sender_create(&cfg, &cb);  // copies everything it needs
    env->ReleaseStringUTFChars(name, cname);
    if (!ctx->session) {
        env->DeleteGlobalRef(ctx->listener);
        delete ctx;
        return 0;
    }
    return reinterpret_cast<jlong>(ctx);
}

JNIEXPORT jlong JNICALL Java_com_spizganed_android_1camera_LennyNative_sessionPtr(JNIEnv*, jclass, jlong h) {
    return h ? reinterpret_cast<jlong>(ctx_of(h)->session) : 0;
}

JNIEXPORT jint JNICALL Java_com_spizganed_android_1camera_LennyNative_connect(JNIEnv* env, jclass, jlong h, jstring host,
                                                                             jint port, jbyteArray token) {
    if (!h || !host) return LENNY_E_INVALID_ARG;
    uint8_t tok[LENNY_PAIR_TOKEN_SIZE];
    const bool has_token = token && env->GetArrayLength(token) == LENNY_PAIR_TOKEN_SIZE;
    if (has_token) env->GetByteArrayRegion(token, 0, LENNY_PAIR_TOKEN_SIZE, reinterpret_cast<jbyte*>(tok));
    const char* chost = env->GetStringUTFChars(host, nullptr);
    jint r = lenny_sender_connect(ctx_of(h)->session, chost, uint16_t(port), has_token ? tok : nullptr);
    env->ReleaseStringUTFChars(host, chost);
    return r;
}

JNIEXPORT jint JNICALL Java_com_spizganed_android_1camera_LennyNative_sendConfig(JNIEnv* env, jclass, jlong h,
                                                                                jobject buf, jint offset, jint size) {
    const uint8_t* p = h && buf ? direct(env, buf, offset) : nullptr;
    return p ? lenny_sender_send_video_config(ctx_of(h)->session, p, size_t(size)) : LENNY_E_INVALID_ARG;
}

JNIEXPORT jint JNICALL Java_com_spizganed_android_1camera_LennyNative_sendFrame(JNIEnv* env, jclass, jlong h, jobject buf,
                                                                               jint offset, jint size, jlong pts_us,
                                                                               jint orientation, jint flags) {
    const uint8_t* p = h && buf ? direct(env, buf, offset) : nullptr;
    return p ? lenny_sender_send_video_frame(ctx_of(h)->session, p, size_t(size), pts_us, uint8_t(orientation),
                                             uint8_t(flags))
             : LENNY_E_INVALID_ARG;
}

JNIEXPORT jint JNICALL Java_com_spizganed_android_1camera_LennyNative_disconnect(JNIEnv*, jclass, jlong h) {
    return h ? lenny_session_disconnect(ctx_of(h)->session) : LENNY_E_INVALID_ARG;
}

JNIEXPORT void JNICALL Java_com_spizganed_android_1camera_LennyNative_destroy(JNIEnv* env, jclass, jlong h) {
    if (!h) return;
    Ctx* ctx = ctx_of(h);
    lenny_session_destroy(ctx->session);  // joins the I/O thread, so no callback can use ctx after this
    env->DeleteGlobalRef(ctx->listener);
    delete ctx;
}

JNIEXPORT jlong JNICALL Java_com_spizganed_android_1camera_LennyNative_nowUs(JNIEnv*, jclass) { return lenny_now_us(); }

}  // extern "C"
