export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export DEBUG = 0

# BUILD_FIX=1 时构建 CCAudioPlayFix(视频自动暂停修复), 默认构建 CCAudioPlayPres(网格素材库)
ifeq ($(BUILD_FIX),1)
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
