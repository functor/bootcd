#
# $Id$
#
%define url $URL$

%define name bootcd
%define version 3.4
%define taglevel 5

%define release %{taglevel}%{?pldistro:.%{pldistro}}%{?date:.%{date}}

Vendor: PlanetLab
Packager: PlanetLab Central <support@planet-lab.org>
Distribution: PlanetLab %{plrelease}
URL: %(echo %{url} | cut -d ' ' -f 2)

Summary: Boot CD
Name: %{name}
Version: %{version}
Release: %{release}
License: BSD
Group: System Environment/Base
Source0: %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root

Requires: dosfstools, mkisofs, gzip, mtools, syslinux

AutoReqProv: no
%define debug_package %{nil}

%description
The Boot CD securely boots PlanetLab nodes into an immutable
environment.

%prep
%setup -q

%build
pushd BootCD

# Build the reference image
./prep.sh %{pldistro}

popd

%install
rm -rf $RPM_BUILD_ROOT

pushd  BootCD

# Install the reference image and build scripts
install -d -m 755 $RPM_BUILD_ROOT/%{_datadir}/%{name}
install -m 755 build.sh $RPM_BUILD_ROOT/%{_datadir}/%{name}/
tar cpf - \
    build/isofs/bootcd.img \
    build/isofs/kernel \
    build/passwd \
    build/version.txt \
	bootcustom.sh \
    configurations | \
    tar -C $RPM_BUILD_ROOT/%{_datadir}/%{name}/ -xpf -

popd
    
%clean
rm -rf $RPM_BUILD_ROOT

# If run under sudo
if [ -n "$SUDO_USER" ] ; then
    # Allow user to delete the build directory
    chown -h -R $SUDO_USER .
    # Some temporary cdroot files like /var/empty/sshd and
    # /usr/bin/sudo get created with non-readable permissions.
    find . -not -perm +0600 -exec chmod u+rw {} \;
    # Allow user to delete the built RPM(s)
    chown -h -R $SUDO_USER %{_rpmdir}/%{_arch}
fi

%files
%defattr(-,root,root,-)
%{_datadir}/%{name}

%changelog
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

