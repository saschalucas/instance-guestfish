# start guestfish in a remote controlable daemon mode
guestfish_prepare() {
  if [[ "${DISK_COUNT}" -eq 0 ]]; then
    log_fail "Instance has no disk"
  fi
  # start the guestfish with no disks attached
  # later we figure out, what and how to add disks
  eval "$(${GUESTFISH} --listen)"
  GUESTFISH="${GUESTFISH} --remote"
  # guestfish daemon will terminate on error or exit here
  CLEANUP+=("eval ${GUESTFISH} -- exit >/dev/null 2>&1 || true")
}  

# add the target disk, where the OS should be installed
guestfish_add_target_disk() {
  # target disk is Ganeti's disk template: i.e. device, file or ceph image
  local PROTO IMAGE
  if [[ -n "${DISK_0_URI:-}" ]]; then
    # this is for userspace URI (RBD)
    PROTO="${DISK_0_URI/:*/}"
    IMAGE="${DISK_0_URI/*:/}"
    ${GUESTFISH} -- add ${IMAGE} protocol:${PROTO} username:${NEW_VAR_DERIVED_FROM_PR1515:-admin}
    # return here, to not process anything else
    return
  elif [[ -n "${DISK_0_PATH}" ]]; then
    # this handles access to legacy devices and files
    ${GUESTFISH} -- add ${DISK_0_PATH}
  else
    log_fail "no target disk available (DISK_0_URI, DISK_0_PATH)"
  fi
}

# in case the source is an image add it here (as a second disk)
#guestfish_add_source_disk() {
#  # source images can be of different formats i.e. raw, qcow2, vmdk, ...
#  # source images can be served by different protcols: i.e. file, http or https
#  # in any case we add it read only
#
#  # force the user to specify an image format, to not rely on auto detection (CVE-2010-385)
#  [[ -n ${SOURCE_IMAGE_FORMAT:-} ]] && log_fail "no SOURCE_IMAGE_FORMAT specified"
# 
#  local URI_PROTO_REGEX='(file|http|https):\/\/(.+)'
#  if [[ "${SOURCE_URI}" =~ "${URI_PROTO_RGEX}" ]]; then
#    local PROTO="${BASH_REMATCH[0]}"
#    local _="${BASH_REMATCH[1]}"
#    local FILEPATH="${BASH_REMATCH[2]}"
#    local PORT="${BASH_REMATCH[3]:-}"
#  else
#    log_fail "SOURCE_URI=${SOURCE_URI} does not match regex=${URI_REGEX}"
#  fi
#  SOURCE_URI_PROTOCOL="${SOURCE_URI%:*}"
#  SOURCE_URI_DATA="${SOURCE_URI#*://}"
#  
#  case "${SOURCE_URI_PROTOCOL}" in
#    file)
#      IMAGE_ADD_CMD="add ${SOURCE_URI_DATA} readonly:true"
#      [[ -r ${SOURCE_URI_DATA} ]] || log_fail "can not read ${SOURCE_URI_DATA}"
#    ;;
#    http|https)
#      SOURCE_URI_SERVER="${SOURCE_URI_DATA%%/*}"
#      SOURCE_URI_PATH="${SOURCE_URI_DATA#*/}"
#      IMAGE_ADD_CMD="add ${SOURCE_URI_PATH} readonly:true protocol:${SOURCE_URI_PROTOCOL} server:${SOURCE_URI_SERVER}"
#    ;;
#    *)
#      log_fail "source URI protocol ${SOURCE_URI_PROTO} not implemented yet"
#    ;;
#  esac
#  
#  case "${SOURCE_FORMAT}" in 
#    qcow2|raw)
#      ${GUESTFISH} "${IMAGE_ADD_CMD}"
#    ;; 
#  esac
#}
 
guestfish_start() {
  guestfish_prepare
  guestfish_add_target_disk
  # when the source is an image type, add a source disk
  if [[ "${TARGET_NEEDS_SOURCE_DISK:-}" == "true" ]]; then
      guestfish_add_source_disk
  fi
  ${GUESTFISH} -- run
}

flag_source_type() {
  case ${SOURCE_TYPE} in
    image)
      TARGET_NEEDS_SOURCE_DISK="true"
      TARGET_NEEDS_DISK_RESIZE="true"
    ;;
    tar)
      TARGET_DISK_NEEDS_PARTITION="true"
      TARGET_DISK_NEEDS_FILESYSTEM="true"
      TARGET_DISK_NEEDS_FSTAB="true"
      TARGET_DISK_NEEDS_GRUBINSTALL="true"
    ;;
    *)
      log_fail "unhandled SOURCE_TYPE=${SOURCE_TYPE}"
    ;;
  esac
}

