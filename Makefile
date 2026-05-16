.PHONY: server test clean

server:
	cd pair && mix deps.get && mix compile

test:
	cd pair && mix test

clean:
	cd pair && mix clean
