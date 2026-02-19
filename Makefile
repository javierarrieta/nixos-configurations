.PHONY: bootstrap bootstrap-llm01

bootstrap:
	@echo "Usage: make bootstrap AGE_KEY=... HOST=... IP=... DISK_PASSWORD=..."
	@test -n "$(AGE_KEY)" || (echo "Error: AGE_KEY is required" && exit 1)
	@test -n "$(HOST)" || (echo "Error: HOST is required" && exit 1)
	@test -n "$(IP)" || (echo "Error: IP is required" && exit 1)
	@test -n "$(DISK_PASSWORD)" || (echo "Error: DISK_PASSWORD is required" && exit 1)
	./bootstrap_host.sh --age-key "$(AGE_KEY)" --host "$(HOST)" --ip "$(IP)" --disk-password "$(DISK_PASSWORD)"

help:
	@echo "Targets:"
	@echo "  bootstrap       - Bootstrap a new host"
	@echo "  bootstrap-llm01 - Bootstrap llm01 host"
	@echo ""
	@echo "Variables (for bootstrap target):"
	@echo "  AGE_KEY        - Age private key for sops"
	@echo "  HOST           - Hostname (flake .#hostname)"
	@echo "  IP             - Server IP address"
	@echo "  DISK_PASSWORD  - Disk encryption password"
	@echo ""
	@echo "Example: make bootstrap AGE_KEY='AGE-SECRET-KEY...' HOST=llm01 IP=192.168.1.100 DISK_PASSWORD='strong-password'"
	@echo "         make bootstrap-llm01 AGE_KEY='AGE-SECRET-KEY...' IP=192.168.1.100 DISK_PASSWORD='strong-password'"

bootstrap-llm01:
	@$(MAKE) bootstrap HOST=llm01
