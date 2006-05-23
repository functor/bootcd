#!/bin/bash

# purpose : create a node-specific CD ISO image

# NOTE (see also bootcd/build.sh)
# If you run your own myplc instance, and you dont need to
# customize the bootcd, you might wish to use bootcd/build.sh
# with the -f option
# However cdcustom.sh might turn out useful if
# (*) you only have an iso image and nothing else
# (*) or you want to generate several iso images in a single run
# (*) or you run myplc rpm, but need to customize the bootcd image,
#     because the myplc rpm does not come with the required sources

# given a (generic, node-independant) CD ISO image, and a (set of)
# node-specific config file(s), this command creates a new almost
# identical ISO image with the node config file embedded as
# /usr/boot/plnode.txt in the overlay.img image
# the output iso images are named after the nodes, and stored in .

######## Logic
# here is how we do this
# for efficiency, we do only once:
#   (*) mount the generic iso
#   (*) copy it into a temp dir
#   (*) unzip/unarchive overlay image into another temp dir
# then for each node, we
#   (*) insert plnode.txt at the right place
#   (*) rewrap a gzipped/cpio overlay.img, that we push onto the
#       copied iso tree
#   (*) rewrap this into an iso image
# and cleanup/umount everything 

######## Customizing the BootCD
# In addition we check (once) for
#  (*) a file called 'bootcd.img' in the current dir
#  (*) a directory named 'bootcd/' in the current dir
# if any of those is present, we use this - presumably custom - stuff to
# replace original bootcd.img from the CD
# more precisely:
#  (*) if the .img is present, it is taken as-is,
#  (*) if not but bootcd/ is present, bootcd.img is refreshed and used
# All this is done only once at startup because it typically
#  takes 40s to recompress bootcd.img
# TODO
#  allow local bootcd/ to hold only patched files
# and get the rest from the CD's bootcd.img

######## Implementation note
# in a former release it was possible to perform faster by
# loopback-mounting the generic iso image
# Unfortunately mkisofs cannot graft a file that already exists on the
# original tree (so overlay.img cannot be overridden)
# to make things worse we cannot loopback-mount the cpio-gzipped
# overlay image either, so all this stuff is way more complicated
# than it used to be.
# It's still pretty fast, unless recompressing a bootcd.img is required

set -e 
COMMAND=$(basename $0 .sh)

function usage () {

   echo "Usage: $0 generic-iso node-config [node-configs]"
   echo "Creates a node-specific ISO image"
   echo "with the node-specific config file embedded as /boot/plnode.txt"
   exit 1
}

### read config file in a subshell and echoes host_name
function host_name () {
  export CONFIG=$1; shift
  ( . "$CONFIG" ; echo $HOST_NAME )
}

### Globals
OVERLAY_IMAGE=overlay.img
PLNODE_PATH=/usr/boot
PLNODE=plnode.txt
# use local bootcd/ or bootcd.img if existing
BOOTCD_IMAGE=bootcd.img
BOOTCD_ROOT=bootcd
## arg-provided generic iso
ISO_GENERIC=
# node-dep conf file
NODE_CONFIG=
# resulting iso image and log
NODE_ISO=
NODE_LOG=
## mount points and temps
ISO_MOUNT=/tmp/$COMMAND-$$-mount
ISO_ROOT=/tmp/$COMMAND-$$-iso
OVERLAY_ROOT=/tmp/$COMMAND-$$-overlay
# node-dep cpio/gzip image
NODE_OVERLAY=

CPIO_OARGS="-oc --quiet"
CPIO_IARGS="-id --quiet"
CPIO_PARGS="-pdu"

# export VERBOSE=true for enabling this
function verbose () {
   if [ -n "$VERBOSE" ] ; then
     echo "$@"
   fi
 }

function message () { echo "$COMMAND : $@" ; }
function message-n () { echo -n "$COMMAND : $@" ; }
function message-done () { echo Done ; }
function error () { echo "$COMMAND : ERROR $@ - exiting" ; exit 1 ;}

