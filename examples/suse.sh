#!/bin/bash

set -euo pipefail

HELP_MSG="SUITE=[leap15.6] ${0} dest-dir"
SUITE="${SUITE:?please specify a suite: $HELP_MSG}"
DEST="${1:?please specify a destination directory to store the result: $HELP_MSG}"

case ${SUITE} in
	leap*)
		REL_VER="${SUITE#leap}"
		;;
	*)
		echo "unhandled SUITE=${SUITE}"
		exit 1
		;;
esac

BASE_PACKAGES="openssh-server wicked grub2-i386-pc kernel-default"

# mktemp creates secure dirs, however root aka "/" needs 755
tmp="$(mktemp -d)"
chmod 755 ${tmp}

# installs a basic system
zypper -R ${tmp} addrepo --refresh "http://download.opensuse.org/distribution/leap/${REL_VER}/repo/oss" "default-repo-oss"
zypper -R ${tmp} addrepo --refresh "http://download.opensuse.org/update/leap/${REL_VER}/oss"            "default-repo-update-oss"
zypper -R ${tmp} --gpg-auto-import-keys refresh
zypper -R ${tmp} -vn install openSUSE-repos || true
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

# https://bugzilla.redhat.com/show_bug.cgi?id=1384241
# guestfish is unwilling to include all xattrs in tar-in command
# we will save a list of files/caps here, to later restore them (at Ganeti OS creation time)
find ${tmp}/ -type f -print0 | xargs -0 getcap | while read f s c; do echo "cap-set-file ${f#${tmp}} ${c:-${s}}"; done > ${tmp}/tmp/capabilities.guestfish

# save our work
tar --gzip --acls --selinux --xattrs --xattrs-include='*' --numeric-owner -cvf ${DEST}/${SUITE}.tar.gz -C ${tmp} .

# cleanup
rm -rf ${tmp}

