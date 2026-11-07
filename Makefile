export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
export DEBUG = 0

LIBRARY_NAME = CCAudioPlayPres CCAudioPlayAllLayout

# 共享层: 真机模块与设置面板预览共用同一份源文件 (禁止复制粘贴第二份)
TLPX_SHARED_FILES = Shared/TLPXConstants.m Shared/TLPXLayoutEngine.m Shared/TLPXMediaSnapshot.m Shared/TLPXPlayerContentView.m
TLPX_SHARED_CFLAGS = -IShared

CCAudioPlayPres_FILES = main/ccgrid.mm main3/ccpre.mm $(TLPX_SHARED_FILES)
CCAudioPlayPres_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations $(TLPX_SHARED_CFLAGS)
CCAudioPlayPres_FRAMEWORKS = UIKit Foundation ImageIO CoreGraphics
CCAudioPlayPres_LDFLAGS = -Wl,-undefined,dynamic_lookup

CCAudioPlayAllLayout_FILES = main2/ccall.mm $(TLPX_SHARED_FILES)
CCAudioPlayAllLayout_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations $(TLPX_SHARED_CFLAGS)
CCAudioPlayAllLayout_FRAMEWORKS = UIKit Foundation
CCAudioPlayAllLayout_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS)/makefiles/common.mk
include $(THEOS)/makefiles/library.mk
