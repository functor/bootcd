ETAGS=etags

tags:
	find . -type f -a '!' '(' -name '*.x86' -o -name '*.x86_64' ')' | egrep -v '/\.(svn|git)/' | xargs $(ETAGS)

.PHONY: tags

#####
# make sync is a little more convoluted than the other variants
# so we call it make bootcdsync for that reason
#
# it expects the following env variables
#
# export BUILD=2015.03.05--f21
# export PLCHOSTLXC=deathvegas.pl.sophia.inria.fr
# export GUESTNAME=2015.03.05--f21-1-vplc12
# export GUESTHOSTNAME=vplc12.pl.sophia.inria.fr
# export KVMHOST=boxtops.pl.sophia.inria.fr
# export NODE=vnode03.pl.sophia.inria.fr
#
# and it also expects there is a reference iso file

KVMDIR=/vservers/$(BUILD)/qemu-$(NODE)
KVMSSH=$(KVMHOST):$(KVMDIR)

# initialize the workdir on the KVM side
# mount iso file, and unwrap .img files into bootcd/ and overlay/
sync-unwrap:
	ssh root@$(KVMHOST) "(cd $(KVMDIR); [ -f $(NODE).iso.ref ] && exit 0; \
			      cp $(NODE).iso $(NODE).iso.ref; \
			      mkdir iso.ref; mount -o ro,loop $(NODE).iso.ref iso.ref; \
			      rsync -ad iso.ref/ iso/; \
			      mkdir bootcd.ref; ( cd bootcd.ref; gzip -dc ../iso/bootcd.img | cpio -diu); \
			      mkdir overlay.ref; ( cd overlay.ref; gzip -dc ../iso/overlay.img | cpio -diu); \
			      rsync -a bootcd.ref/ bootcd/ ; rsync -a overlay.ref/ overlay/; \
			     )"

sync-clean:
	ssh root@$(KVMHOST) "(cd $(KVMDIR); [ -f $(NODE).iso.ref ] || exit 0; \
			      umount iso.ref; \
			      rm -rf iso.ref iso bootcd overlay bootcd.ref overlay.ref; \
			      mv -f $(NODE).iso.ref $(NODE).iso; \
			     )"

# once sync-mount is OK you can start tweaking the contents of bootcd/ and overlay/ manually
#
# -- or -- use this target to push the files in initscripts/ and systemd/ into
# that newly created bootcd/ before running sync-rewrap
RSYNC = rsync -av --exclude .du

sync-push:
	$(RSYNC) initscripts/ root@$(KVMHOST):$(KVMDIR)/bootcd/etc/init.d/
	$(RSYNC) systemd/ root@$(KVMHOST):$(KVMDIR)/bootcd/etc/systemd/system/

# and then use this to rebuild a new .iso

# same as in build.sh
MKISOFS_OPTS="-R -J -r -f -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table"

sync-rewrap:
	ssh root@$(KVMHOST) "(cd $(KVMDIR); \
			     echo "Rewrapping overlay.img"; \
			     (cd overlay && find . | cpio --quiet -c -o) | gzip -1 > iso/overlay.img; \
			     echo "Rewrapping bootcd.img"; \
			     (cd bootcd && find . | cpio --quiet -c -o) | gzip -1 > iso/bootcd.img; \
			     mkisofs -o $(NODE).iso $(MKISOFS_OPTS) iso/; \
			    )"

# install just build.sh in the myplc - assuming it has no bonding links..
sync-build:
	$(RSYNC) build.sh root@$(PLCHOSTLXC):/vservers/$(GUESTNAME)/usr/share/bootcd\*/
