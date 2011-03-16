#!/bin/bash

COMMAND=$(basename $0)

function usage() {
  echo "$COMMAND variant kernel-rpm"
  echo "    Allows to create a variant of the bootcd image with a different kernel"
  echo "    variant will be created under /usr/share/bootcd/<variant>"
  echo "    with the same structure as the default /usr/share/bootcd/build"
  echo "    the kernel rpm will also be stored in the variant dir for future reference"
  echo "e.g. $COMMAND centos5 http://mirror.onelab.eu/centos/5.2/updates/i386/RPMS/kernel-2.6.18-92.1.1.el5.i686.rpm"
  exit 1
}

function bail () {
    rm -rf $tmpdir $files
    exit -1
}

## locate rpm and store it in variant
function getrpm () {
    kernelrpm_url=$1; shift
    kernelrpm_local=$1; shift
    nocolon=$(echo $kernelrpm_url | sed -e s,:,,)
    if [ "$kernelrpm_url" == "$nocolon" ] ; then
	echo "Copying $kernelrpm_url in $variant_path"
	cat $kernelrpm_url > $kernelrpm_local
    else
	echo "Fetching $kernelrpm_url in $variant_path"
	curl -o $kernelrpm_local $kernelrpm_url
    fi 
}

## sanity check
function checkrpm () {
    filename=$1
    if [ -f "$filename" ] ; then
	if [ $(rpm -qip $filename | wc -l) -eq 1 ] ; then
	    echo "$filename not a valid rpm file"
	    usage
	fi
    fi
}

######################################## let's go
set -e

[[ -z "$@" ]] && usage
variant=$1; shift
[[ -z "$@" ]] && usage
kernelrpm_url=$1; shift
[[ -n "$@" ]] && usage

basedir=$(cd -P $(dirname $0); pwd)
standard_path="$basedir/build"
if [ ! -d $standard_path ] ; then
    echo "Cound not find standard image $standard_path - exiting"
    exit 1
fi

variant_path="$basedir/$variant"
if [ -e "$variant_path" ] ; then
    echo "Found $variant_path - please remove first - exiting"
    exit 1
fi

here=$(pwd)
mkdir $variant_path
echo "Creating $variant_path from $standard_path"
tar -C $standard_path -cf - . | tar -C $variant_path -xf - 

kernelrpm=$variant_path/$(basename $kernelrpm_url)
getrpm $kernelrpm_url $kernelrpm
checkrpm $kernelrpm

isofsdir=$variant_path/isofs

tmpdir=
files=

tmpdir=$(mktemp -d /var/tmp/bootcd.XXXXXX)
trap "bail" ERR INT
echo "Updating bootcd image with $kernelrpm"
mkdir $tmpdir/bootcd
pushd $tmpdir/bootcd
echo "Unwrapping bootcd.img in $(pwd)"
gzip -d -c $isofsdir/bootcd.img | cpio -diu
echo "Cleaning up older kernel"
rm -rf boot/*
rm -rf lib/modules
echo "Replacing with new kernel"
rpm2cpio  $kernelrpm | cpio -diu
echo "Running depmod"
version=$(cd ./boot && ls vmlinuz* | sed 's,vmlinuz-,,')
depmod -b . $version
echo "Exposing kernel"
cp boot/vmlinuz* ${tmpdir}/kernel
echo "Wrapping new bootcd.img"
find . | cpio --quiet -c -o | gzip -9 > ${tmpdir}/bootcd.img
popd

#
echo -n "Preserving in $isofsdir .."
mv ${isofsdir}/kernel ${tmpdir}/kernel.orig
echo -n " kernel"
mv ${isofsdir}/bootcd.img ${tmpdir}/bootcd.img.orig
echo -n " bootcd.img"
echo ""

#
echo -n "Populating $isofsdir .."
mv ${tmpdir}/kernel ${isofsdir}/kernel
echo -n " kernel"
mv ${tmpdir}/bootcd.img ${isofsdir}/bootcd.img
echo -n " bootcd.img"
echo ""

rm -rf $tmpdir $kernelrpm

echo "new variant $variant ready"
trap - ERR
exit 0
