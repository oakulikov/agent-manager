.PHONY: check test

check:
	bash -n agent-manager workspace.sh tests/workspace_test.sh tests/server_test.sh
	funxy manager.lang >/dev/null

test: check
	./tests/workspace_test.sh
	./tests/server_test.sh
