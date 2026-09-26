// Give the shared library a SONAME on ELF targets. Without it, whatever links liblenny_core.so (the Android JNI
// shim, CMake consumers) records the build machine's absolute path as DT_NEEDED and fails to load on the device.
fn main() {
    let os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if matches!(os.as_str(), "linux" | "android") {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,liblenny_core.so");
    }
}
