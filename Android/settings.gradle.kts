pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Necesario para `audioswitch`, dependencia transitiva real de
        // io.livekit:livekit-android (0056_live_streams.sql) -- JitPack es
        // un repositorio público gratuito, no un servicio de pago.
        maven(url = "https://jitpack.io")
    }
}

rootProject.name = "SOCIAL"
include(":app")
