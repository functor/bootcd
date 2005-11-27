#!/bin/bash

set -e

# where the boot cd build config files are stored (and certificats/keys)
CONFIGURATIONS_DIR=configurations/

# where built files are stored
BUILD_DIR=build/

BOOTCD_VERSION="3.2"
FULL_VERSION_STRING="PlanetLab BootCD"
OUTPUT_IMAGE_NAME='PlanetLab-BootCD'
    
SYSLINUX_SRC=sources/syslinux-2.11.tar.bz2

BOOTCD_YUM_GROUP=BootCD

CDRECORD_FLAGS="-v -dao"

CONF_FILES_DIR=conf_files/

# size of the ram disk in MB
RAMDISK_SIZE=64

# the bytes per inode ratio (the -i value in mkfs.ext2) for the ramdisk
INITRD_BYTES_PER_INODE=1024


# make sure the boot manager source is checked out in the same directory
# as the bootcd_v3 repository
for BOOTMANAGER_DIR in ../bootmanager-* ../bootmanager ; do
    [ -d $BOOTMANAGER_DIR ] && break
done

if [ ! -d $BOOTMANAGER_DIR ]; then
    echo "the bootmanager repository needs to be checked out at the same"
    echo "level as this directory, for the merge_hw_tables.py script"
    exit
fi


function usage()
{
    echo "Usage: build.sh <action> [<configuration>]"
    echo "Action: build burn clean"
    echo
    echo "If configuration is missing, 'default' is loaded"
    exit
}


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
    # trick rpm and yum
    export HOME=$PWD
    cp -f $CONF_FILES_DIR/macros $PWD/.rpmmacros

    echo "initialize rpm db"
    mkdir -p $CD_ROOT/var/lib/rpm
    rpm --root $CD_ROOT --initdb
    
    # XXX Should download yum.conf from the boot server?
    echo "generate yum.conf"
cat >yum.conf <<EOF
[main]
cachedir=/var/cache/yum
debuglevel=2
logfile=/var/log/yum.log
pkgpolicy=newest
### for yum-2.4 in fc4 (this will be ignored by yum-2.0)
### everything in here, do not scan /etc/yum.repos.d/
reposdir=/dev/null

[FedoraCore2Base]
name=Fedora Core 2 Base -- PlanetLab Central
baseurl=http://$PRIMARY_SERVER/install-rpms/stock-fc2/

[FedoraCore2Updates]
name=Fedora Core 2 Updates -- PlanetLab Central
baseurl=http://$PRIMARY_SERVER/install-rpms/updates-fc2/

[PlanetLab]
name=PlanetLab RPMS -- PlanetLab Central
baseurl=http://$PRIMARY_SERVER/install-rpms/planetlab/
EOF
    # XXX Temporary hack until the 3.2 rollout is complete and the
    # /planetlab/yumgroups.xml file contains the BootCD group.
    yumgroups="http://$PRIMARY_SERVER/install-rpms/planetlab-rollout/yumgroups.xml"

   # Solve the bootstrap problem by including any just built packages in
   # the yum configuration. This cooperates with the PlanetLab build
   # system.
   if [ -n "$RPM_BUILD_DIR" ] ; then
       cat >>yum.conf <<EOF
