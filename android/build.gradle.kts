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
// 沙箱离线:pub 原生插件(如 package:jni)默认索取 NDK 28 / build-tools 36 / cmake(本地均无完整包)。
// 子工程脚本会覆盖普通 subprojects{} 赋值，必须 afterEvaluate(本回调注册早于 AGP，执行时脚本已跑完)。
subprojects {
    pluginManager.withPlugin("com.android.library") {
        project.afterEvaluate {
            extensions.findByName("android")?.let { ext ->
                try {
                    ext.javaClass.getMethod("setNdkVersion", String::class.java)
                        .invoke(ext, "27.0.12077973")
                    ext.javaClass.getMethod("setBuildToolsVersion", String::class.java)
                        .invoke(ext, "34.0.0")
                    val enb = ext.javaClass.getMethod("getExternalNativeBuild").invoke(ext)
                    val cmake = enb.javaClass.getMethod("getCmake").invoke(enb)
                    cmake.javaClass.getMethod("setVersion", String::class.java)
                        .invoke(cmake, "4.4.3")
                } catch (ignored: Exception) {
                    logger.warn("跳过 ${project.path} 的离线钉定:${ignored.message}")
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
