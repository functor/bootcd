#!/bin/bash

set -e

BOOTCD_VERSION="3.0-beta0.1"
FULL_VERSION_STRING="PlanetLab BootCD $BOOTCD_VERSION"

# which boot server to contact
BOOTSERVER='boot.planet-lab.org'

# and on which port (protocol will be https)
BOOTSERVER_PORT='443'

# finally, what path to request from the server
BOOTSERVER_PATH='boot/'

SYSLINUX_SRC=sources/syslinux-2.11.tar.bz2

ISO=cd.iso

CD_ROOT=`pwd`/cdroot
ROOT_PASSWD='$1$IdEn2srw$/TfrjZSPUC1xP244YCuIi0'

BOOTCD_YUM_GROUP=BootCD

CDRECORD_FLAGS="-v -dao -blank=fast"

CONF_FILES_DIR=conf_files/

# location of the uncompressed ramdisk image
INITRD=$CD_ROOT/usr/isolinux/initrd

# temporary mount point for rd
INITRD_MOUNT=`pwd`/rd

# size of the ram disk in MB
RAMDISK_SIZE=48

# the bytes per inode ratio (the -i value in mkfs.ext2) for the ramdisk
INITRD_BYTES_PER_INODE=1024


function build_cdroot()
{
    if [ -f $CD_ROOT/.built ]; then
	echo "cd root already built, skipping"
	return
    fi

    clean
    
    mkdir -p $CD_ROOT/dev/pts
    mkdir -p $CD_ROOT/proc
    mkdir -p $CD_ROOT/etc

    echo "copy fstab and mtab"
    cp -f $CONF_FILES_DIR/fstab $CD_ROOT/etc/
    cp -f $CONF_FILES_DIR/mtab $CD_ROOT/etc/

    echo "setup rpm to install only en_US locale and no docs"
    mkdir -p $CD_ROOT/etc/rpm
    cp -f $CONF_FILES_DIR/macros $CD_ROOT/etc/rpm

    echo "initialize rpm db"
    mkdir -p $CD_ROOT/var/lib/rpm
    rpm --root $CD_ROOT --initdb

    echo "install boot cd base rpms"
    yum -c yum.conf --installroot=$CD_ROOT -y groupinstall $BOOTCD_YUM_GROUP

    echo "removing unneccessary build files"
    (cd $CD_ROOT/lib/modules && \
	find ./ -type d -name build -maxdepth 2 -exec rm -rf {} \;)

    echo "setting up non-ssh authentication"
    mkdir -p $CD_ROOT/etc/samba
    chroot $CD_ROOT /usr/sbin/authconfig --nostart --kickstart \
	--enablemd5 --enableshadow

    echo "setting root password"
    sed -i "s#root::#root:$ROOT_PASSWD:#g" $CD_ROOT/etc/shadow

    echo "relocate some large directories out of the root system"
    # get /var/lib/rpm out, its 12mb. create in its place a 
    # symbolic link to /usr/relocated/var/lib/rpm
    mkdir -p $CD_ROOT/usr/relocated/var/lib/
    mv $CD_ROOT/var/lib/rpm $CD_ROOT/usr/relocated/var/lib/
    (cd $CD_ROOT/var/lib && ln -s ../../usr/relocated/var/lib/rpm rpm)

    # get /lib/tls out
    mkdir -p $CD_ROOT/usr/relocated/lib
    mv $CD_ROOT/lib/tls $CD_ROOT/usr/relocated/lib/
    (cd $CD_ROOT/lib && ln -s ../usr/relocated/lib/tls tls)

    echo "extracting syslinux, copying isolinux files to cd"
    mkdir -p syslinux
    mkdir -p $CD_ROOT/usr/isolinux/
    tar -C syslinux -xjvf $SYSLINUX_SRC
    find syslinux -name isolinux.bin -exec cp -f {} $CD_ROOT/usr/isolinux/ \;

    echo "moving kernel to isolinux directory"
    KERNEL=$CD_ROOT/boot/vmlinuz-*
    mv -f $KERNEL $CD_ROOT/usr/isolinux/kernel

    echo "creating version files"
    echo "$FULL_VERSION_STRING" > $CD_ROOT/usr/isolinux/pl_version
    echo "$FULL_VERSION_STRING" > $CD_ROOT/pl_version

    touch $CD_ROOT/.built
}

