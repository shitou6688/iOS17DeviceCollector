# iOS17DeviceCollector Makefile
# 
# 编译要求: macOS + Xcode Command Line Tools
# 
# 用法:
#   make          - 编译 dylib
#   make package   - 打包成 .deb
#   make clean     - 清理

ARCHS = arm64
TARGET = iphone:clang:latest:14.0

iOS17DeviceCollector_FILES = iOS17DeviceCollector.m
iOS17DeviceCollector_FRAMEWORKS = Foundation UIKit WebKit
iOS17DeviceCollector_CFLAGS = -fobjc-arc -O2

include $(THEOS)/makefiles/common.mk
LIBRARY_NAME = iOS17DeviceCollector
include $(THEOS_MAKE_PATH)/library.mk

# 仅编译 dylib (不打包)
dylib::
	@echo "Using Theos at: $(THEOS)"
	$(MAKE) -f Makefile

# 无 Theos 环境的直接编译方式:
raw:
	xcrun -sdk iphoneos clang -arch arm64 -dynamiclib \
		-fobjc-arc -O2 \
		-framework Foundation -framework UIKit -framework WebKit \
		-o iOS17DeviceCollector.dylib \
		iOS17DeviceCollector.m
	@echo ""
	@echo "产物: iOS17DeviceCollector.dylib"
	@echo "签名: ldid -S iOS17DeviceCollector.dylib"
	@echo "注入: 用巨魔注入器注入到转转.ipa"

sign:
	ldid -S iOS17DeviceCollector.dylib

clean::
	rm -f iOS17DeviceCollector.dylib
	rm -rf .theos obj
