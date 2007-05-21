all: test

Build: Build.PL
	perl Build.PL

test: Build
	./Build test

.PHONY: test all