function build_initrd()
{
    echo "building initrd"
    rm -f $INITRD
    rm -f $INITRD.gz

    echo "copy fstab and mtab"
    cp -f $CONF_FILES_DIR/fstab $CD_ROOT/etc/
    cp -f $CONF_FILES_DIR/mtab $CD_ROOT/etc/

    echo "installing generic modprobe.conf"
    cp -f $CONF_FILES_DIR/modprobe.conf $CD_ROOT/etc/

    echo "installing our own inittab and init scripts"
    cp -f $CONF_FILES_DIR/inittab $CD_ROOT/etc
    init_scripts="pl_sysinit pl_hwinit pl_netinit pl_validateconf pl_boot"
    for script in $init_scripts; do
	cp -f $CONF_FILES_DIR/$script $CD_ROOT/etc/init.d/
	chmod +x $CD_ROOT/etc/init.d/$script
    done

    echo "setup basic networking files"
    cp -f $CONF_FILES_DIR/hosts $CD_ROOT/etc/

    echo "setup default network conf file"
    mkdir -p $CD_ROOT/usr/boot
    cp -f $CONF_FILES_DIR/default-net.cnf $CD_ROOT/usr/boot/

    echo "setup boot server configuration"
    cp -f $CONF_FILES_DIR/cacert.pem $CD_ROOT/usr/boot/
    cp -f $CONF_FILES_DIR/pubring.gpg $CD_ROOT/usr/boot/
    echo "$BOOTSERVER" > $CD_ROOT/usr/boot/boot_server
    echo "$BOOTSERVER_PORT" > $CD_ROOT/usr/boot/boot_server_port
    echo "$BOOTSERVER_PATH" > $CD_ROOT/usr/boot/boot_server_path

    echo "copying isolinux configuration files"
    cp -f $CONF_FILES_DIR/isolinux.cfg $CD_ROOT/usr/isolinux/
    echo "$FULL_VERSION_STRING" > $CD_ROOT/usr/isolinux/message.txt

    echo "writing /etc/issue"
    echo "$FULL_VERSION_STRING" > $CD_ROOT/etc/issue
    echo "Kernel \r on an \m" >> $CD_ROOT/etc/issue
    echo "" >> $CD_ROOT/etc/issue
    echo "" >> $CD_ROOT/etc/issue

    echo "making the isolinux initrd kernel command line match rd size"
    let INITRD_SIZE_KB=$(($RAMDISK_SIZE * 1024))
    sed -i "s#ramdisk_size=0#ramdisk_size=$INITRD_SIZE_KB#g" \
	$CD_ROOT/usr/isolinux/isolinux.cfg

    echo "building pcitable for hardware detection"
    pci_map_file=`find $CD_ROOT/lib/modules/ -name modules.pcimap | head -1`
    ./scripts/rewrite-pcitable.py $pci_map_file $CD_ROOT/etc/pl_pcitable

    dd if=/dev/zero of=$INITRD bs=1M count=$RAMDISK_SIZE
    mkfs.ext2 -F -m 0 -i $INITRD_BYTES_PER_INODE $INITRD
    mkdir -p $INITRD_MOUNT
    mount -o loop,rw $INITRD $INITRD_MOUNT

    echo "copy all files except usr to ramdisk"
    (cd $CD_ROOT && find . -path ./usr -prune -o -print | \
	cpio -p -d -u $INITRD_MOUNT)

    umount $INITRD_MOUNT
    rmdir $INITRD_MOUNT
    
    echo "compressing ramdisk"
    gzip $INITRD
}

function build_iso()
{
    echo "building iso"
    rm -f $ISO
    mkisofs -o $ISO -R -allow-leading-dots -J -r -b isolinux/isolinux.bin \
	-c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
	-V PlanetLab-3-0 $CD_ROOT/usr
}

function burn()
{
    cdrecord $CDRECORD_FLAGS -data $ISO
}

function clean()
{
    echo "removing built files"
    rm -rf cdroot
    rm -rf syslinux
    rm -rf $INITRD_MOUNT
    rm -f $ISO
}


if [ "$1" == "clean" ]; then
    clean
    exit
fi

if [ "$1" == "burn" ]; then
    burn
    exit
fi

if [ "$1" == "force" ]; then
    clean
fi

# build base image via yum
build_cdroot

# always build/rebuild initrd
build_initrd

build_iso
