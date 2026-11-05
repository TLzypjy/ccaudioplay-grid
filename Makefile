export ARCHS = arm64e
export TARGET = iphone:clang:latest:15.0
export DEBUG = 0

LIBRARY_NAME = CCAudioPlayPres
CCAudioPlayPres_FILES = main/ccgrid.mm
CCAudioPlayPres_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations
CCAudioPlayPres_FRAMEWORKS = UIKit Foundation ImageIO CoreGraphics
CCAudioPlayPres_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/library.mk
