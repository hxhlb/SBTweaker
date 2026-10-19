# Rootless is the default. Override THEOS, TARGET and
# THEOS_PACKAGE_SCHEME=roothide for a roothide package.
export THEOS ?= $(HOME)/theos

export TARGET ?= iphone:clang:15.6:15.0
export ARCHS = arm64 arm64e

THEOS_PACKAGE_SCHEME ?= rootless

INSTALL_TARGET_PROCESSES = SpringBoard

TWEAK_NAME = SBTweaker
SBTweaker_FILES = Tweak.x
SBTweaker_CFLAGS = -fobjc-arc

# Diagnostic builds only: make SBT_DIAG=1 adds Diag.x (logging, never released).
ifeq ($(SBT_DIAG),1)
SBTweaker_FILES += Diag.x
SBTweaker_CFLAGS += -DSBT_DIAG=1
endif

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
SBTweaker_LIBRARIES += roothide
endif

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += sbtweakerprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
