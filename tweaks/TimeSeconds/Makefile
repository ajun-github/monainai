TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e

# RootHide / Dopamine roothide 与常规 rootless 完全兼容
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TimeSeconds
TimeSeconds_FILES = Tweak.xm
TimeSeconds_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
TimeSeconds_FRAMEWORKS = UIKit Foundation

BUNDLE_NAME = TimeSecondsPrefs
TimeSecondsPrefs_FILES = RootListController.m
TimeSecondsPrefs_INSTALL_PATH = /Library/PreferenceBundles
TimeSecondsPrefs_CFLAGS = -fobjc-arc
TimeSecondsPrefs_FRAMEWORKS = UIKit Foundation
TimeSecondsPrefs_RESOURCE_FILES = prefs/Info.plist prefs/Root.plist prefs/entry.plist
# PSListController 来自 Preferences.framework，运行期由 Settings 提供
TimeSecondsPrefs_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 SpringBoard"
