DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsTrollOpenFixBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsTrollOpenFix
AxsTrollOpenFix_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsTrollOpenFix_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsTrollOpenFix_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsTrollOpenFix_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk


