ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0

THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FilzaPatches AutoPatches

FilzaPatches_FILES = Patches.mm
FilzaPatches_CFLAGS = -fobjc-arc
FilzaPatches_LDFLAGS = -L./ -ldobby
FilzaPatches_INSTALL_PATH = /usr/lib/DynamicPatches

AutoPatches_FILES = AutoPatches.mm
AutoPatches_CFLAGS = -fobjc-arc
AutoPatches_LDFLAGS = -L./ -ldobby
AutoPatches_INSTALL_PATH = /usr/lib/DynamicPatches


include $(THEOS_MAKE_PATH)/library.mk


PATCH_FILES = \
	"/Applications/Filza.app/Filza" \
	"/Applications/Filza.app/PlugIns/Sharing.appex/Sharing" \
	"/usr/libexec/filza/Filza" \
	"/usr/libexec/filza/FilzaHelper" \
	"/usr/libexec/filza/FilzaWebDAVServer"


before-package::
	for file in $(PATCH_FILES); do \
		echo add patch file $$file at $$(dirname "$$file"); \
		dir=$$(dirname "$$file"); \
		mkdir -p "$(THEOS_STAGING_DIR)/$$dir" ; \
		ln -s "/usr/lib/DynamicPatches/FilzaPatches.dylib" "$(THEOS_STAGING_DIR)/$$file.roothidepatch"; \
	done;

clean::
	rm -rf ./packages/*
	