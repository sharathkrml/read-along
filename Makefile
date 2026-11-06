# ReadAlong — build and packaging shortcuts.
SHELL := /bin/bash

VERSION ?= 1.0.0
CODESIGN_IDENTITY ?=
NOTARY_PROFILE ?=
export VERSION CODESIGN_IDENTITY NOTARY_PROFILE

APP := build/ReadAlong.app
DMG := dist/ReadAlong-$(VERSION).dmg

.PHONY: all setup app dmg run dev test icon lock clean help

all: dmg

help:
	@printf '%s\n' \
	  'make setup   create .venv and install requirements' \
	  'make app     build build/ReadAlong.app' \
	  'make dmg     build dist/ReadAlong-$(VERSION).dmg' \
	  'make run     build the app and open it' \
	  'make dev     run the Python app from .venv' \
	  'make test    run the aligner checks' \
	  'make icon    regenerate macapp/AppIcon.icns' \
	  'make lock    refresh scripts/requirements.lock.txt' \
	  'make clean   remove build/ and dist/' \
	  '' \
	  'Variables: VERSION=$(VERSION) CODESIGN_IDENTITY NOTARY_PROFILE'

setup:
	python3.12 -m venv .venv
	.venv/bin/pip install -r requirements.txt

app:
	./scripts/build_app.sh

dmg:
	./scripts/build_dmg.sh

run: app
	open "$(APP)"

dev:
	.venv/bin/python readalong.py

test:
	.venv/bin/python test_align.py

icon:
	.venv/bin/python scripts/make_icon.py

lock:
	.venv/bin/python -m pip freeze > scripts/requirements.lock.txt

clean:
	rm -rf build dist
