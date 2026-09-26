group = "com.spizganed.android_camera"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// The core is a Rust crate (/core). cargo-ndk builds liblenny_core.so per ABI; it's packaged from jniLibs and
// linked by the JNI shim (src/main/cpp). Needs `cargo install cargo-ndk` and the Android Rust targets
// (rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android).
val rustJniLibs = layout.buildDirectory.dir("rustJniLibs")
val cargoNdk by tasks.registering(Exec::class) {
    val out = rustJniLibs.get().asFile
    workingDir = file("../../../core")
    inputs.dir(file("../../../core/src"))
    inputs.files(file("../../../core/Cargo.toml"), file("../../../core/build.rs"), file("../../../Cargo.lock"))
    outputs.dir(out)
    commandLine(
        "cargo", "ndk", "--platform", "24",
        "-t", "arm64-v8a", "-t", "armeabi-v7a", "-t", "x86_64", "-t", "x86",
        "-o", out.absolutePath, "build", "--release", "--lib",
    )
    val ndk = androidComponents.sdkComponents.ndkDirectory
    doFirst { environment("ANDROID_NDK_HOME", ndk.get().asFile.absolutePath) }
}
tasks.named("preBuild") { dependsOn(cargoNdk) }

android {
    namespace = "com.spizganed.android_camera"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            jniLibs.srcDir(rustJniLibs.get().asFile) // filled by cargoNdk (preBuild depends on it)
        }
    }

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DLENNY_RUST_LIB_DIR=${rustJniLibs.get().asFile.absolutePath}",
                )
            }
        }
    }

    ndkVersion = "30.0.16248370"

    // JNI shim only; it links the Rust liblenny_core.so built by cargoNdk above.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    implementation("androidx.core:core-ktx:1.13.1")
    // QR scan in the system UI: no camera permission, no scanner of our own.
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
}
