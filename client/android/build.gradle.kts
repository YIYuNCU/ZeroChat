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

// Project.buildDir 在 Gradle 9 已弃用，改用 layout.buildDirectory；输出位置不变（client/build/<project>）。
val sharedBuildDir: Directory = rootProject.layout.projectDirectory.dir("../build")
rootProject.layout.buildDirectory.set(sharedBuildDir)
subprojects {
    project.layout.buildDirectory.set(sharedBuildDir.dir(project.name))
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
