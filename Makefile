CC = clang
CFLAGS = -std=c11 -Wall -Wextra -Werror -O2

.PHONY: all test

all: build/beacon-led build/beacon-backlight

build/beacon-led: native/led.c
	mkdir -p build
	$(CC) $(CFLAGS) $< -framework IOKit -framework CoreFoundation -framework ApplicationServices -o $@

build/beacon-backlight: native/backlight.m
	mkdir -p build
	$(CC) -fobjc-arc -Wall -Wextra -Werror -O2 $< -framework Foundation -o $@

build/backlight-native-test: test/backlight_native_test.m native/backlight.m
	mkdir -p build
	$(CC) -fobjc-arc -Wall -Wextra -Werror -O2 $< -framework Foundation -o $@

test: all build/backlight-native-test
	./build/backlight-native-test
	/usr/bin/ruby -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
