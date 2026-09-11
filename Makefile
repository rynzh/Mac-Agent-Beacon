CC = clang
CFLAGS = -std=c11 -Wall -Wextra -Werror -O2

.PHONY: all test

all: build/beacon-led

build/beacon-led: native/led.c
	mkdir -p build
	$(CC) $(CFLAGS) $< -framework IOKit -framework CoreFoundation -framework ApplicationServices -o $@

test: all
	/usr/bin/ruby -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