parse_source_uri() {
  local RE_LOCAL_OR_REMOTE='(.+)://(.+)'
  local RE_SERVER_PATH_PORT='(.+)/(.+)(:(\d+))?'
  if [[ ${SOURCE_URI} =~ ${RE_LOCAL_OR_REMOTE} ]]; then
    SOURCE_URI_PROTO="${BASH_REMATCH[1]}"
    SOURCE_URI_PATH="${BASH_REMATCH[2]}"
    case ${SOURCE_URI_PROTO} in
      file)
        SOURCE_URI_FILEPATH="${SOURCE_URI_PATH}"
      ;;
      http|https)
        if [[ ${SOURCE_URI_PATH} =~ ${RE_SERVER_PATH_PORT} ]]; then
          SOURCE_URI_SERVER="${BASH_REMATCH[1]}"
          SOURCE_URI_FILEPATH="${BASH_REMATCH[2]}"
          SOURCE_URI_PORT="${BASH_REMATCH[4]}"
        fi
      ;;
      *)
        log_fail "unhandled source protcol ${SOURCE_URI_PROTO}"
      ;;
    esac
  fi
}

# check all prerequirements 
instance_check(){
  local TARGET_DISK_SIZE SOURCE_DISK_SIZE
  TARGET_DISK_SIZE="$(${GUESTFISH} -- blockdev-getsize64 /dev/sda)"
  case ${SOURCE_TYPE} in
    image)
      SOURCE_DISK_SIZE="$(${GUESTFISH} -- blockdev-getsize64 /dev/sdb)"
    ;;
    tar)
      # must be set in variant config
      SOURCE_DISK_SIZE="${TARGET_MIN_SIZE}"
  esac
  if [[ "${TARGET_DISK_SIZE}" -ge ${SOURCE_DISK_SIZE} ]]; then
    return
  else
    log_fail "Target disk to small. Got ${TARGET_DISK_SIZE} want ${SOURCE_DISK_SIZE} bytes"
  fi
}

# prepare the instance, so that data can be copied
instance_prepare_before_copy() {
  if [[ "${TARGET_DISK_NEEDS_PARTITION:-}" == "true" ]]; then
    instance_create_partition
  fi
  if [[ "${TARGET_DISK_NEEDS_FILESYSTEM:-}" == "true" ]]; then
    instance_create_rootfs
  fi
}

# do follow up work after copy
instance_prepare_after_copy() {
  if [[ "${TARGET_DISK_NEEDS_DISK_RESIZE:-}" == "true" ]]; then
    instance_disk_resize
  fi
  if [[ "${TARGET_DISK_NEEDS_FSTAB:-}" == "true" ]]; then
    instance_create_fstab
  fi
  if [[ "${TARGET_DISK_NEEDS_GRUBINSTALL:-}" == "true" ]]; then
    ${GUESTFISH} -- command "grub-install /dev/sda"
  fi
}

instance_create_fstab() {
  TARGET_DISK_SWAP_UUID=$(${GUESTFISH} -- blkid ${TARGET_DISK_SWAP_DEV} | grep ^UUID | awk '{print $2}')
  TARGET_DISK_DATA_UUID=$(${GUESTFISH} -- blkid ${TARGET_DISK_DATA_DEV} | grep ^UUID | awk '{print $2}')
  cat << EOF > ${temp_file}
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=${TARGET_DISK_DATA_UUID} / ${TARGET_DISK_FILESYSTEM:-ext4} errors=remount-ro 0 1
UUID=${TARGET_DISK_SWAP_UUID} none swap sw 0 0
EOF
  ${GUESTFISH} -- upload ${temp_file} /etc/fstab
}

