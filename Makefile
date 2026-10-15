.PHONY: setup doctor dev login test clean
PROVIDER ?= codex

setup:
	python3 scripts/contributor.py setup
doctor:
	python3 scripts/contributor.py doctor
dev:
	python3 scripts/contributor.py dev
login:
	python3 scripts/contributor.py login --provider "$(PROVIDER)"
test:
	python3 scripts/contributor.py test
clean:
	python3 scripts/contributor.py clean
