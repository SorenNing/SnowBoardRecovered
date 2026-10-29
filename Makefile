TARGET = iphone:clang:16.5:15.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SnowBoardRecovered
SnowBoardRecovered_FILES = Tweak.m
SnowBoardRecovered_CFLAGS = -fobjc-arc
SnowBoardRecovered_FRAMEWORKS = UIKit Foundation

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
