.PHONY: check test

check:
	bash -n agent-manager workspace.sh tests/workspace_test.sh tests/server_test.sh tests/app_server_test.sh tests/supervisor_test.sh tests/supervisor_reliability_test.sh tests/fake_workspace.sh
	@if command -v plutil >/dev/null 2>&1; then plutil -lint dev.funxy.agent-manager.app-server.plist dev.funxy.agent-manager.supervisor.plist >/dev/null; fi
	funxy manager.lang >/dev/null
	funxy supervisor.lang --check >/dev/null
	funxy tests/namespace_test.lang >/dev/null

test: check
	./tests/workspace_test.sh
	./tests/server_test.sh
	./tests/app_server_test.sh
	./tests/supervisor_test.sh
	./tests/supervisor_reliability_test.sh
