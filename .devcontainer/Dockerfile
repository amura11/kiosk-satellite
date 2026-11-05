FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Versions mirror CI (release.yml) and what Flutter 3.44.6 / AGP 9.0.1 resolve to.
ARG FLUTTER_VERSION=3.44.6
ARG ANDROID_PLATFORM=36
ARG ANDROID_BUILD_TOOLS=36.0.0
ARG ANDROID_NDK=28.2.13676358
ARG CMDLINE_TOOLS=11076708

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends openjdk-17-jdk-headless unzip xz-utils zip libglu1-mesa \
    && rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
ENV ANDROID_SDK_ROOT=/opt/android-sdk
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64

RUN mkdir -p ${ANDROID_HOME}/cmdline-tools \
    && curl -fsSL -o /tmp/cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS}_latest.zip \
    && unzip -q /tmp/cmdline-tools.zip -d ${ANDROID_HOME}/cmdline-tools \
    && mv ${ANDROID_HOME}/cmdline-tools/cmdline-tools ${ANDROID_HOME}/cmdline-tools/latest \
    && rm /tmp/cmdline-tools.zip \
    && yes | ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager --licenses >/dev/null \
    && ${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager \
        "platform-tools" "platforms;android-${ANDROID_PLATFORM}" \
        "build-tools;${ANDROID_BUILD_TOOLS}" "ndk;${ANDROID_NDK}" \
    && chown -R vscode:vscode ${ANDROID_HOME}

USER vscode

# Flutter has no devcontainer feature, so it is cloned here and cached as an image layer.
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /home/vscode/flutter \
    && /home/vscode/flutter/bin/flutter config --android-sdk ${ANDROID_HOME} --no-analytics \
    && /home/vscode/flutter/bin/flutter precache --android --universal

ENV PATH=/home/vscode/flutter/bin:${ANDROID_HOME}/platform-tools:${PATH}
