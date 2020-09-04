#/usr/bin/env bash

function instance_mount() {
local patition=$1
echo "mount instance: ${1}"
guestfish --remote mount $patition /
}

function instance_unmount() {
local patition=$1
echo "unmount instance: ${1}"
guestfish --remote unmount $patition
}

function instance_hostname() {
echo "set hostname to: ${INSTANCE_NAME}"
echo "${INSTANCE_NAME}" > "${DIR}/hostname"
guestfish --remote upload "${DIR}/hostname" /etc/hostname
rm -f "${DIR}/hostname"
}

function instance_hosts() {
echo "configure hosts: ${NIC_0_IP} ${INSTANCE_NAME}"
cat >> ${DIR}/hosts << _EOF_
127.0.0.1       localhost
${NIC_0_IP}       ${INSTANCE_NAME}

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
_EOF_
guestfish --remote upload "${DIR}/hosts" /etc/hosts
rm -f ${DIR}/hosts
}

function CIDR2Netmask() {
  cidr=${1}
  one=$(seq ${cidr} | sed -e "c1" | tr -d '\n')
  zero=$(seq $(( 32 - ${cidr} )) | sed -e "c0" | tr -d '\n')
  bin=$( echo -n "${one}${zero}" | sed 's/\(.\{8\}\)\(.\{8\}\)\(.\{8\}\)\(.\{8\}\)/\1.\2.\3.\4/g')
  bin=(${bin//./ })
  echo -n "$(( 2#${bin[0]} )).$(( 2#${bin[1]} )).$(( 2#${bin[2]} )).$(( 2#${bin[3]} ))"
}

function instance_network() {

for NIC in $(seq 0 $(($NIC_COUNT - 1))); do

NETWORK_CIDR="$(echo $(eval 'echo ${NIC_'${NIC}'_NETWORK_SUBNET}') | awk -F'/' '{ print $2 }')"
NETWORK_MASK="netmask $(CIDR2Netmask ${NETWORK_CIDR})"
NETWORK_GATEWAY=''
NETWORK_DNS_SEARCH=''
NETWORK_DNS_SERVERS=''

if [ "$(eval 'echo ${NIC_'${NIC}'_NETWORK_GATEWAY}')" != '' ]; then
  NETWORK_GATEWAY="gateway $(eval 'echo ${NIC_'${NIC}'_NETWORK_GATEWAY}')"
fi

for NETWORK_TAG in $(eval 'echo ${NIC_'${NIC}'_NETWORK_TAGS}'); do
  KEY=${NETWORK_TAG//:*/}
  VAL=${NETWORK_TAG//*:/}
  if [ "${KEY}" == "dns-search" ]; then
     NETWORK_DNS_SEARCH="dns-search ${VAL}"
  fi
  if [ "${KEY}" == "dns-nameservers" ]; then
     NETWORK_DNS_SERVERS="dns-nameservers ${VAL}"
  fi
done

if [ -n ${OSP_DNS-SEARCH} ]; then
  NETWORK_DNS_SEARCH="dns-search ${OSP_DNS-SEARCH}"
fi
if [ -n ${OSP_DNS-SERVER} ]; then
  NETWORK_DNS_SERVERS="dns-nameservers ${OSP_DNS-SERVER}"
fi

cat >> ${DIR}/eth${NIC}.conf << _EOF_
allow-hotplug eth${NIC}
iface eth${NIC} inet static
  address $(eval 'echo ${NIC_'${NIC}'_IP}')
  ${NETWORK_MASK}
  ${NETWORK_GATEWAY} 
  ${NETWORK_DNS_SERVERS}
  ${NETWORK_DNS_SEARCH}
iface eth${NIC} inet6 auto
_EOF_

guestfish --remote upload "${DIR}/eth${NIC}.conf" /etc/network/interfaces.d/eth${NIC}.conf
rm -f ${DIR}/eth${NIC}.conf

done
}

function guestfish_start() {

if [ "${DISK_COUNT}" -eq 0 ]; then
  log_fail "Instance has no disk"
fi

eval "$(guestfish --listen)"
CLEANUP+=("eval guestfish --remote -- exit >/dev/null 2>&1 || true")

if [ -n "${DISK_0_URI}" ]; then
  DISK_0_URI_DRIVER="${DISK_0_URI//:*/}"
  DISK_0_URI_IMAGE="${DISK_0_URI//*:/}"
  guestfish --remote add ${DISK_0_URI_IMAGE} protocol:${DISK_0_URI_DRIVER} username:admin
  echo "source: ${IMG_PATH} destiantion: ${DISK_0_URI}"
else
  guestfish --remote add ${DISK_0_PATH}
  echo "source: ${IMG_PATH} destiantion: ${DISK_0_PATH}"
fi

SOURCE_URI_PROTOCOL="${SOURCE_URI%:*}"
SOURCE_URI_DATA="${SOURCE_URI#*://}"

case "${SOURCE_URI_PROTOCOL}" in
  file)
    IMAGE_ADD_CMD="add ${SOURCE_URI_DATA} readonly:true"
    [[ -r ${SOURCE_URI_DATA} ]] || log_fail "can not read ${SOURCE_URI_DATA}"
  ;;
  http|https)
    SOURCE_URI_SERVER="${SOURCE_URI_DATA%%/*}"
    SOURCE_URI_PATH="${SOURCE_URI_DATA#*/}"
    IMAGE_ADD_CMD="add ${SOURCE_URI_PATH} readonly:true protocol:${SOURCE_URI_PROTOCOL} server:${SOURCE_URI_SERVER}"
  ;;
  *)
    log_fail "source URI protocol ${SOURCE_URI_PROTO} not implemented yet"
  ;;
esac

case "${SOURCE_FORMAT}" in 
  qcow2|raw)
    guestfish --remote "${IMAGE_ADD_CMD}"
  ;; 
esac

echo "start guestfish"
guestfish --remote run
}

