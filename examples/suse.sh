#!/bin/bash

set -euo pipefail

HELP_MSG="SUITE=[leap15.6] ${0} dest-dir"
SUITE="${SUITE:?please specify a suite: $HELP_MSG}"
DEST="${1:?please specify a destination directory to store the result: $HELP_MSG}"

case ${SUITE} in
	leap15.*)
		REL_PKG="openSUSE-repos"
		;;
	leap16.*)
		REL_PKG="Leap-release"
		;;
	*)
		echo "unhandled SUITE=${SUITE}"
		exit 1
		;;
esac

REL_VER="${SUITE#leap}"
BASE_PACKAGES="openssh-server wicked grub2-i386-pc kernel-default"

# mktemp creates secure dirs, however root aka "/" needs 755
tmp="$(mktemp -d)"
chmod 755 ${tmp}

# installs a basic system
# https://en.opensuse.org/Package_repositories
zypper -R ${tmp} addrepo --refresh "http://download.opensuse.org/distribution/leap/${REL_VER}/repo/oss" "default-repo-oss"
# Leap 16.0 No dedicated update repository as we use repo-oss for updates as well.
case ${SUITE} in
	leap15.*)
		zypper -R ${tmp} addrepo --refresh "http://download.opensuse.org/update/leap/${REL_VER}/oss"            "default-repo-update-oss"
		;;
esac
zypper -R ${tmp} --gpg-auto-import-keys refresh
zypper -R ${tmp} -vn install ${REL_PKG}
rm ${tmp}/etc/zypp/repos.d/default-repo-*

cp /etc/resolv.conf ${tmp}/etc/
mount -o bind /dev ${tmp}/dev
chroot ${tmp} zypper --gpg-auto-import-keys refresh
sleep 5s
umount ${tmp}/dev
chroot ${tmp} zypper -vn install -t pattern enhanced_base
chroot ${tmp} zypper -vn install ${BASE_PACKAGES}
chroot ${tmp} zypper clean
chroot ${tmp} systemctl enable sshd.service
chroot ${tmp} update-ca-certificates -f

# https://bugzilla.redhat.com/show_bug.cgi?id=1384241
# guestfish is unwilling to include all xattrs in tar-in command
# we will save a list of files/caps here, to later restore them (at Ganeti OS creation time)
find ${tmp}/ -type f -print0 | xargs -0 getcap | while read f s c; do echo "cap-set-file ${f#${tmp}} ${c:-${s}}"; done > ${tmp}/tmp/capabilities.guestfish

# save our work
tar --gzip --acls --selinux --xattrs --xattrs-include='*' --numeric-owner -cvf ${DEST}/${SUITE}.tar.gz -C ${tmp} .

# cleanup
rm -rf ${tmp}