instance_disk_resize() {
  :
  #bdev_size="$(${GUESTFISH} blockdev-getsz /dev/sda)"
  #part_type="$(${GUESTFISH} part-get-parttype /dev/sda)"
  #part_list=($(${GUESTFISH} list-partitions))
  #
  #part_last="${part_list[-1]}"
  #part_last_num="${part_last: -1}"
  #
  #if [ "$part_type" == "gpt" ]; then
  #  echo "expand gpt"
  #  ${GUESTFISH} part-expand-gpt /dev/sda
  #  echo "resize /dev/sda$part_last_num to $(($bdev_size-34))"
  #  ${GUESTFISH} part-resize /dev/sda $part_last_num $(($bdev_size-34))
  #  echo "grow filesystem $part_last"
  #  ${GUESTFISH} resize2fs $part_last
  #else
  #  echo "resize /dev/sda$part_last_num to $(($bdev_size-1))"
  #  ${GUESTFISH} part-resize /dev/sda $part_last_num $(($bdev_size-1))
  #  echo "grow filesystem $part_last"
  #  ${GUESTFISH} resize2fs $part_last
  #fi
}

instance_create_partition() {
  ${GUESTFISH} -- part-init /dev/sda ${TARGET_DISK_PARTITON_TYPE:-mbr}
  # default to 1G swap as the 1st partition
  TARGET_DISK_SWAP_SIZE=${TARGET_DISK_SWAP_SIZE:-1}
  SWAP_START="2048"
  SWAP_END="$(( ${SWAP_START} + ( ${TARGET_DISK_SWAP_SIZE} * 1024 * 1024 * 1024 / 512 ) - 1))"
  DATA_START="$(( ${SWAP_END} + 1 ))"
  DATA_END="-1"
  ${GUESTFISH} -- part-add /dev/sda primary ${SWAP_START} ${SWAP_END}
  ${GUESTFISH} -- part-add /dev/sda primary ${DATA_START} ${DATA_END}
}

instance_create_rootfs() {
  TARGET_DISK_SWAP_DEV="/dev/sda1"
  TARGET_DISK_DATA_DEV="/dev/sda2"
  ${GUESTFISH} -- mkswap ${TARGET_DISK_SWAP_DEV}
  ${GUESTFISH} -- mkfs ${TARGET_DISK_FILESYSTEM:-ext4} ${TARGET_DISK_DATA_DEV}
  ${GUESTFISH} -- mount ${TARGET_DISK_DATA_DEV} /
}

instance_copy() {
  local CMD tmp
  case ${SOURCE_TYPE} in
    image)
      ${GUESTFISH} copy-device-to-device /dev/sdb /dev/sda
    ;;
    tar)
      CMD="${GUESTFISH} -- tar-in ${SOURCE_URI_FILEPATH} / xattrs:true selinux:true acls:true"
      if [[ -n "${SOURCE_COMPRESS:-}" ]]; then
        CMD="${CMD} compress:${SOURCE_COMPRESS}"
      fi
      ${CMD}
      # https://bugzilla.redhat.com/show_bug.cgi?id=1384241
      # guestfish is unwilling to include all xattrs in tar-in command 
      # set them here
      tmp="$(${GUESTFISH} -- is-file /tmp/capabilities.guestfish)"
      if [[ "${tmp}" = "true" ]]; then
        ${GUESTFISH} -- download /tmp/capabilities.guestfish ${temp_file}
        while read line; do
          ${GUESTFISH} -- ${line}
        done < ${temp_file}
      fi
    ;;
  esac
}

instance_configure() {
  # mount when image
  instance_configure_grub
  instance_set_hostname
  instance_set_root_pwhash
  instance_set_root_ssh_auth_keys
  instance_manage_ssh_host_keys
  instance_configure_network
  instance_regenerate_machineid
  instance_iscsi_new_iqn
  # umount wenn fertig
}

# configure grub for serial console, network interface names and non multiqueue io-scheduler
instance_configure_grub() {
  ${GUESTFISH} -- download /etc/default/grub ${temp_file}
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200n8 elevator=noop net.ifnames=0 earlyprintk=ttyS0,115200n8"/' ${temp_file}
  echo '# Serial console
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=8
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
' >> ${temp_file}
  ${GUESTFISH} -- upload ${temp_file} /etc/default/grub
  case ${SOURCE_FLAVOR} in
    ubuntu|debian)
      ${GUESTFISH} -- command "update-grub"
    ;;
    *)
      log_fail "source flavor ${SOURCE_FLAVOR} is not implemented yet"
    ;;
  esac
}

instance_set_hostname() {
  case ${SOURCE_FLAVOR} in
    ubuntu|debian)
      ${GUESTFISH} -- write /etc/hostname "${INSTANCE_NAME%%.*}"
    ;;
    *)
      log_fail "source flavor ${SOURCE_FLAVOR} is not implemented yet"
   ;;
  esac
}

