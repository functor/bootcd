#!/bin/bash

# purpose : create a node-specific CD ISO image

# given a CD ISO image, and a node-specific config file, this command
# creates a new almost identical ISO image with the config file
# embedded as boot/plnode.txt 

set -e 
COMMAND=$(basename $0)

function usage () {

   echo "Usage: $0 generic-iso node-config"
   echo "Creates a node-specific ISO image"
   echo "with the node-specific config file embedded as /boot/plnode.txt"
   exit 1
}

### read config file in a subshell and echoes host_name
function host_name () {
  export CONFIG=$1; shift
  ( . $CONFIG ; echo $HOST_NAME )
}

function cleanup () {
   echo "Unmounting"
   umount $ISOINROOT
   echo "Cleaning mount-point"
   rmdir $ISOINROOT
   if [ -f $NODECONFPLAIN ] ; then
     echo Cleaning $NODECONFPLAIN
     rm -f $NODECONFPLAIN
   fi
}

function abort () {
   echo "Cleaning $ISOOUT"
   rm -f $ISOOUT
   cleanup
}

function main () {

   [[ -n "$TRACE" ]] && set -x

   [[ -z "$@" ]] && usage
   ISOIN=$1; shift
   [[ -z "$@" ]] && usage
   NODECONF=$1; shift
   [[ -n "$@" ]] && usage

   NODENAME=$(host_name $NODECONF)
   if [ -z "$NODENAME" ] ; then
     echo "HOST_NAME not found in $NODECONF - exiting"
     exit 1
   fi
   
   ISODIR=$(dirname "$ISOIN")
   ISOOUT=$ISODIR/$NODENAME.iso
   ISOLOG=$ISODIR/$NODENAME.log


   ### temporary mount point
   ISOINROOT=$(basename $ISOIN .iso)

   ### checking
   if [ ! -f $ISOIN ] ; then
     echo "Could not find template ISO image - exiting" ; exit 1
   fi
   if [ ! -f $NODECONF ] ; then
     echo "Could not find node-specifig config - exiting" ; exit 1
   fi
   if [ -e "$ISOINROOT" ] ; then
     echo "Temporary mount point $ISOINROOT exists, please clean up first - exiting" ; exit 1
   fi
   if [ -e  "$ISOOUT" ] ; then
     echo "$ISOOUT exists, please remove first - exiting" ; exit 1
   fi

   ### in case the NODECONF is a symlink
   NODECONFPLAIN=/tmp/$$
   cp $NODECONF $NODECONFPLAIN

   ### summary
   echo -e "Generic ISO image:\r\t\t\t$ISOIN"
   echo -e "Node-specific config:\r\t\t\t$NODECONF"
   echo -e "Node-specific ISO:\r\t\t\t$ISOOUT"
   echo -e "Temporary mount-point:\r\t\t\t$ISOINROOT"

   echo -ne "OK ? "
   read answer

   echo -n "Creating mount-point "
   mkdir -p $ISOINROOT
   echo Done

   echo -n "Mounting generic image "
   mount -o ro,loop $ISOIN $ISOINROOT 
   echo Done

   ### mkisofs needs to have write access on the boot image passed with -b
   ### and we cannot use the same name as isolinux.bin either, so we change it to isolinux
   ### the good news is that this way we can check we start from a fresh image

   if [ -e $ISOINROOT/isolinux/isolinux ] ; then
     echo "$ISOIN already contains isolinux/isolinux"
     echo "It looks like this is not a first-hand image - exiting"
     cleanup
     exit 1
   fi

   echo -n "Copying isolinux.bin in /tmp/isolinux "
   cp $ISOINROOT/isolinux/isolinux.bin /tmp/isolinux
   echo Done

   echo -n "Writing custom image ... "
   trap abort int hup quit err
   mkisofs -o $ISOOUT -R -allow-leading-dots -J -r -b isolinux/isolinux \
   -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table \
   --graft-points $ISOINROOT isolinux/isolinux=/tmp/isolinux boot/plnode.txt=$NODECONFPLAIN > $ISOLOG 2>&1
   trap - int hup quit 
   echo Done
   
   cleanup

   echo "CD ISO image for $NODENAME in $ISOOUT"

}

####################
main "$@"
