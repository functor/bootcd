#
%define nodefamily %{pldistro}-%{distroname}-%{_arch}

%define name bootcd-%{nodefamily}
%define version 5.1
%define taglevel 3

# pldistro already in the rpm name
#%define release %{taglevel}%{?pldistro:.%{pldistro}}%{?date:.%{date}}
%define release %{taglevel}%{?date:.%{date}}

# structure - this results in 2 packages
# bootcd-initscripts - has the plc.d/ scripts
# bootcd-<nodefamily> - has the actual stuff for a given nodefamily

Vendor: PlanetLab
Packager: PlanetLab Central <support@planet-lab.org>
Distribution: PlanetLab %{plrelease}
URL: %{SCMURL}

Summary: Boot CD material for %{nodefamily}
Name: %{name}
Version: %{version}
Release: %{release}
License: BSD
Group: System Environment/Base
Source0: %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root
# other archs must be able to install this
BuildArch: noarch

Requires: dosfstools, mkisofs, gzip, mtools, syslinux
# yumdownloader is needed in bootcd-kernel
Requires: yum-utils
# mkdiskimage is used for USB-partitioned mode
# but it now comes in a separate rpm
%if "%{distro}" == "Fedora" && %{distrorelease} >= 14
Requires: syslinux-perl
%endif

Requires: pyplnet

# 5.0 now has 3-fold nodefamily
%define obsolete_nodefamily %{pldistro}-%{_arch}
Obsoletes: bootcd-%{obsolete_nodefamily}

AutoReqProv: no
%define debug_package %{nil}

%description
The Boot CD securely boots PlanetLab nodes into an immutable
environment. This package is designed to be installed on a MyPLC
installation and provide the basics for the PLC to able to compute
BootCDs for its attached nodes. 
See http://svn.planet-lab.org/wiki/NodeFamily


%package -n bootcd-initscripts
Summary: initscripts for the MyPLC installation
Group: System Environment/Base
%description -n bootcd-initscripts
This package contains the init scripts that get fired when the PLC is
restarted.

### avoid having yum complain about updates, as stuff is moving around
# plc.d/bootcd*
Conflicts: MyPLC <= 4.3

%prep
%setup -q

%build
[ -d bootcd ] || ln -s BootCD bootcd

pushd bootcd

# Build the reference image
./prep.sh %{pldistro} %{nodefamily}

popd

%install
rm -rf $RPM_BUILD_ROOT

pushd bootcd

# Install the reference image and build scripts
install -d -m 755 $RPM_BUILD_ROOT/%{_datadir}/%{name}
install -m 755 build.sh $RPM_BUILD_ROOT/%{_datadir}/%{name}/
install -m 755 kvariant.sh $RPM_BUILD_ROOT/%{_datadir}/%{name}/
tar cpf - \
    build/isofs/bootcd.img \
    build/isofs/kernel \
    build/passwd \
    build/version.txt \
    build/nodefamily \
    configurations | \
    tar -C $RPM_BUILD_ROOT/%{_datadir}/%{name}/ -xpf -

for script in bootcd bootcd-kernel; do 
    install -D -m 755 plc.d/$script $RPM_BUILD_ROOT/etc/plc.d/$script
done

popd
    
%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
%{_datadir}/%{name}

%files -n bootcd-initscripts
%defattr(-,root,root,-)
/etc/plc.d

%changelog
* Thu Feb 21 2013 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-5.1-3
- reviewed for systemd & f18

* Mon May 07 2012 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-5.1-2
- turn off selinux, turns out needed with some combinations like lxc/f14

* Wed Apr 11 2012 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-5.1-1
- compatible with pre- and post- f16
- add systemd friendlyness to bootcd
- also add biosdevname=0 tp kernel args so ethernet devices are still named in eth<x>

* Mon Nov 07 2011 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-5.0-11
- add requires: to syslinux-perl on fedora14

* Mon Mar 21 2011 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-5.0-10
- blacklisted mdules
- requires yum-utils for yumdownloader in bootcd-kernel

* Mon Feb 21 2011 S.Çağlar Onur <caglar@verivue.com> - bootcd-5.0-9
- Handle /dev/rtc name change for newer kernels

* Tue Jan 25 2011 S.Çağlar Onur <caglar@cs.princeton.edu> - bootcd-5.0-8
- Revert hacky solution for 2.6.32 based kernels as they are no longer required

* Sun Jan 23 2011 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-5.0-7
- changes for booting off fedora14
- displays some sanity checks in case bm can's get downloaded
- virtio devices in /dev/vd* also considered
- start service rsyslog if found
- hack for kernel-firmware with 2.6.32
- use $() instead of ``

