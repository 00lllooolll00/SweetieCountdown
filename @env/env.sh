#!/usr/bin/env bash
# SweetieCountdown 沙箱环境封装 — 必须在任何 flutter/dart/gradle 命令前 source 本文件
# 用法: source "@env/env.sh"  (需 bash)
set -e
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  export SWEETIE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  export SWEETIE_ROOT="/home/n1netynine99/WorkSpace/GitProject/SweetieCountdown"
fi
export PUB_CACHE="$SWEETIE_ROOT/@env/.pub_cache"
export GRADLE_USER_HOME="$SWEETIE_ROOT/@env/.gradle"
export XDG_CONFIG_HOME="$SWEETIE_ROOT/@env/.config"
export XDG_CACHE_HOME="$SWEETIE_ROOT/@env/.cache"
export XDG_DATA_HOME="$SWEETIE_ROOT/@env/.local/share"
export ANDROID_USER_HOME="$SWEETIE_ROOT/@env/.android"
export ANDROID_EMULATOR_HOME="$SWEETIE_ROOT/@env/.android"
export FLUTTER_ROOT="$SWEETIE_ROOT/@env/flutter"
export PATH="$FLUTTER_ROOT/bin:$PATH"
# 沙箱临时目录：防止继承 ctx 沙箱已删除的 TMPDIR
export TMPDIR="$SWEETIE_ROOT/@env/.tmp"
export TEMP="$TMPDIR"
export TMP="$TMPDIR"
# 国内镜像加速：存储用腾讯云（实测最快且有新版 engine），Pub 用清华 TUNA
export FLUTTER_STORAGE_BASE_URL="https://mirrors.cloud.tencent.com/flutter"
export PUB_HOSTED_URL="https://mirrors.tuna.tsinghua.edu.cn/dart-pub"
export FLUTTER_GIT_URL="https://mirrors.tuna.tsinghua.edu.cn/git/flutter-sdk.git"
# Android SDK 使用沙箱内 @env/android-sdk（平台/构建工具/NDK 均为本地拷贝，零远端、零宿主写入）
export ANDROID_HOME="$SWEETIE_ROOT/@env/android-sdk"
export ANDROID_SDK_ROOT="$SWEETIE_ROOT/@env/android-sdk"
mkdir -p "$PUB_CACHE" "$GRADLE_USER_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$ANDROID_USER_HOME" "$TMPDIR"
