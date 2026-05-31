plugins {
    id("org.jetbrains.intellij.platform") version "2.2.1"
    kotlin("jvm") version "2.0.21"
}

group = "local.ai-monitor"
version = "0.1.0"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        intellijIdeaCommunity("2024.3")
    }
}

kotlin {
    jvmToolchain(17)
}

intellijPlatform {
    pluginConfiguration {
        id = "local.ai-monitor.jetbrains"
        name = "AI Monitor"
        version = project.version.toString()
    }
}