[Bootstrap]
name=Bootstrap RPMS -- $(dirname $RPM_BUILD_DIR)/RPMS/
baseurl=file://$(dirname $RPM_BUILD_DIR)/RPMS/
EOF
       yumgroups="file://$(dirname $RPM_BUILD_DIR)/RPMS/yumgroups.xml"
   fi

    echo "install boot cd base rpms"
    yum -c yum.conf --installroot=$CD_ROOT -y groupinstall $BOOTCD_YUM_GROUP

    # Retrieve all of the packagereq declarations in the BootCD group of the yumgroups.xml file
    echo "checking to make sure rpms were installed"
    packages=$(curl $yumgroups | sed -n -e '/<name>BootCD<\/name>/,/<name>/{ s/.*<packagereq.*>\(.*\)<\/packagereq>/\1/p }')
    set +e
    for package in $packages; do
	echo "checking for package $package"
	/usr/sbin/chroot $CD_ROOT /bin/rpm -qi $package > /dev/null
	if [[ "$?" -ne 0 ]]; then
	    echo "package $package was not installed in the cd root."
	    echo "make sure it exists in the yum repository."
	    exit 1
	fi
    done
    set -e
    
    echo "removing unneccessary build files"
    (cd $CD_ROOT/lib/modules && \
	find ./ -type d -name build -maxdepth 2 -exec rm -rf {} \;)

    echo "setting up non-ssh authentication"
    mkdir -p $CD_ROOT/etc/samba
    /usr/sbin/chroot $CD_ROOT /usr/sbin/authconfig --nostart --kickstart \
	--enablemd5 --enableshadow

    echo "setting root password"
    sed -i "s#root::#root:$ROOT_PASSWORD:#g" $CD_ROOT/etc/shadow

    echo "relocate some large directories out of the root system"
    # get /var/lib/rpm out, its 12mb. create in its place a 
    # symbolic link to /usr/relocated/var/lib/rpm
    mkdir -p $CD_ROOT/usr/relocated/var/lib/
    mv $CD_ROOT/var/lib/rpm $CD_ROOT/usr/relocated/var/lib/
    (cd $CD_ROOT/var/lib && ln -s ../../usr/relocated/var/lib/rpm rpm)

    # get /var/cache/yum out, its 100Mb. create in its place a 
    # symbolic link to /usr/relocated/var/cache/yum
    mkdir -p $CD_ROOT/usr/relocated/var/cache/
    mv $CD_ROOT/var/cache/yum $CD_ROOT/usr/relocated/var/cache/
    (cd $CD_ROOT/var/cache && ln -s ../../usr/relocated/var/cache/yum yum)

    # get /lib/tls out
    mkdir -p $CD_ROOT/usr/relocated/lib
    mv $CD_ROOT/lib/tls $CD_ROOT/usr/relocated/lib/
    (cd $CD_ROOT/lib && ln -s ../usr/relocated/lib/tls tls)

    echo "extracting syslinux, copying isolinux files to cd"
    mkdir -p $CD_ROOT/usr/isolinux/
    mkdir -p $BUILD_DIR/syslinux
    tar -C $BUILD_DIR/syslinux -xjvf $SYSLINUX_SRC
    find $BUILD_DIR/syslinux -name isolinux.bin \
	-exec cp -f {} $CD_ROOT/usr/isolinux/ \;

    echo "moving kernel to isolinux directory"
    KERNEL=$CD_ROOT/boot/vmlinuz-*
    mv -f $KERNEL $CD_ROOT/usr/isolinux/kernel

    echo "moving /usr/bin/find and /usr/bin/dirname to /bin"
    mv $CD_ROOT/usr/bin/find $CD_ROOT/bin/
    mv $CD_ROOT/usr/bin/dirname $CD_ROOT/bin/

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

    echo "copying sysctl.conf (fix tcp window scaling and broken routers)"
    cp -f $CONF_FILES_DIR/sysctl.conf $CD_ROOT/etc/

    echo "setup default network conf file"
    mkdir -p $CD_ROOT/usr/boot
    cp -f $CONF_FILES_DIR/default-net.cnf $CD_ROOT/usr/boot/

    echo "setup boot server configuration"
    cp -f $CURRENT_CONFIG_DIR/$PRIMARY_SERVER_CERT $CD_ROOT/usr/boot/cacert.pem
    cp -f $CURRENT_CONFIG_DIR/$PRIMARY_SERVER_GPG $CD_ROOT/usr/boot/pubring.gpg
    echo "$PRIMARY_SERVER" > $CD_ROOT/usr/boot/boot_server
    echo "$PRIMARY_SERVER_PORT" > $CD_ROOT/usr/boot/boot_server_port
    echo "$PRIMARY_SERVER_PATH" > $CD_ROOT/usr/boot/boot_server_path

    echo "setup backup boot server configuration"
    mkdir -p $CD_ROOT/usr/boot/backup
    cp -f $CURRENT_CONFIG_DIR/$BACKUP_SERVER_CERT \
	$CD_ROOT/usr/boot/backup/cacert.pem
    cp -f $CURRENT_CONFIG_DIR/$BACKUP_SERVER_GPG \
	$CD_ROOT/usr/boot/backup/pubring.gpg
    echo "$BACKUP_SERVER" > $CD_ROOT/usr/boot/backup/boot_server
    echo "$BACKUP_SERVER_PORT" > $CD_ROOT/usr/boot/backup/boot_server_port
    echo "$BACKUP_SERVER_PATH" > $CD_ROOT/usr/boot/backup/boot_server_path

    echo "copying old boot cd directory bootme (TEMPORARY)"
    cp -r bootme_old $CD_ROOT/usr/bootme
    echo "$FULL_VERSION_STRING" > $CD_ROOT/usr/bootme/ID
    echo "$PRIMARY_SERVER" > $CD_ROOT/usr/bootme/BOOTSERVER
    echo "$PRIMARY_SERVER" > $CD_ROOT/usr/bootme/BOOTSERVER_IP
    echo "$PRIMARY_SERVER_PORT" > $CD_ROOT/usr/bootme/BOOTPORT

    echo "copying cacert to old boot cd directory bootme (TEMPORARY)"
    mkdir -p $CD_ROOT/usr/bootme/cacert/$PRIMARY_SERVER/
    cp -f $CURRENT_CONFIG_DIR/$PRIMARY_SERVER_CERT \
	$CD_ROOT/usr/bootme/cacert/$PRIMARY_SERVER/cacert.pem

    echo "forcing lvm to make lvm1 partitions (TEMPORARY)"
    cp -f $CONF_FILES_DIR/lvm.conf $CD_ROOT/etc/lvm/

    echo "copying isolinux configuration files"
    cp -f $CONF_FILES_DIR/isolinux.cfg $CD_ROOT/usr/isolinux/
    echo "$FULL_VERSION_STRING" > $CD_ROOT/usr/isolinux/message.txt

    echo "writing /etc/issue"
    echo "$FULL_VERSION_STRING" > $CD_ROOT/etc/issue
    echo "Kernel \r on an \m" >> $CD_ROOT/etc/issue
    echo "" >> $CD_ROOT/etc/issue
    echo "" >> $CD_ROOT/etc/issue

    if [[ ! -z "$NODE_CONFIGURATION_FILE" ]]; then
	echo "Copying node configuration file to cd"
	cp -f $CURRENT_CONFIG_DIR/$NODE_CONFIGURATION_FILE \
	    $CD_ROOT/usr/boot/plnode.txt
    fi

    echo "making the isolinux initrd kernel command line match rd size"
    let INITRD_SIZE_KB=$(($RAMDISK_SIZE * 1024))
    sed -i "s#ramdisk_size=0#ramdisk_size=$INITRD_SIZE_KB#g" \
	$CD_ROOT/usr/isolinux/isolinux.cfg

    echo "building pcitable for hardware detection"
    pci_map_file=`find $CD_ROOT/lib/modules/ -name modules.pcimap | head -1`
    module_dep_file=`find $CD_ROOT/lib/modules/ -name modules.dep | head -1`
    pci_table=$CD_ROOT/usr/share/hwdata/pcitable
    $BOOTMANAGER_DIR/source/merge_hw_tables.py \
	$module_dep_file $pci_map_file $pci_table $CD_ROOT/etc/pl_pcitable

    dd if=/dev/zero of=$INITRD bs=1M count=$RAMDISK_SIZE
    /sbin/mkfs.ext2 -F -m 0 -i $INITRD_BYTES_PER_INODE $INITRD
    mkdir -p $INITRD_MOUNT
    mount -o loop,rw $INITRD $INITRD_MOUNT

    echo "copy all files except usr to ramdisk"
    pushd .
    cd $CD_ROOT
    find . -path ./usr -prune -o -print | cpio -p -d -u $INITRD_MOUNT
    popd

    umount $INITRD_MOUNT
    rmdir $INITRD_MOUNT
    
    echo "compressing ramdisk"
    gzip $INITRD
}

