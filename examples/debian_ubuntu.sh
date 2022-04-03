#!/bin/bash

set -euo pipefail

HELP_MSG="SUITE=[buster|bullseye|bionic|focal|jammy] ${0} dest-dir"
SUITE="${SUITE:?please specify a suite: $HELP_MSG}"
DEST="${1:?please specify a destination directory to store the result: $HELP_MSG}"

case ${SUITE} in
	bionic|focal|jammy)
		DEFAULT_MIRROR="http://archive.ubuntu.com/ubuntu"
		KERNEL_PACKAGE="linux-image-generic"
		APT_COMPONENTS="main,universe,multiverse,restricted"
		;;
	buster|bullseye)
		DEFAULT_MIRROR="http://deb.debian.org/debian"
		KERNEL_PACKAGE="linux-image-amd64"
		APT_COMPONENTS="main,contrib,non-free"
		;;
	*)
		echo "unhandled SUITE=${SUITE}"
		exit 1
		;;
esac

# let the user override the mirror
MIRROR="${MIRROR:-${DEFAULT_MIRROR}}"
BASE_PACKAGES="openssh-server,ifupdown,grub-pc,locales,dbus,initramfs-tools,${KERNEL_PACKAGE}"

# mktemp creates secure dirs, however root aka "/" needs 755
tmp="$(mktemp -d)"
chmod 755 ${tmp}

# installs a basic system without updates
debootstrap --arch=amd64 --include=${BASE_PACKAGES} --components=${APT_COMPONENTS} ${SUITE} ${tmp} ${MIRROR}

# configures apt
[[ -n ${http_proxy:-} ]] && echo "Acquire::http::Proxy \"${http_proxy}\";" > ${tmp}/etc/apt/apt.conf.d/99proxy
case ${SUITE} in
        bionic|focal|jammy)
		cat <<- EOF > ${tmp}/etc/apt/sources.list
			deb ${MIRROR} ${SUITE} ${APT_COMPONENTS//,/ }
			deb ${MIRROR} ${SUITE}-updates ${APT_COMPONENTS//,/ }
			deb ${MIRROR} ${SUITE}-security ${APT_COMPONENTS//,/ }
		EOF
		;;
	buster)
		cat <<- EOF > ${tmp}/etc/apt/sources.list
			deb ${MIRROR} ${SUITE} ${APT_COMPONENTS//,/ }
			deb ${MIRROR} ${SUITE}-updates ${APT_COMPONENTS//,/ }
			deb ${MIRROR}-security ${SUITE}/updates ${APT_COMPONENTS//,/ }
		EOF
		;;
	bullseye)
		cat <<- EOF > ${tmp}/etc/apt/sources.list
			deb ${MIRROR} ${SUITE} ${APT_COMPONENTS//,/ }
			deb ${MIRROR} ${SUITE}-updates ${APT_COMPONENTS//,/ }
			deb ${MIRROR}-security ${SUITE}-security ${APT_COMPONENTS//,/ }
		EOF
		;;
esac

# configure some packages
for i in tzdata locales; do
  chroot ${tmp} dpkg-reconfigure ${i}
done

# update the system
export DEBIAN_FRONTEND=noninteractive
chroot ${tmp} apt update
chroot ${tmp} apt -y full-upgrade
chroot ${tmp} apt -y autoremove --purge
chroot ${tmp} apt clean

# https://bugzilla.redhat.com/show_bug.cgi?id=1384241
# guestfish is unwilling to include all xattrs in tar-in command
# we will save a list of files/caps here, to later restore them (at Ganeti OS creation time)
find ${tmp}/ -type f -print0 | xargs -0 getcap | while read f s c; do echo "cap-set-file ${f#${tmp}} ${c}"; done > ${tmp}/tmp/capabilities.guestfish

# save our work
tar --gzip --acls --selinux --xattrs --xattrs-include='*' --numeric-owner -cvf ${DEST}/${SUITE}.tar.gz -C ${tmp} .

# cleanup
rm -rf ${tmp}

