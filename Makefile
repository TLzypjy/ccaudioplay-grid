export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export DEBUG = 0

LIBRARY_NAME = CCAudioPlayPres CCAudioPlayAllLayout

CCAudioPlayPres_FILES = main/ccgrid.mm main3/ccpre.mm
CCAudioPlayPres_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
CCAudioPlayPres_FRAMEWORKS = UIKit Foundation ImageIO CoreGraphics
CCAudioPlayPres_LDFLAGS = -Wl,-undefined,dynamic_lookup

CCAudioPlayAllLayout_FILES = main2/ccall.mm
CCAudioPlayAllLayout_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
CCAudioPlayAllLayout_FRAMEWORKS = UIKit Foundation
CCAudioPlayAllLayout_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/library.mk
