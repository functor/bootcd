%define name bootcd
%define version 3.2
%define release 1.planetlab%{?date:.%{date}}
# XXX Get this from /etc/planetlab
%define configuration default

Vendor: PlanetLab
Packager: PlanetLab Central <support@planet-lab.org>
Distribution: PlanetLab 3.2
URL: http://cvs.planet-lab.org/cvs/bootcd_v3

Summary: The PlanetLab Boot CD
Name: bootcd
Version: %{version}
Release: %{release}
License: BSD
Group: System Environment/Base
Source0: %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root

AutoReqProv: no
%define debug_package %{nil}

%description
The PlanetLab Boot CD securely boots PlanetLab nodes into an immutable
environment.

%prep
%setup -q

%build
./build.sh build %{configuration}

%install
install -d $RPM_BUILD_ROOT/var/www/html/download
pushd build/%{configuration}
bzip2 -c PlanetLab-BootCD-%{version}.iso > \
    $RPM_BUILD_ROOT/var/www/html/download/PlanetLab-BootCD-%{version}.iso.bz2
bzip2 -c PlanetLab-BootCD-%{version}.usb > \
    $RPM_BUILD_ROOT/var/www/html/download/PlanetLab-BootCD-%{version}.usb.bz2
md5sum PlanetLab-BootCD-%{version}.{iso,usb} >> \
    $RPM_BUILD_ROOT/var/www/html/download/PlanetLab-BootCD-%{version}.md5
cd $RPM_BUILD_ROOT/var/www/html/download/
md5sum PlanetLab-BootCD-%{version}.{iso,usb}.bz2 >> \
    PlanetLab-BootCD-%{version}.md5
popd
    
# If run under sudo, allow user to delete the build directory
if [ -n "$SUDO_USER" ] ; then
    chown -R $SUDO_USER .
    # Some temporary cdroot files like /var/empty/sshd and
    # /usr/bin/sudo get created with non-readable permissions.
    find . -not -perm +0600 -exec chmod u+rw {} \;
fi

%clean
rm -rf $RPM_BUILD_ROOT

# If run under sudo, allow user to delete the built RPM
if [ -n "$SUDO_USER" ] ; then
    chown $SUDO_USER %{_rpmdir}/%{_arch}/%{name}-%{version}-%{release}.%{_arch}.rpm
fi

%post
cat <<EOF
Remember to GPG sign
/var/www/html/download/PlanetLab-BootCD-%{version}.{iso,usb}.bz2 with
the PlanetLab private key.
EOF

%files
%defattr(-,root,root,-)
/var/www/html/download/PlanetLab-BootCD-%{version}.iso.bz2
/var/www/html/download/PlanetLab-BootCD-%{version}.usb.bz2
/var/www/html/download/PlanetLab-BootCD-%{version}.md5

%changelog
* Fri Sep  2 2005 Mark Huang <mlhuang@cotton.CS.Princeton.EDU> - 
- Initial build.

