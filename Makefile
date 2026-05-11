.PHONY: install client server test clean

install: client
	@echo "Client built. Server: cd pair && mix deps.get && mix pair server"

client:
	cd pair-client && go build -ldflags="-s -w" -o $(HOME)/go/bin/pair .
	@echo "pair → $(HOME)/go/bin/pair"

server:
	cd pair && mix deps.get && mix compile

test:
	cd pair && mix test
	cd pair-client && go test ./...

clean:
	cd pair && mix clean
	rm -f $(HOME)/go/bin/pair
