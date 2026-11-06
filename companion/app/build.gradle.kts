plugins {
    id("com.android.application")
}

android {
    namespace = "app.chessuite.companion"
    compileSdk = 34

    defaultConfig {
        applicationId = "app.chessuite.companion"
        minSdk = 24
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // signed with the debug key so it installs without extra setup
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
