PACKAGE := plakar-pve-provider
VERSION ?= 0.0.0
DEB := $(PACKAGE)_$(VERSION)_all.deb
BUILD := build
PERL5 := $(BUILD)/usr/share/perl5

.PHONY: test deb clean

test:
	prove -I t/lib -I src t/

deb: clean
	install -D -m 0644 src/PVE/Storage/Custom/PlakarPlugin.pm $(PERL5)/PVE/Storage/Custom/PlakarPlugin.pm
	install -D -m 0644 src/PVE/BackupProvider/Plugin/Plakar.pm $(PERL5)/PVE/BackupProvider/Plugin/Plakar.pm
	install -D -m 0644 debian/tmpfiles.conf $(BUILD)/usr/lib/tmpfiles.d/$(PACKAGE).conf
	install -D -m 0644 LICENSE $(BUILD)/usr/share/doc/$(PACKAGE)/copyright
	install -D -m 0755 debian/postinst $(BUILD)/DEBIAN/postinst
	sed 's/@VERSION@/$(VERSION)/' debian/control > $(BUILD)/DEBIAN/control
	dpkg-deb --root-owner-group --build $(BUILD) $(DEB)

clean:
	rm -rf $(BUILD) *.deb
