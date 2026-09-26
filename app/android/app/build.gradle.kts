import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.exists()) propertiesFile.inputStream().use { load(it) }
}
fun signingValue(property: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() }
        ?: signingProperties.getProperty(property)?.takeIf { it.isNotBlank() }
val releaseStore = signingValue("storeFile", "DDECK_KEYSTORE_PATH")
val releaseStorePassword = signingValue("storePassword", "DDECK_KEYSTORE_PASSWORD")
val releaseAlias = signingValue("keyAlias", "DDECK_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "DDECK_KEY_PASSWORD")
val releaseSigningReady = listOf(releaseStore, releaseStorePassword, releaseAlias, releaseKeyPassword).all { it != null }

gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name.contains("Release", ignoreCase = true) } && !releaseSigningReady) {
        throw GradleException("릴리스 서명 설정이 없습니다. docs/ANDROID_SIGNING.md를 따라 설정하세요.")
    }
}

android {
    namespace = "kr.co.ddeck.ddeck_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        // flutter_local_notifications 가 java.time 을 쓴다. 구형 안드로이드에서도
        // 동작하도록 desugaring 을 켠다. 켜지 않으면 빌드가 거부된다.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "kr.co.ddeck.ddeck_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningReady) {
            create("release") {
                storeFile = file(releaseStore!!)
                storePassword = releaseStorePassword
                keyAlias = releaseAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningReady) signingConfig = signingConfigs.getByName("release")
        }
    }
}

dependencies {
    // 위 isCoreLibraryDesugaringEnabled 와 짝을 이룬다.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
