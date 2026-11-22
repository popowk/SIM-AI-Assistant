plugins { id("com.android.application") }

android {
    namespace = "com.popowk.simai.companion"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.popowk.simai.companion"
        minSdk = 26
        targetSdk = 32
        versionCode = 6
        versionName = "0.3.1"
    }
    buildTypes {
        getByName("release") { isMinifyEnabled = false }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
