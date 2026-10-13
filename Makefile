# Deskterior developer tasks. Scripts live in scripts/; every target works with Command Line Tools only.
.PHONY: build release test lint app install run clean

build:
	swift build

release:
	swift build -c release --product Deskterior

test:
	scripts/swift-test.sh

lint:
	scripts/check-file-safety.sh

check: build test lint

app:
	scripts/build-app.sh

install: app
	rm -rf /Applications/Deskterior.app
	ditto build/Deskterior.app /Applications/Deskterior.app

run:
	swift run Deskterior --windowed

clean:
	rm -rf .build .build-* build
