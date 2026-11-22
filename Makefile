export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export DEBUG = 0

# BUILD_RANDOM=1  -> CCAudioPlayRandom(随机洗牌轮播, 注入 SpringBoard)
# BUILD_FIX=1     -> CCAudioPlayFix(视频自动暂停修复)
# BUILD_LIBROOT=1 -> libroot(roothide 随机 jbroot 兼容 shim, 供 libroot_dyn 二进制 dlopen)
# 默认            -> CCAudioPlayPres(网格素材库 loader)
ifeq ($(BUILD_LIBROOT),1)
LIBRARY_NAME = libroot
libroot_FILES = libroot_shim/libroot.c
libroot_CFLAGS = -Wno-unused-function
libroot_LDFLAGS = -Wl,-undefined,dynamic_lookup
else ifeq ($(BUILD_RANDOM),1)
LIBRARY_NAME = CCAudioPlayRandom
CCAudioPlayRandom_FILES = fix/CCAudioPlayRandom.mm
CCAudioPlayRandom_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
CCAudioPlayRandom_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia
CCAudioPlayRandom_LDFLAGS = -Wl,-undefined,dynamic_lookup
else ifeq ($(BUILD_FIX),1)
LIBRARY_NAME = CCAudioPlayFix
CCAudioPlayFix_FILES = fix/CCAudioPlayFix.mm
CCAudioPlayFix_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
CCAudioPlayFix_FRAMEWORKS = Foundation UIKit AVFoundation CoreMedia
CCAudioPlayFix_LDFLAGS = -Wl,-undefined,dynamic_lookup
else
LIBRARY_NAME = CCAudioPlayPres
CCAudioPlayPres_FILES = main/ccgrid.mm
CCAudioPlayPres_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
CCAudioPlayPres_FRAMEWORKS = UIKit Foundation ImageIO CoreGraphics
CCAudioPlayPres_LDFLAGS = -Wl,-undefined,dynamic_lookup
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/library.mk
