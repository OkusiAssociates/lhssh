# Makefile - Install lhssh
# BCS1212 compliant

PREFIX  ?= /usr/local
BINDIR  ?= $(PREFIX)/bin
COMPDIR ?= /etc/bash_completion.d
CONFDIR ?= /etc/lhssh
DESTDIR ?=

SCRIPTS = lhssh lhssh-cmd

.PHONY: all install uninstall check test help

all: help

install:
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 lhssh $(DESTDIR)$(BINDIR)/lhssh
	install -m 755 lhssh-cmd $(DESTDIR)$(BINDIR)/lhssh-cmd
	@if [ -d $(DESTDIR)$(COMPDIR) ]; then \
	  install -m 644 lhssh.bash_completion $(DESTDIR)$(COMPDIR)/lhssh; \
	fi
	install -d $(DESTDIR)$(CONFDIR)
	@if [ ! -f $(DESTDIR)$(CONFDIR)/lhssh.conf ]; then \
	  install -m 644 lhssh.conf.default $(DESTDIR)$(CONFDIR)/lhssh.conf; \
	  echo 'Created $(CONFDIR)/lhssh.conf'; \
	else \
	  echo '$(CONFDIR)/lhssh.conf exists, not overwriting'; \
	fi
	@if [ -z "$(DESTDIR)" ]; then $(MAKE) --no-print-directory check; fi

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/lhssh
	rm -f $(DESTDIR)$(BINDIR)/lhssh-cmd
	rm -f $(DESTDIR)$(COMPDIR)/lhssh
	@echo 'Note: $(CONFDIR)/lhssh.conf preserved (remove manually if desired)'

check:
	@command -v lhssh >/dev/null 2>&1 \
	  && echo 'lhssh: OK' \
	  || echo 'lhssh: NOT FOUND (check PATH)'
	@command -v lhssh-cmd >/dev/null 2>&1 \
	  && echo 'lhssh-cmd: OK' \
	  || echo 'lhssh-cmd: NOT FOUND (check PATH)'

test:
	bats tests/

help:
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Targets:'
	@echo '  install     Install to $(PREFIX)'
	@echo '  uninstall   Remove installed files'
	@echo '  check       Verify installation'
	@echo '  test        Run test suite'
	@echo '  help        Show this message'
	@echo ''
	@echo 'Install from GitHub:'
	@echo '  git clone https://github.com/OkusiAssociates/lhssh.git'
	@echo '  cd lhssh && sudo make install'