function build()
{
    # build base image via yum
    build_cdroot

    # always build/rebuild initrd
    build_initrd

    # build iso image
    rm -f $ISO
    mkisofs -o $ISO -R -allow-leading-dots -J -r -b isolinux/isolinux.bin \
	-c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
	$CD_ROOT/usr

    # build usb image and make it bootable with syslinux (instead of isolinux)
    USB_IMAGE=${ISO%*.iso}.usb
    # leave 1 MB of free space on the filesystem
    USB_KB=$(du -kc $ISO $CD_ROOT/usr/isolinux | awk '$2 == "total" { print $1 + 1024 }')
    /sbin/mkfs.vfat -C $USB_IMAGE $USB_KB

    mkdir -p $INITRD_MOUNT
    mount -o loop,rw $USB_IMAGE $INITRD_MOUNT

    # populate the root of the image with the iso, pl_version, and the syslinux files
    cp -a $ISO $INITRD_MOUNT
    cp -a $CD_ROOT/usr/isolinux/{initrd.gz,kernel,message.txt,pl_version} $INITRD_MOUNT
    cp -a $CD_ROOT/usr/isolinux/isolinux.cfg $INITRD_MOUNT/syslinux.cfg

    umount $INITRD_MOUNT
    rmdir $INITRD_MOUNT

    # make it bootable
    syslinux $USB_IMAGE
}

