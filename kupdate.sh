#!/bin/bash

kernelrpm=$1
isofsdir=$2

tmpdir=
files=

bail () 
{
    rm -rf $tmpdir $files
    exit -1
}

usage ()
{
    program=$(basename $0)
    echo "USAGE:"
    echo " $program kernel.rpm"
    echo "   where kernel.rpm is the corresponding rpm files,"
    echo "   which might live in ./RPMS/..."
    exit -1
}

checkrpm ()
{
    filename=$1
    if [ -f "$filename" ] ; then
	if [ $(rpm -qip $filename | wc -l) -eq 1 ] ; then
	    echo "$filename not a valid rpm file"
	    usage
	fi
    fi
}

[ -z "$kernelrpm" ] && usage
checkrpm $kernelrpm

tmpdir=$(mktemp -d /var/tmp/bootcd.XXXXXX)
trap "bail" ERR INT
echo "Updating bootcd image with $kernelrpm"
pushd $tmpdir
mkdir bootcd
pushd bootcd
gzip -d -c $isofsdir/bootcd.img | cpio -diu
rm -rf boot/*
rm -rf lib/modules
rpm2cpio  $kernelrpm | cpio -diu
version=$(cd ./boot && ls vmlinuz* | sed 's,vmlinuz-,,')
depmod -b . $version
cp boot/vmlinuz* ${tmpdir}/kernel
find . | cpio --quiet -c -o | gzip -9 > ${tmpdir}/bootcd.img
popd
popd

#
mv ${isofsdir}/kernel ${tmpdir}/kernel.orig
mv ${isofsdir}/bootcd.img ${tmpdir}/bootcd.img.orig

#
mv ${tmpdir}/kernel ${isofsdir}/kernel
mv ${tmpdir}/bootcd.img ${isofsdir}/bootcd.img
rm -rf $tmpdir

echo " ... done"
trap - ERR
exit 0
