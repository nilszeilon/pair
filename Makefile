.PHONY: install server test clean

install:
	cd pair && mix deps.get && mix compile

server:
	cd pair && mix deps.get && mix compile

test:
	cd pair && mix test

clean:
	cd pair && mix clean
