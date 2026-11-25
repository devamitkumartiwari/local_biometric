group = "com.amit.local_biometric"
version = "0.0.5"

plugins {
    id("com.android.library")
}

// AGP 9+ compiles Kotlin itself ("built-in Kotlin"), on by default unless the host app sets
// `android.builtInKotlin=false` (Flutter's current app template still does). Applying the Kotlin
// Gradle Plugin on top of built-in Kotlin is what Flutter warns will become a build failure, but
// apps on AGP 8, or with built-in Kotlin disabled, still need KGP to compile this plugin's Kotlin
// sources. So apply KGP only when built-in Kotlin isn't active.
val agpMajorVersion = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
val builtInKotlinEnabled = agpMajorVersion >= 9 &&
    (findProperty("android.builtInKotlin")?.toString()?.toBooleanStrictOrNull() ?: true)
if (!builtInKotlinEnabled) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

android {
    namespace = "com.amit.local_biometric"
    compileSdk = 37

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }
}

// Configured through the compile tasks rather than the `kotlin {}` extension accessor, which
// only exists when KGP is applied in the `plugins {}` block; this works in both modes above.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.biometric:biometric:1.4.0-rc01")
    implementation("androidx.appcompat:appcompat:1.8.0")
    implementation("androidx.lifecycle:lifecycle-common:2.11.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
}
