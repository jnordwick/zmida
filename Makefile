.PHONY: clean retest build test

build:
	zig build --verbose

test:
	zig build test --verbose --summary new

retest: clean test

clean:
	rm -rf zig-out .zig-cache *.gp examples/*.gp examples/*.png