function burn()
{
    cdrecord $CDRECORD_FLAGS -data $ISO
}

function clean()
{
    rm -rf $CD_ROOT
    rm -rf $BUILD_DIR/syslinux
    rm -rf $BUILD_DIR/$INITRD_MOUNT
    rm -rf $BUILD_DIR
    rm -f $ISO
    rmdir --ignore-fail-on-non-empty build
}

if [[ "$1" == "clean" || "$1" == "burn" || "$1" == "build" ]]; then
    action=$1
    configuration=$2

    if [[ -z "$configuration" ]]; then
	configuration=default
    fi

    echo "Loading configuration $configuration"
    CURRENT_CONFIG_DIR=$CONFIGURATIONS_DIR/$configuration
    . $CURRENT_CONFIG_DIR/configuration

    # setup vars for this configuration

    # version string for this build
    if [[ ! -z "$EXTRA_VERSION" ]]; then
	FULL_VERSION_STRING="$FULL_VERSION_STRING $EXTRA_VERSION"
    fi
    FULL_VERSION_STRING="$FULL_VERSION_STRING $BOOTCD_VERSION"

    # destination image
    if [[ ! -z "$EXTRA_VERSION" ]]; then
	OUTPUT_IMAGE_NAME="$OUTPUT_IMAGE_NAME-$EXTRA_VERSION"
    fi
    OUTPUT_IMAGE_NAME="$OUTPUT_IMAGE_NAME-$BOOTCD_VERSION"

    # setup build directories
    BUILD_DIR=build/$configuration
    mkdir -p $BUILD_DIR
    ISO=$BUILD_DIR/`echo $OUTPUT_IMAGE_NAME | sed -e "s/%version/$BOOTCD_VERSION/"`.iso

    CD_ROOT=`pwd`/$BUILD_DIR/cdroot
    mkdir -p $CD_ROOT

    # location of the uncompressed ramdisk image
    INITRD=$CD_ROOT/usr/isolinux/initrd

    # temporary mount point for rd
    INITRD_MOUNT=`pwd`/$BUILD_DIR/rd


    case $action in 
	build )
	    echo "Proceeding with building $DESCRIPTION"
	    build;;

	clean )
	    echo "Removing built files for $DESCRIPTION"
	    clean;;

	burn )
	    echo "Burning $DESCRIPTION"
	    burn;;
    esac    
else
    usage
fi

