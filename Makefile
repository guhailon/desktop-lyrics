# 巨魔歌词桌面 — DesktopLyrics (original Theos tweak)
# 目标机型：iPhone 11 / iOS 16.5 / Dopamine (rootless)。
# 构建：macOS + Xcode + Theos，或 GitHub Actions（macos runner）。
# 本地 Linux 冒烟构建见 hidden_files/build_smoke_1.0.0.sh（需 clang 交叉工具链 + iOS SDK + ldid）。
ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DesktopLyrics

DesktopLyrics_FILES = Tweak.xm
DesktopLyrics_CFLAGS = -fobjc-arc
DesktopLyrics_PRIVATE_FRAMEWORKS = MediaRemote

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
