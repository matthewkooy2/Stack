.PHONY: setup doctor dev login test clean
PROVIDER ?= codex
DAILY_LIMIT ?= 10

setup:
	python3 scripts/contributor.py setup
doctor:
	python3 scripts/contributor.py doctor
dev:
	python3 scripts/contributor.py dev
login:
	python3 scripts/contributor.py login --provider "$(PROVIDER)" --owner "$(OWNER)" --daily-limit "$(DAILY_LIMIT)"
test:
	python3 scripts/contributor.py test
clean:
	python3 scripts/contributor.py clean
