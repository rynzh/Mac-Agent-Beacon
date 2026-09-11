CC = clang
CFLAGS = -std=c11 -Wall -Wextra -Werror -O2

all: build/beacon-led

build/beacon-led: native/led.c
	mkdir -p build
	$(CC) $(CFLAGS) $< -framework IOKit -framework CoreFoundation -framework ApplicationServices -o $@

test: all
	/usr/bin/ruby test/beacon_test.rb
