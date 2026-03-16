.PHONY: all cli wasm watch

all: cli wasm

cli:
	zig build -Doptimize=Debug

wasm:
	zig build copy-wasm

watch:
	zig build copy-wasm --watch