# lazy startup
STARTED_UP=
function startup () {

   [[ -n "$DEBUG" ]] && set -x

   # lazy : run only once
   [[ -n "$STARTED_UP" ]] && return
   message "starting up"

   ### checking
   [ ! -f "$ISO_GENERIC" ] && error "Could not find template ISO image"
   [ -d "$ISO_MOUNT" ] && error "$ISO_MOUNT already exists" 
   [ -d "$ISO_ROOT" ] && error "$ISO_ROOT already exists" 
   [ -d "$OVERLAY_ROOT" ] && error "$OVERLAY_ROOT already exists"

   verbose "Creating temp dirs"
   mkdir -p $ISO_MOUNT $ISO_ROOT $OVERLAY_ROOT
   verbose "Mounting generic ISO $ISO_GENERIC under $ISO_MOUNT"
   mount -o ro,loop $ISO_GENERIC $ISO_MOUNT

   ### DONT!! use tar for duplication
   message "Duplicating ISO image in $ISO_ROOT"
   (cd $ISO_MOUNT ; find . | cpio $CPIO_PARGS  $ISO_ROOT )

   # use local bootcd.img or bootcd/ if existing
   message-n "Checking for custom $BOOTCD_ROOT in . "
   if [ -d $BOOTCD_ROOT -a -f $BOOTCD_IMAGE ] ; then
     message-n " using $BOOTCD_IMAGE as-is "
   elif [ -d $BOOTCD_ROOT -a ! -f $BOOTCD_IMAGE ] ; then
     message-n "yes, making img .. "
     (cd $BOOTCD_ROOT ; find . | cpio $CPIO_OARGS) | gzip -9 > $BOOTCD_IMAGE
   fi
   if [ -f $BOOTCD_IMAGE ] ; then
     message-n "pushing onto $ISO_ROOT.. "
     cp $BOOTCD_IMAGE $ISO_ROOT/$BOOTCD_IMAGE
   fi
   message-done
     
   message "Extracting generic overlay image in $OVERLAY_ROOT"
   gzip -d -c "$ISO_ROOT/$OVERLAY_IMAGE" | ( cd "$OVERLAY_ROOT" ; cpio $CPIO_IARGS )

   STARTED_UP=true

}   

function node_cleanup () {
   verbose "Cleaning node-dependent cpio image"
   rm -rf "$NODE_OVERLAY"
  
}

function cleanup () {

   echo "$COMMAND : cleaning up"
   [[ -n "$DEBUG" ]] && set -x

   verbose "Cleaning overlay image"
   rm -rf "$OVERLAY_ROOT"
   verbose "Cleaning ISO image"
   rm -rf "$ISO_ROOT"
   verbose "Cleaning node-dep overlay image"
   rm -f "$NODE_OVERLAY"
   verbose "Unmounting $ISO_MOUNT"
   umount "$ISO_MOUNT" 2> /dev/null
   rmdir "$ISO_MOUNT"
   exit
}

function abort () {
   echo "$COMMAND : Aborting"
   message "Cleaning $NODE_ISO"
   rm -f "$NODE_ISO"
   cleanup
}

function main () {

   trap abort int hup quit err
   set -e

   [[ -n "$DEBUG" ]] && set -x

   [[ -z "$@" ]] && usage
   ISO_GENERIC=$1; shift

   [[ -z "$@" ]] && usage

#  perform that later (lazily)
#  so that (1st) node-dep checking are done before we bother to unpack
#   startup

   for NODE_CONFIG in "$@" ; do

     NODENAME=$(host_name $NODE_CONFIG)
     if [ -z "$NODENAME" ] ; then
       message "HOST_NAME not found in $NODE_CONFIG - skipped"
       continue
     fi
   
     message "$COMMAND : dealing with node $NODENAME"

     NODE_ISO="$NODENAME.iso"
     NODE_LOG="$NODENAME.log"
     NODE_OVERLAY="$NODENAME.img"

     ### checking
     if [ -e  "$NODE_ISO" ] ; then
       message "$NODE_ISO exists, please remove first - skipped" ; continue
     fi
     if [ ! -f "$NODE_CONFIG" ] ; then
       message "Could not find node-specifig config - skipped" ; continue
     fi
     
     startup

     verbose "Pushing node config into overlay image"
     mkdir -p $OVERLAY_ROOT/$PLNODE_PATH
     cp "$NODE_CONFIG" $OVERLAY_ROOT/$PLNODE_PATH/$PLNODE

     echo "$COMMAND : Creating overlay image for $NODENAME"
     (cd "$OVERLAY_ROOT" ; find . | cpio $CPIO_OARGS) | gzip -9 > $NODE_OVERLAY

     message-n "Pushing custom overlay image "
     cp "$NODE_OVERLAY" "$ISO_ROOT/$OVERLAY_IMAGE"
     message-done

     message "Refreshing isolinux.cfg"
     # Calculate ramdisk size (total uncompressed size of both archives)
     ramdisk_size=$(gzip -l $ISO_ROOT/bootcd.img $ISO_ROOT/overlay.img | tail -1 | awk '{ print $2; }') # bytes
     # keep safe, provision for cpio's block size
     ramdisk_size=$(($ramdisk_size / 1024 + 1)) # kilobytes

     # Write isolinux configuration
     cat > $ISO_ROOT/isolinux.cfg <<EOF
DEFAULT kernel
APPEND ramdisk_size=$ramdisk_size initrd=bootcd.img,overlay.img root=/dev/ram0 rw
DISPLAY pl_version
PROMPT 0
TIMEOUT 40
EOF

     message-n "Writing custom image, log on $NODE_LOG .. "
     mkisofs -o "$NODE_ISO" -R -allow-leading-dots -J -r -b isolinux.bin \
     -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
     "$ISO_ROOT" > "$NODE_LOG" 2>&1
     message-done
   
     node_cleanup
     
     message "CD ISO image for $NODENAME in $NODE_ISO"
   done

   cleanup

}

####################
main "$@"