function instance_prepare_image() {
echo "copy instance"
guestfish --remote copy-device-to-device /dev/sdb /dev/sda

bdev_size="$(guestfish --remote blockdev-getsz /dev/sda)"
part_type="$(guestfish --remote part-get-parttype /dev/sda)"
part_list=($(guestfish --remote list-partitions))

part_last="${part_list[-1]}"
part_last_num="${part_last: -1}"

if [ "$part_type" == "gpt" ]; then
  echo "expand gpt"
  guestfish --remote part-expand-gpt /dev/sda
  echo "resize /dev/sda$part_last_num to $(($bdev_size-34))"
  guestfish --remote part-resize /dev/sda $part_last_num $(($bdev_size-34))
  echo "grow filesystem $part_last"
  guestfish --remote resize2fs $part_last
else
  echo "resize /dev/sda$part_last_num to $(($bdev_size-1))"
  guestfish --remote part-resize /dev/sda $part_last_num $(($bdev_size-1))
  echo "grow filesystem $part_last"
  guestfish --remote resize2fs $part_last
fi
}

function instance_prepare_fs() {
  # TODO:
}

function instance_prepare() {
TARGET_SIZE="$(guestfish --remote blockdev-getsize64 /dev/sda)"
if [[ ${TARGET_SIZE} -lt ${TARGET_MIN_SIZE} ]]; then
  log_fail "the target disk ${DISK_0_PATH:-${DISK_0_URI}} is to small \
(got $(( ${TARGET_SIZE} / 1024 / 1024 )) MB, but need $(( ${TARGET_MIN_SIZE} / 1024 / 1024 )) MB)"
if

case "${SOURCE_FORMAT}" in 
  qcow2|raw)
    instance_prepare_image
  ;;
  tar)
    instance_prepare_fs
  ;;
esac

}

function instance_modify() {
DIR="/tmp/guestfish/${INSTANCE_NAME}/${OS_VARIANT}"
mkdir -p "${DIR}"
instance_mount /dev/sda3
instance_hostname
instance_hosts
instance_network
instance_unmount /dev/sda3
}
