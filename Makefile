ARCHS = arm64 arm64e
export ARCHS

TARGET := iphone:clang:latest:15.0
export TARGET

THEOS_PACKAGE_SCHEME = roothide
export THEOS_PACKAGE_SCHEME

include $(THEOS)/makefiles/common.mk

SUBPROJECTS = FilzaPatches AutoPatches

include $(THEOS_MAKE_PATH)/aggregate.mk

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
		ln -sf "/usr/lib/DynamicPatches/FilzaPatches.dylib" "$(THEOS_STAGING_DIR)/$$file.roothidepatch"; \
	done;

clean::
	rm -rf ./packages/*