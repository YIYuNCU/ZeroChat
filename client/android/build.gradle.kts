allprojects {
    repositories {
        // Maven Central is intermittently slow/unreachable on some networks.
        maven(url = "https://maven.aliyun.com/repository/public")
        // Google Maven is intermittently unreachable on some networks.
        maven(url = "https://maven.aliyun.com/repository/google")
        // Flutter engine artifacts are hosted on Google Storage; use the
        // official China mirror first, with Google as fallback.
        maven(url = "https://storage.flutter-io.cn/download.flutter.io") {
            content { includeGroup("io.flutter") }
        }
        google()
        mavenCentral()
    }
}

rootProject.buildDir = file("../build")
subprojects {
    project.buildDir = file("${rootProject.buildDir}/${project.name}")
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.buildDir)
}
