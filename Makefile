.PHONY: build test app run clean

build:
	swift build

test:
	swift test

app:
	scripts/make-app.sh

# Quit any running AuthReach first (e.g. the installed release), so the build
# you just made is the one in the menu bar — otherwise two instances share the
# bundle id and the new one is easy to miss.
run: app
	-pkill -x AuthReach
	open "build/AuthReach.app"

clean:
	rm -rf .build build
