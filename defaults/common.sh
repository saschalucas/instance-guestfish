#####
##### Vars
#####

# Binarys needed for this script
DEPS="guestfish"

#####
##### Functions
#####

# the cleanup from instance-debootstrap
CLEANUP=()
cleanup() {
  if [[ ${#CLEANUP[*]} -gt 0 ]]; then
    local LAST_ELEMENT="$(( ${#CLEANUP[*]} - 1 ))"
    local REVERSE_INDEXES="$(seq ${LAST_ELEMENT} -1 0)"
    local i
    for i in ${REVERSE_INDEXES}; do
      ${CLEANUP[$i]}
    done
  fi
}

log_fail() {
  echo "$@" 2>&1
  exit 1
}

check_deps() {
  local d search
  for d in ${DEPS}; do
    search="$(which ${d} || true)"
    [[ -x ${search} ]] || log_fail "binary ${d} is needed, but can not be found"
  done
}

#####
##### Main
#####
trap cleanup EXIT
check_deps
