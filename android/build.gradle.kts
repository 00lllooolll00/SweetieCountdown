allprojects {
    repositories {
        maven("https://maven.aliyun.com/repository/google/")
        maven("https://maven.aliyun.com/repository/public/")
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}
// 沙箱离线:pub 原生插件(如 package:jni)不钉 ndkVersion，AGP 默认索取 NDK 28(本地无完整包)。
// 根脚本 classpath 没有 AGP 类型，用反射统一钉到沙箱 NDK 27；执行时机在 AGP 读值之前。
subprojects {
    pluginManager.withPlugin("com.android.library") {
        extensions.findByName("android")?.let { ext ->
            try {
                ext.javaClass.getMethod("setNdkVersion", String::class.java)
                    .invoke(ext, "27.0.12077973")
            } catch (ignored: Exception) {
                logger.warn("跳过 ${project.path} 的 NDK 钉定:${ignored.message}")
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