instance_set_root_pwhash() {
  if [[ -n "${TARGET_ROOT_PWHASH:=${OSP_ROOT_PW_HASH:-}}" ]]; then
    ${GUESTFISH} -- command "usermod -p ${TARGET_ROOT_PWHASH} root"
    ${GUESTFISH} -- download /etc/ssh/sshd_config ${temp_file}
    sed -r -i 's/^(|#|# )PermitRootLogin.*/PermitRootLogin yes/' ${temp_file}
    ${GUESTFISH} -- upload ${temp_file} /etc/ssh/sshd_config
  fi
}

instance_set_root_ssh_auth_keys() {
  if [[ -n "${TARGET_ROOT_SSH_AUTH_KEYS:=${OSP_ROOT_SSH_AUTH_KEY:-}}" ]]; then
    tmp="$(${GUESTFISH} -- is-dir /root/.ssh)"
    [[ "${tmp}" = "true" ]] || ${GUESTFISH} -- mkdir-mode /root/.ssh 0700
    ${GUESTFISH} -- write /root/.ssh/authorized_keys "${TARGET_ROOT_SSH_AUTH_KEYS}"
  fi
}

instance_manage_ssh_host_keys() {
  for i in $(${GUESTFISH} -- glob-expand /etc/ssh/ssh_host_'*'); do
    ${GUESTFISH} -- rm ${i}
  done
  case ${SOURCE_FLAVOR} in
    ubuntu|debian)
      ${GUESTFISH} -- command "dpkg-reconfigure openssh-server"
    ;;
    *)
      log_fail "source flavor ${SOURCE_FLAVOR} is not implemented yet"
    ;;
  esac
}

instance_configure_network() {
  if [[ -n "${NIC_0_IP:-}" &&  -n "${NIC_0_NETWORK_SUBNET:-}" &&  -n "${NIC_0_NETWORK_GATEWAY:-}" ]]; then
    tmp="$(${GUESTFISH} -- is-file /etc/udev/rules.d/70-persistent-net.rules)"
    if [[ "${tmp}" = "true" ]]; then
      ${GUESTFISH} -- rm /etc/udev/rules.d/70-persistent-net.rules
    fi
    tmp="$(${GUESTFISH} -- is-symlink /etc/resolv.conf)"
    if [[ "${tmp}" = "true" ]]; then
      ${GUESTFISH} -- rm /etc/resolv.conf
    fi
    ${GUESTFISH} -- write /etc/resolv.conf "nameserver ${TARGET_NAMESERVER:-${NIC_0_NETWORK_GATEWAY:-127.0.0.1}}"
    case ${SOURCE_FLAVOR} in
      ubuntu|debian)
        cat <<-EOF > ${temp_file}
		# This file describes the network interfaces available on your system
		# and how to activate them. For more information, see interfaces(5).
		
		# The loopback network interface
		auto lo
		iface lo inet loopback
		
		# The primary network interface
		auto eth0
		iface eth0 inet static
		        address ${NIC_0_IP}
		        netmask ${NIC_0_NETWORK_SUBNET##*/}
		        gateway ${NIC_0_NETWORK_GATEWAY}
	EOF
        ${GUESTFISH} -- upload ${temp_file} /etc/network/interfaces
      ;;
      *)
        log_fail "source flavor ${SOURCE_FLAVOR} is not implemented yet"
      ;;
    esac
  fi
}

instance_regenerate_machineid() {
  for f in /etc/machine-id /var/lib/dbus/machine-id; do
    tmp="$(${GUESTFISH} -- is-file ${f})"
    if [[ "${tmp}" = "true" ]]; then
      ${GUESTFISH} -- rm "${f}"
      # when /etc/machine-id is an emtpy file a new ID will be generated
      if [[ "${i}" = "/etc/machine-id" ]]; then
        ${GUESTFISH} --remote=${GUESTFISH_PID} -- touch ${i}
      fi
    fi
  done
}

instance_iscsi_new_iqn() {
  tmp="$(${GUESTFISH} --remote=${GUESTFISH_PID} -- is-file /etc/iscsi/initiatorname.iscsi)"
  if [[ "${tmp}" = "true" ]]; then
    ${GUESTFISH} --remote=${GUESTFISH_PID} -- write /etc/iscsi/initiatorname.iscsi "GenerateName=yes"
  fi
}
