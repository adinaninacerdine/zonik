allprojects {
    repositories {
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

// Deux rustines pour tflite_flutter :
// 1. Son Java compile en 1.8 mais son Kotlin hérite du 17 par défaut ->
//    "Inconsistent JVM Target" : on aligne son Kotlin sur SON Java (1.8).
// 2. Il compile contre android-31, mais TFLite 2.16 (forcé dans app/ pour
//    résoudre le conflit de namespaces AGP 9) exige compileSdk >= 34 :
//    on remonte son compileSdk. (afterEvaluate ciblé : ce sous-projet
//    n'est pas encore évalué au moment où la racine se configure.)
project(":tflite_flutter") {
    afterEvaluate {
        extensions.configure(com.android.build.gradle.LibraryExtension::class) {
            compileSdk = 36
        }
    }
    tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class).configureEach {
        compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
