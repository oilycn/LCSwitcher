TARGET := iphone:clang:latest:16.0
ARCHS := arm64

TWEAK_NAME = LCSwitcher

LCSwitcher_FILES = LCSwitcher.m
LCSwitcher_CFLAGS = -fobjc-arc -O3 -fvisibility=hidden
LCSwitcher_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore AVKit AVFoundation

.PHONY: all clean

all:
	@./build.sh

clean:
	@rm -f *.dylib *.deb *.zip *.plist
