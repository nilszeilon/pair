.PHONY: build install clean

build:
	go build -ldflags="-s -w" -o pair .

install:
	go install .

clean:
	rm -f pair