* Wed Dec 01 2010 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-5.0-6
- use /usr/lib/syslinux/mkdiskimage or installed mkdiskimage

* Wed Sep 01 2010 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-5.0-5
- remove remainging reference to planet-lab.org

* Mon Jul 05 2010 Baris Metin <Talip-Baris.Metin@sophia.inria.fr> - BootCD-5.0-4
- module name changes

* Wed Jun 23 2010 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-5.0-3
- nicer initscript now uses 'action' from /etc/init.d/functions

* Tue Apr 20 2010 Talip Baris Metin <Talip-Baris.Metin@sophia.inria.fr> - BootCD-5.0-2
- obsolete old bootcd versions

* Fri Jan 29 2010 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-5.0-1
- First working version of 5.0:
- pld.c/, db-config.d/ and nodeconfig/ scripts should now sit in the module they belong to
- nodefamily is 3-fold with pldistro-fcdistro-arch
- new module bootcd-inistscripts

* Sat Jan 09 2010 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-17
- support for fedora 12

* Sun Dec 27 2009 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-16
- fix build on fedora12

* Fri Sep 04 2009 Stephen Soltesz <soltesz@cs.princeton.edu> - BootCD-4.2-15
- record the ntp time to the hwclock.  this is a bootcd operation, but it is
- repeated in the bootmanager to handle all CDs without this operation

* Mon Jun 29 2009 Marc Fiuczynski <mef@cs.princeton.edu> - BootCD-4.2-14
- Daniel''s update to generalize the kvariant support.

* Wed Apr 08 2009 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-13
- robust to node config file specified with a relative path

* Tue Apr 07 2009 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-12
- fix specfile - 4.2-11 would not build

* Tue Apr 07 2009 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-11
- Added support for handling kernel variants
- http://svn.planet-lab.org/wiki/BootcdVariant

* Tue Mar 24 2009 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-10
- mkfs.vfat output removed prior to invokation - fix needed on fedora 10

* Tue Dec 30 2008 Marc Fiuczynski <mef@cs.princeton.edu> - BootCD-4.2-9
- Added kupdate.sh

* Sat Dec 13 2008 Daniel Hokka Zakrisson <daniel@hozac.com> - BootCD-4.2-8
- Use pyplnet.
- Add a site_admin account to the BootCD.
- Add some explanations for common errors.

* Tue Dec 02 2008 Daniel Hokka Zakrisson <daniel@hozac.com> - BootCD-4.2-7
- Allow multiple -k options to the build.sh script.
- Probe devices in PCI bus order.

* Fri Nov 14 2008 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-6
- add support for fedora9 images - compliant with upstart
- formerly monolythic dir 'conf_files/' split into 'etc/' and 'initscripts/'

* Tue Sep 23 2008 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-5
- cosmetic - pl_boot to display timestamps

* Mon Aug 04 2008 Stephen Soltesz <soltesz@cs.princeton.edu> - BootCD-4.2-4
- adds -k as an argument to build.sh to pass additional kernel parameters to the
- bootcd and kexec kernel.

* Mon May 05 2008 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-3
- rpm release tag does not need pldistro as it is already part of the rpm name

* Thu Apr 24 2008 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-2
- change location of nodefamily in /etc/planetlab/

* Wed Apr 23 2008 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-4.2-1
- new name for the rpm, to allow simultaneous rpm-installs for several nodefamily (pldistro+arch)
- now installs in /usr/share/bootcd-<nodefamily> with a legacy symlink (requires MyPLC-4.2-7) 
- nodefamily exported under bootcd.img in /etc/nodefamily (for bm) and under build/nodefamily (for build.sh)

* Wed Mar 26 2008 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - BootCD-3.4-4 BootCD-3.4-5
- kargs.txt for serial boot fixed: now properly exposed to bootmanager through the overlay image
- build.sh cleaned up in the process
- actual location of selected node config file displayed
- import pypci rather than pypciscan

* Thu Feb 14 2008 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-3.4-3 bootcd-3.4-4
- build.sh support for -s <console_spec> (recommended vs using type)
- build.sh cleanup - usage clearer wrt types - removed old code
- fixed modprobe with args in pl_hwinit

* Thu Jan 31 2008 Thierry Parmentelat <thierry.parmentelat@sophia.inria.fr> - bootcd-3.4-2 bootcd-3.4-3
- load floppy with modprobe flags
- support for creating a usb partition
- removed obsolete files newbuild.sh, bootcustom.sh and cdcustom.sh

* Mon Jan 29 2006 Marc E. Fiuczynski <mef@cs.princeton.edu> - 
- added biginitrd usb image

* Fri Sep  2 2005 Mark Huang <mlhuang@cotton.CS.Princeton.EDU> - 
- Initial build.

%define module_current_branch 4.2
