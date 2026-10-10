SHELL=/bin/bash

ZIG_BUILD_ARGS=-Dexamples=true --release=fast --verbose

.PHONY: clean retest build test build-egs

build:
	zig build --verbose

test:
	zig build test --verbose --summary new

retest: clean test

clean:
	rm -rf zig-out .zig-cache *.gp example/*.{gp,png,txt,csv}

run-egs: 
	zig build examples ${ZIG_BUILD_ARGS}
	cd example; \
	for x in *.zig; do \
	    zig build run-$${x%.zig} ${ZIG_BUILD_ARGS}; \
	done

pngs: 
	cd example && gnuplot *.gp
	mkdir -p example/out
	mv example/*.{gp,png,txt} example/out/

