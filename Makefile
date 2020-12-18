# SPDX-License-Identifier: 0BSD
# -----------------------------------------------------------------------------

V_MAJOR = 0
V_MINOR = 1
V_PATCH = 0
V_EXTRA =
VERSION = $(V_MAJOR).$(V_MINOR).$(V_PATCH)$(V_EXTRA)

PREFIX = /usr/local
ETCDIR = /etc
BINDIR = $(PREFIX)/bin
MANDIR = $(PREFIX)/share/man

all: b2stic

man: b2stic.1 b2stic.conf.5

clean:
	rm -f b2stic.1 b2stic.conf.5

distclean: clean
	rm -f b2stic

install:
	scripts/atomic-install -D -m 0755 b2stic $(DESTDIR)$(BINDIR)/b2stic
	scripts/atomic-install -D -m 0644 b2stic.1 $(DESTDIR)$(MANDIR)/man1/b2stic.1
	scripts/atomic-install -D -m 0644 b2stic.conf.5 $(DESTDIR)$(MANDIR)/man5/b2stic.conf.5

b2stic: b2stic.sh
	sed -E 's@__ETCDIR__@$(ETCDIR)@g' <$< >$@

b2stic.1: b2stic.1.adoc
	asciidoctor -a VERSION="$(VERSION)" -b manpage -o $@ $<

b2stic.conf.5: b2stic.conf.5.adoc
	asciidoctor -a ETCDIR="$(ETCDIR)" -a VERSION="$(VERSION)" -b manpage -o $@ $<

.PHONY: clean distclean install man
