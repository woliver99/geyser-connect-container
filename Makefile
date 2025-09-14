.PHONY: install run test

build:
	podman build -t geyser-connect-container ./

run:
	mkdir -p ./geyser-data/
	podman run --userns=keep-id --name geyser-connect-container --rm -v ./geyser-data:/data:z geyser-connect-container

test: build run
