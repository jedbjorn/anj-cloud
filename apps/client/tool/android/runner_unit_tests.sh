#!/usr/bin/env bash
# JVM unit tests of Android runner logic that needs no device (PR #64 review F1: PendingCall),
# compiled with the Kotlin compiler and JUnit from the toolchain's Gradle cache (offline). The
# Flutter Gradle plugin refuses a plain `gradlew testDebugUnitTest` here ([CXX1400]), so this
# runs the same sources directly.
#   tool/android/runner_unit_tests.sh <n>   -> scope anj-test-${ANJ_TAG:-a5}-<n>
set -euo pipefail
N="${1:?usage: runner_unit_tests.sh <n>}"; TAG="${ANJ_TAG:-a5}"
P="$(cd "$(dirname "$0")/../../android/app/src" && pwd)"
T=$HOME/.local/share/anj-cloud/toolchains/android
C="$T/gradle/caches/modules-2/files-2.1"
export JAVA_HOME="${JAVA_HOME:-$T/jdk-21}"
pick() { find "$C/$1/$2" -name "*.jar" ! -name "*-sources.jar" | head -1; }
K=$(pick org.jetbrains.kotlin/kotlin-compiler-embeddable 2.4.0)
STD=$(pick org.jetbrains.kotlin/kotlin-stdlib 2.4.0)
CP="$K:$STD:$(pick org.jetbrains.kotlin/kotlin-script-runtime 2.4.0):$(pick org.jetbrains.kotlin/kotlin-reflect 2.2.21)"
CP="$CP:$(pick org.jetbrains.kotlin/kotlin-daemon-embeddable 2.4.0):$(pick org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm 1.8.1)"
CP="$CP:$(pick org.jetbrains/annotations 23.0.0)"
JUNIT="$(pick junit/junit 4.12):$(pick org.hamcrest/hamcrest-core 1.3)"
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
systemd-run --user --scope --quiet --unit="anj-test-$TAG-$N" -p MemoryMax=2G -p TasksMax=512 \
  bash -c '
    set -euo pipefail
    "$JAVA_HOME/bin/java" -cp "$1" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect \
      -cp "$2:$3" -d "$4" "$5/main/kotlin/cloud/anj/anj_cloud/PendingCall.kt" \
      "$5/test/kotlin/cloud/anj/anj_cloud/PendingCallTest.kt"
    "$JAVA_HOME/bin/java" -cp "$4:$2:$3" org.junit.runner.JUnitCore cloud.anj.anj_cloud.PendingCallTest
  ' _ "$CP" "$STD" "$JUNIT" "$OUT" "$P"
