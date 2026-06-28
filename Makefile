.PHONY: test smoke install install-deps uninstall doctor

test:
	./tests/static.sh

smoke:
	./tests/install-smoke.sh

install:
	./install.sh

install-deps:
	./install.sh --deps

uninstall:
	./uninstall.sh

doctor:
	workspace-stream doctor
