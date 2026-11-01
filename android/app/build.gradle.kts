plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Pinned native dependencies live outside Git; tool/setup.py --native provisions them.
val nativeCache = System.getenv("RECEPTIONIST_NATIVE_CACHE")
    ?: "${System.getProperty("user.home")}/.cache/android-ai-receptionist"

android {
    namespace = "ai.local.receptionist"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDir("$nativeCache/jniLibs")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ai.local.receptionist"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk { abiFilters.add("arm64-v8a") }
        externalNativeBuild {
            cmake {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
                arguments.add("-DANDROID_STL=c++_shared")
                arguments.add("-DORT_LIB_DIR=$nativeCache/jniLibs")
                arguments.add("-DLLAMA_SOURCE=$nativeCache/llama.cpp")
            }
        }
    }

    packaging {
        jniLibs { useLegacyPackaging = true }
    }

    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Local sideload build; signed with the debug key.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // JVM unit tests for pure Kotlin code (e.g. the MMS PDU reader).
    testImplementation("junit:junit:4.13.2")
}
