TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

# RootHide / Dopamine roothide 与常规 rootless 完全兼容
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TimeSeconds
TimeSeconds_FILES = Tweak.xm
TimeSeconds_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TimeSeconds_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
