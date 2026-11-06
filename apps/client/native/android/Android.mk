# libanj_rootfs.so for Android (spec #28 A2), built by the Gradle app module
# (android/app/build.gradle.kts, ndkBuild) with the pinned NDK for arm64-v8a
# and x86_64. The same source as Linux (native/posix/rootfs.cc and its .inc
# files); the primitives Android's app sandbox refuses come from
# native/posix/compat_android.h (decisions #123, #130 (1)).
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)
LOCAL_MODULE := anj_rootfs
LOCAL_SRC_FILES := ../posix/rootfs.cc
LOCAL_CPPFLAGS := -std=c++17 -Wall -Wextra -Werror -O2
include $(BUILD_SHARED_LIBRARY)
