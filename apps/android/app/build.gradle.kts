plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "app.strongroom.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.strongroom.android"
        // minSdk 26 (Android 8.0): Autofill framework (API 26) and Keystore
        // EC keys. Hardware ECDH (KeyProperties.PURPOSE_AGREE_KEY) needs
        // API 31, so device-bound export/import and biometric unlock are
        // gated at runtime on API >= 31 (docs/OPEN-QUESTIONS.md OQ-1).
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            // Only ABIs the Rust build produced are packaged.
            abiFilters += (System.getenv("STRONGROOM_ABIS") ?: "arm64-v8a").split(" ").filter { it.isNotBlank() }
        }
    }

    // Release signing is optional and comes only from the environment, so no
    // key or password is ever committed. Without these variables the release
    // build is produced unsigned.
    val releaseKeystore = System.getenv("STRONGROOM_ANDROID_KEYSTORE")
    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("STRONGROOM_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("STRONGROOM_ANDROID_KEY_ALIAS") ?: "strongroom"
                keyPassword = System.getenv("STRONGROOM_ANDROID_KEY_PASSWORD")
                    ?: System.getenv("STRONGROOM_ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        debug {
            // Debug keystore is the Gradle default (~/.android/debug.keystore);
            // nothing is committed.
        }
        release {
            isMinifyEnabled = false
            isDebuggable = false
            if (releaseKeystore != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    sourceSets["main"].kotlin.srcDir(layout.buildDirectory.dir("generated/uniffi/kotlin"))
    packaging {
        jniLibs {
            // Keep the .so debuggable in debug builds; no stripping needed.
            keepDebugSymbols += "**/libstrongroom_ffi.so"
        }
    }
    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

// Rust core + Kotlin bindings. Skip with -Pstrongroom.skipRust=true when the
// .so and bindings were produced by a separate step (CI does this).
val buildRust by tasks.registering(Exec::class) {
    group = "build"
    description = "cargo-ndk build of strongroom-ffi + uniffi-bindgen Kotlin bindings"
    workingDir = rootProject.projectDir
    commandLine("bash", "scripts/build-rust.sh")
    onlyIf { !project.hasProperty("strongroom.skipRust") }
}
tasks.named("preBuild") { dependsOn(buildRust) }

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.fragment.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.biometric)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons.core)
    implementation(libs.kotlinx.coroutines.android)
    // UniFFI Kotlin bindings load the Rust library through JNA.
    implementation("${libs.jna.get().module}:${libs.jna.get().version}@aar")

    testImplementation(libs.junit)

    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.junit)
}
