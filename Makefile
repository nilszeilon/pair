.PHONY: build test clean

build:
	go build -ldflags="-s -w" -o pair .

test:
	go test ./...

clean:
	rm -f pair
