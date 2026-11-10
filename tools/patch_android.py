#!/usr/bin/env python3
"""Подписывает release-сборку постоянным ключом из ci/debug.keystore,
чтобы новые версии ставились поверх старых."""
import os
import sys

for name, kts in (("android/app/build.gradle", False), ("android/app/build.gradle.kts", True)):
    if not os.path.exists(name):
        continue
    s = open(name, encoding="utf-8").read()
    if kts:
        cfg = '''    signingConfigs {
        create("ci") {
            storeFile = file("../../ci/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {'''
        s = s.replace("signingConfig = signingConfigs.getByName(\"debug\")", "signingConfig = signingConfigs.getByName(\"ci\")")
    else:
        cfg = '''    signingConfigs {
        ci {
            storeFile = file("../../ci/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {'''
        s = s.replace("signingConfig = signingConfigs.debug", "signingConfig = signingConfigs.ci")
    if "signingConfigs.ci" not in s and 'getByName("ci")' not in s:
        sys.exit(f"не нашёл, где подменить подпись в {name}")
    s = s.replace("    buildTypes {", cfg, 1)
    open(name, "w", encoding="utf-8").write(s)
    print(f"подпись ci подключена: {name}")
    break
else:
    sys.exit("build.gradle не найден")
