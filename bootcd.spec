%define name bootcd
%define version 3.3
%define release 2%{?pldistro:.%{pldistro}}%{?date:.%{date}}

Vendor: PlanetLab
Packager: PlanetLab Central <support@planet-lab.org>
Distribution: PlanetLab 3.3
URL: http://cvs.planet-lab.org/cvs/bootcd_v3

Summary: Boot CD
Name: bootcd
Version: %{version}
Release: %{release}
License: BSD
Group: System Environment/Base
Source0: %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root

Requires: dosfstools, mkisofs, gzip

AutoReqProv: no
%define debug_package %{nil}

%description
The Boot CD securely boots PlanetLab nodes into an immutable
environment.

%package planetlab
Summary: PlanetLab Boot CD
Group: System Environment/Base

%description planetlab
The default PlanetLab Boot CD, customized to boot from PlanetLab
Central servers.

%prep
%setup -q

%build
pushd bootcd_v3

# Build the reference image
./prep.sh

# Build the default configuration (PlanetLab)
./build.sh

md5sum PlanetLab-BootCD-%{version}.{iso,usb} \
    >PlanetLab-BootCD-%{version}.md5

popd

%install
rm -rf $RPM_BUILD_ROOT

pushd bootcd_v3

# Install the reference image and build scripts
install -d -m 755 $RPM_BUILD_ROOT/%{_datadir}/%{name}
install -m 755 build.sh $RPM_BUILD_ROOT/%{_datadir}/%{name}/
find \
    build/isofs/bootcd.img \
    build/isofs/isolinux.bin \
    build/isofs/kernel \
    build/passwd \
    build/version.txt \
    configurations \
    syslinux/unix/syslinux | \
    cpio -p -d -u $RPM_BUILD_ROOT/%{_datadir}/%{name}/

# Install the default images in the download/ directory
install -d -m 755 $RPM_BUILD_ROOT/var/www/html/download
install -m 644 PlanetLab-BootCD-%{version}.* \
    $RPM_BUILD_ROOT/var/www/html/download/

popd
    
%clean
rm -rf $RPM_BUILD_ROOT

# If run under sudo
if [ -n "$SUDO_USER" ] ; then
    # Allow user to delete the build directory
    chown -R $SUDO_USER .
    # Some temporary cdroot files like /var/empty/sshd and
    # /usr/bin/sudo get created with non-readable permissions.
    find . -not -perm +0600 -exec chmod u+rw {} \;
    # Allow user to delete the built RPM(s)
    chown -R $SUDO_USER %{_rpmdir}/%{_arch}
fi

%post planetlab
cat <<EOF
Remember to GPG sign
/var/www/html/download/PlanetLab-BootCD-%{version}.{iso,usb} with
the PlanetLab private key.
EOF

%files
%defattr(-,root,root,-)
%{_datadir}/%{name}

%files planetlab
%defattr(-,root,root,-)
/var/www/html/download

%changelog
* Mon Jan 29 2006 Marc E. Fiuczynski <mef@cs.princeton.edu> - 
- added biginitrd usb image

* Fri Sep  2 2005 Mark Huang <mlhuang@cotton.CS.Princeton.EDU> - 
- Initial build.

