ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0

THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = AutoPatches

AutoPatches_FILES = AutoPatches.mm
AutoPatches_CFLAGS = -fobjc-arc
AutoPatches_LDFLAGS = $(abspath libdobby.a)
AutoPatches_INSTALL_PATH = /usr/lib/DynamicPatches

include $(THEOS_MAKE_PATH)/library.mk

clean::
	rm -rf ./packages/*
