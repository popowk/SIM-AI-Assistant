plugins { id("com.android.application") }

// Signing credentials are provided only by the developer's trusted environment
// or GitHub Actions Secrets. Never add a private keystore to this repository.
// This remains a debuggable build because Mac ADB configuration sync uses run-as.
val stableKeystorePath = System.getenv("SIMAI_ANDROID_KEYSTORE_PATH").orEmpty()
val stableStorePassword = System.getenv("SIMAI_ANDROID_KEYSTORE_PASSWORD").orEmpty()
val stableKeyAlias = System.getenv("SIMAI_ANDROID_KEY_ALIAS").orEmpty()
val stableKeyPassword = System.getenv("SIMAI_ANDROID_KEY_PASSWORD").orEmpty()
val stableFields = listOf(
    stableKeystorePath, stableStorePassword, stableKeyAlias, stableKeyPassword
)
require(stableFields.all { it.isNotEmpty() } || stableFields.all { it.isEmpty() }) {
    "Android stable signing must specify all four environment values"
}
val hasStableSigning = stableFields.all { it.isNotEmpty() }

android {
    namespace = "com.popowk.simai.companion"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.popowk.simai.companion"
        minSdk = 26
        targetSdk = 32
        versionCode = 32
        versionName = "0.3.27"
    }
    signingConfigs {
        if (hasStableSigning) {
            create("simaiStableDebug") {
                storeFile = file(stableKeystorePath)
                storePassword = stableStorePassword
                keyAlias = stableKeyAlias
                keyPassword = stableKeyPassword
            }
        }
    }
    buildTypes {
        getByName("debug") {
            if (hasStableSigning) {
                signingConfig = signingConfigs.getByName("simaiStableDebug")
            }
        }
        getByName("release") { isMinifyEnabled = false }
    }
    buildFeatures { aidl = true }
    sourceSets.getByName("main").java.srcDir("../../AudioProbe/src")
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
}
