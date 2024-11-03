#!/bin/bash
# shellcheck disable=SC2004,SC2012,SC2181

#Colors
RED='\033[1;31m'
GREEN='\033[1;32m'
NOCOLOR='\033[0m'

#Other variables
version="v0.5.3"
CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
LOGFILE="${CURRENT_DIR}/${SCRIPTNAME%.*}.log"
REQUIRED_TOOLS="parted losetup tune2fs md5sum e2fsck resize2fs"
ZIPTOOLS=("gzip pigz xz")
declare -A ZIP_PARALLEL_TOOL=( [gzip]="pigz" [xz]="xz" ) # parallel zip tool to use in parallel mode
declare -A ZIP_PARALLEL_OPTIONS=( [pigz]="-f9" [xz]="-T0" ) # options for zip tools in parallel mode
declare -A ZIPEXTENSIONS=( [gzip]="gz" [xz]="xz" ) # extensions of zipped files

function cleanup() {
	if losetup "$loopback" &>/dev/null; then
		losetup -d "$loopback"
	fi
	if [ "$debug" = true ]; then
		local old_owner
		old_owner=$(stat -c %u:%g "$src")
		chown "$old_owner" "$LOGFILE"
	fi
}

function logVariables() {
	if [ "$debug" = true ]; then
		echo "Line $1" >> "$LOGFILE"
		shift
		local v var
		for var in "$@"; do
			eval "v=\$$var"
			echo "$var: $v" >> "$LOGFILE"
		done
	fi
}

function checkFilesystem() {
	echo -e "${GREEN}Checking filesystemy${NOCOLOR}"
	e2fsck -pf "$loopback"
	(( $? < 4 )) && return
	echo -e "${RED}Filesystem error detected!${NOCOLOR}"
	echo -e "${RED}Trying to recover corrupted filesystem${NOCOLOR}"
	e2fsck -y "$loopback"
	(( $? < 4 )) && return
	if [[ $repair == true ]]; then
	  info "Trying to recover corrupted filesystem - Phase 2"
	  e2fsck -fy -b 32768 "$loopback"
	  (( $? < 4 )) && return
	fi
	echo -e "${RED}Filesystem recoveries failed. Giving up...${NOCOLOR}"
	exit 9
}

function set_autoexpand() {
  #Make pi expand rootfs on next boot
  mountdir=$(mktemp -d)
  partprobe "$loopback"
	sleep 3
  umount "$loopback" > /dev/null 2>&1
  mount "$loopback" "$mountdir" -o rw
  if (( $? != 0 )); then
  	echo -e "${RED}Unable to mount loopback, autoexpand will not be enabled"
    return
  fi
	if [ ! -d "$mountdir/etc" ]; then
    echo -e "${RED}/etc not found, autoexpand will not be enabled${NOCOLOR}"
    umount "$mountdir"
    return
	fi
	if [[ ! -f "$mountdir/etc/rc.local" ]]; then
			info "An existing /etc/rc.local was not found, autoexpand may fail..."
	fi
	if [[ -f "$mountdir/etc/rc.local" ]] && [[ "$(md5sum "$mountdir/etc/rc.local" | cut -d ' ' -f 1)" != "5c286b336c0606ed8e6f87708f7802eb" ]]; then
    echo "Creating new /etc/rc.local"
  if [ -f "$mountdir/etc/rc.local" ]; then
    mv "$mountdir/etc/rc.local" "$mountdir/etc/rc.local.bak"
  fi

    #####Do not touch the following lines#####
cat <<\EOF1 > "$mountdir/etc/rc.local"
#!/bin/bash
do_expand_rootfs() {
  ROOT_PART=$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p')

  PART_NUM=${ROOT_PART#mmcblk0p}
  if [ "$PART_NUM" = "$ROOT_PART" ]; then
    echo "$ROOT_PART is not an SD card. Don't know how to expand"
    return 0
  fi

  # Get the starting offset of the root partition
  PART_START=$(parted /dev/mmcblk0 -ms unit s p | grep "^${PART_NUM}" | cut -f 2 -d: | sed 's/[^0-9]//g')
  [ "$PART_START" ] || return 1
  # Return value will likely be error for fdisk as it fails to reload the
  # partition table because the root fs is mounted
  fdisk /dev/mmcblk0 <<EOF
p
d
$PART_NUM
n
p
$PART_NUM
$PART_START

p
w
EOF

cat <<EOF > /etc/rc.local &&
#!/bin/sh
echo "Expanding /dev/$ROOT_PART"
resize2fs /dev/$ROOT_PART
rm -f /etc/rc.local; cp -fp /etc/rc.local.bak /etc/rc.local && /etc/rc.local

EOF
reboot
exit
}
raspi_config_expand() {
/usr/bin/env raspi-config --expand-rootfs
if [[ $? != 0 ]]; then
  return -1
else
  rm -f /etc/rc.local; cp -fp /etc/rc.local.bak /etc/rc.local && /etc/rc.local
  reboot
  exit
fi
}
raspi_config_expand
echo "WARNING: Using backup expand..."
sleep 5
do_expand_rootfs
echo "ERROR: Expanding failed..."
sleep 5
if [[ -f /etc/rc.local.bak ]]; then
  cp -fp /etc/rc.local.bak /etc/rc.local
  /etc/rc.local
fi
exit 0
EOF1
    #####End no touch zone#####
    chmod +x "$mountdir/etc/rc.local"
    fi
    umount "$mountdir"
}

help() {
	local help
	read -r -d '' help << EOM
Usage: $0 [-acdhrspvzZ] imagefile.img [newimagefile.img]
  -0         Using zerofree to save additional space by finding unallocated blocks in an extx
             filesystem and fills them with zeroes
  -a         Compress image in parallel using multiple cores (don't combine with -c)
  -c         Compress image after shrinking with gzip (don't combine with -a)
  -d         Write debug messages in a debug log file
  -h         This help screen
  -r         Use advanced filesystem repair option if the normal one fails
  -s         Don't expand filesystem when image is booted the first time
  -p         Remove logs, apt archives, dhcp leases, ssh hostkeys and users bash history
  -v         Be verbose
  -z         Compress image after shrinking with pigz (uses threads)
  -Z         Compress image after shrinking with xz

EOM
	echo "$help"
	exit 1
}

should_skip_autoexpand=false
debug=false
repair=false
parallel=false
verbose=false
prep=false
zerofree=false
ziptool=""

while getopts ":0acdhprsvzZ" opt; do
  case "${opt}" in
		0) zerofree=true;;
    a) parallel=true;;
		c) ziptool="gzip";;
    d) debug=true;;
    h) help;;
    p) prep=true;;
    r) repair=true;;
    s) should_skip_autoexpand=true ;;
    v) verbose=true;;
    z) ziptool="pigz";;
    Z) ziptool="xz";;
    *) help;;
  esac
done
shift $((OPTIND-1))

if [ "$debug" = true ]; then
	echo -e "${GREEN}Creating log file $LOGFILE${NOCOLOR}"
	rm "$LOGFILE" &>/dev/null
	exec 1> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&1)
	exec 2> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&2)
fi

echo -e "${GREEN}${0##*/} $version${NOCOLOR}"

#Args
src="$1"
img="$1"

#Usage checks
if [[ -z "$img" ]]; then
  help
fi

if [[ ! -f "$img" ]]; then
  echo -e "${RED}$img is not a file...${NOCOLOR}"
  exit 2
fi
if (( EUID != 0 )); then
  echo -e "${RED}You need to be running as root.${NOCOLOR}"
  exit 3
fi

# set locale to POSIX(English) temporarily
# these locale settings only affect the script and its sub processes

export LANGUAGE=POSIX
export LC_ALL=POSIX
export LANG=POSIX


# check selected compression tool is supported and installed
if [[ -n $ziptool ]]; then
	# WE HAVE TO FIX THAT - see https://www.shellcheck.net/wiki/SC2199
	# shellcheck disable=SC2199
	if [[ ! " ${ZIPTOOLS[*]} " =~ $ziptool ]]; then
		echo -e "${RED}$ziptool is an unsupported ziptool.${NOCOLOR}"
		exit 17
	else
		if [[ $parallel == true && $ziptool == "gzip" ]]; then
			REQUIRED_TOOLS="$REQUIRED_TOOLS pigz"
		else
			REQUIRED_TOOLS="$REQUIRED_TOOLS $ziptool"
		fi
	fi
fi

#Check that what we need is installed
for command in $REQUIRED_TOOLS; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo -e "${RED}$command is not installed.${NOCOLOR}"
    exit 4
  fi
done

#Copy to new file if requested
if [ -n "$2" ]; then
  f="$2"
  if [[ -n $ziptool && "${f##*.}" == "${ZIPEXTENSIONS[$ziptool]}" ]]; then	# remove zip extension if zip requested because zip tool will complain about extension
    f="${f%.*}"
  fi
  echo -e "${GREEN}Copying $1 to $f...${NOCOLOR}"
  if ! cp --reflink=auto --sparse=always "$1" "$f"; then
    echo -e "${RED}Could not copy file...${NOCOLOR}"
    exit 5
  fi
  old_owner=$(stat -c %u:%g "$1")
  chown "$old_owner" "$f"
  img="$f"
fi

# cleanup at script exit
trap cleanup EXIT

#Gather info
echo -e "${GREEN}Gathering data${NOCOLOR}"
beforesize="$(du -h "$img" | cut -f -1)"
parted_output="$(parted -ms "$img" unit B print)"
rc=$?
if (( $rc )); then
	echo -e "${RED}parted failed with rc $rc${NOCOLOR}"
	echo -e "${RED}Possibly invalid image. Run 'parted $img unit B print' manually to investigate${NOCOLOR}"
	exit 6
fi
partnum="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 1)"
partstart="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 2 | tr -d 'B')"
# WE HAVE TO FIX THAT - see https://www.shellcheck.net/wiki/SC2143
# shellcheck disable=SC2143
if [ -z "$(parted -s "$img" unit B print | grep "$partstart" | grep logical)" ]; then
    parttype="primary"
else
    parttype="logical"
fi
loopback="$(losetup -f --show -o "$partstart" "$img")"
tune2fs_output="$(tune2fs -l "$loopback")"
rc=$?
if (( $rc )); then
    echo -e "${RED}$tune2fs_output${NOCOLOR}"
    echo -e "${RED}tune2fs failed. Unable to shrink this type of image${NOCOLOR}"
    exit 7
fi

currentsize="$(echo "$tune2fs_output" | grep '^Block count:' | tr -d ' ' | cut -d ':' -f 2)"
blocksize="$(echo "$tune2fs_output" | grep '^Block size:' | tr -d ' ' | cut -d ':' -f 2)"

logVariables $LINENO beforesize parted_output partnum partstart parttype tune2fs_output currentsize blocksize

#Check if we should make pi expand rootfs on next boot
if [ "$parttype" == "logical" ]; then
  echo -e "${RED}WARNING: PiShrink does not yet support autoexpanding of this type of image${NOCOLOR}"
elif [ "$should_skip_autoexpand" = false ]; then
  set_autoexpand
else
  echo -e "${RED}Skipping autoexpanding process...${NOCOLOR}"
fi

if [[ $prep == true ]]; then
  echo -e "${GREEN}Syspreping: Removing logs, apt archives, dhcp leases and users bash history${NOCOLOR}"
  mountdir=$(mktemp -d)

  # Temporarily mount image to manipulate internal files
  mount "$loopback" "$mountdir"

  # Remove unwanted cache, logs, sensitive data
	# $mountdir/etc/ssh/*_host_* is not removed, according to https://github.com/Drewsif/PiShrink/pull/247/files
	# shellcheck disable=SC2086
  rm -rvf $mountdir/var/cache/apt/archives/* \
          $mountdir/var/lib/dhcpcd5/* \
          $mountdir/var/tmp/* \
          $mountdir/tmp/*

	# We shouldn't remove folders because some applications will not start (for example nginx)
	# shellcheck disable=SC2044
	for logs in $(find "$mountdir/var/log" -type f); do rm -rvf "$logs"; done

  # Remove users' pip cache if it exists
  find "$mountdir" -regextype egrep -regex '.*/(home/.*|root)/\.cache/pip' -type d -exec rm -vrf {} +;

  # Remove any user's bash session history
  find "$mountdir" -regextype egrep -regex '.*/(home/.*|root)/\.bash_history[0-9]*' -type f -exec rm -vf {} \;
  find "$mountdir" -regextype egrep -regex '.*/(home/.*|root)/\.bash_sessions' -type d -exec rm -vrf {} +;

	# Check if openssh is enabled (taken and adapted from https://github.com/shatteredsword/PiShrink)
	if [[ -f "$mountdir/etc/systemd/system/multi-user.target.wants/ssh.service" ]]; then
		if [[ -f "$mountdir/lib/systemd/system/regenerate_ssh_host_keys.service" ]] && [[ -d "$mountdir/etc/systemd/system/multi-user.target.wants" ]]; then
			if [[ ! -f "$mountdir/etc/systemd/system/multi-user.target.wants/regenerate_ssh_host_keys.service" ]]; then
				ln -s "$mountdir/lib/systemd/system/regenerate_ssh_host_keys.service" "$mountdir/etc/systemd/system/multi-user.target.wants/regenerate_ssh_host_keys.service"
				echo -e "${GREEN}SSH host keys remains but will be regenerated on first boot.${NOCOLOR}"
			fi
		else
		# Key regeneration relies on using the host to regenerate the keys
			if ! command -v ssh-keygen &> /dev/null; then
				echo -e "${RED}Cannot regenerated SSH keys on first boot and cannot locate ssh-keygen command --> keeping old keys!${NOCOLOR}"
			else
				if [ -c /dev/hwrng ]; then dd if=/dev/hwrng of=/dev/urandom count=1 bs=4096 status=none; fi
				rm -f "$mountdir"/etc/ssh/ssh_host_*_key*
				echo -e "${GREEN}Regenarting SSH host keys.${NOCOLOR}"
				ssh-keygen -A -f "$mountdir" > /dev/null
			fi
		fi
	# Check if dropbear is enabled
	elif [[ -f "$mountdir/etc/init.d/dropbear" ]]; then
		# Key regeneration relies on using the host to regenerate the keys
		if ! command -v dropbearkey &> /dev/null; then
			echo -e "${RED}Cannot locate dropbearkey command --> keeping old keys!${NOCOLOR}"
		else
			rm -f "$mountdir"/etc/dropbear/dropbear_*_host_key
			echo -e "${GREEN}Regenarting Dropbear keys.${NOCOLOR}"
			dropbearkey -t rsa -f "$mountdir"/etc/dropbear/dropbear_rsa_host_key > /dev/null
			dropbearkey -t ecdsa -f "$mountdir"/etc/dropbear/dropbear_ecdsa_host_key > /dev/null
			dropbearkey -t ed25519 -f "$mountdir"/etc/dropbear/dropbear_ed25519_host_key > /dev/null
		fi
	fi

  # if raspi-config use, make sure it doesn't fill up an entire SD card partition
  # allows for raw clones across different manufacturers
  #if [ -f "$mountdir/usr/lib/raspi-config/init_resize.sh" ]; then
    # shellcheck disable=SC2016
  #  sed -i 's#TARGET_END=$((ROOT_DEV_SIZE - 1))#TARGET_END=$((ROOT_DEV_SIZE / 100 * 92))#' \
  #    "$mountdir/usr/lib/raspi-config/init_resize.sh"
  #fi

  # unmount filesystem image
  umount "$mountdir"
fi

#Make sure filesystem is ok
checkFilesystem

if ! minsize=$(resize2fs -P "$loopback"); then
	rc=$?
	echo -e "${RED}resize2fs failed with rc $rc${NOCOLOR}"
	exit 10
fi
minsize=$(cut -d ':' -f 2 <<< "$minsize" | tr -d ' ')
logVariables $LINENO currentsize minsize
if [[ $currentsize -eq $minsize ]]; then
  echo -e "${RED}Image already shrunk to smallest size${NOCOLOR}"
  exit 11
fi

#Add some free space to the end of the filesystem
extra_space=$(($currentsize - $minsize))
logVariables $LINENO extra_space
for space in 5000 1000 100; do
  if [[ $extra_space -gt $space ]]; then
    minsize=$(($minsize + $space))
    break
  fi
done
logVariables $LINENO minsize

#Shrink filesystem
echo -e "${GREEN}Shrinking filesystem${NOCOLOR}"
# shellcheck disable=SC2086
resize2fs -p "$loopback" $minsize
rc=$?
if (( $rc )); then
  echo -e "${RED}resize2fs failed with rc $rc${NOCOLOR}"
  mount "$loopback" "$mountdir"
  mv "$mountdir/etc/rc.local.bak" "$mountdir/etc/rc.local"
  umount "$mountdir"
  losetup -d "$loopback"
  exit 12
fi
sleep 1

#Shrink partition
partnewsize=$(($minsize * $blocksize))
newpartend=$(($partstart + $partnewsize))
logVariables $LINENO partnewsize newpartend
parted -s -a minimal "$img" rm "$partnum"
rc=$?
if (( $rc )); then
	echo -e "${RED}parted failed with rc $rc${NOCOLOR}"
	exit 13
fi

parted -s "$img" unit B mkpart "$parttype" "$partstart" "$newpartend"
rc=$?
if (( $rc )); then
	echo -e "${RED}parted failed with rc $rc${NOCOLOR}"
	exit 14
fi

#Truncate the file
echo -e "${GREEN}Shrinking image${NOCOLOR}"
endresult=$(parted -ms "$img" unit B print free)
rc=$?
if (( $rc )); then
	echo -e "${RED}parted failed with rc $rc${NOCOLOR}"
	exit 15
fi

endresult=$(tail -1 <<< "$endresult" | cut -d ':' -f 2 | tr -d 'B')
logVariables $LINENO endresult
truncate -s "$endresult" "$img"
rc=$?
if (( $rc )); then
	echo -e "${RED}truncate failed with rc $rc${NOCOLOR}"
	exit 16
fi

# Using zerofree
if [[ $zerofree == true ]]; then
	# Check is zerofree is already installed
	if ! command -v "zerofree" >/dev/null 2>&1; then
		echo -e "${RED}ZEROFREE is not installed!${NOCOLOR}"
		while true
		do
			read -r -p $'\e[1;31m Would you like me to install zerofree? [Y/n]? -> \e[0m'
			# The following line is for the prompt to appear on a new line.
			if [[ $REPLY =~ ^[YyNn]$ ]] ; then
				echo
				echo
				break
			fi
		done
		if [[ $REPLY =~ ^[Yy]$ ]] ; then
			echo -e "${GREEN}Installing zerofree${NOCOLOR}"
			sudo apt-get install -y zerofree
		else
			echo -e "${RED}Cannot apply zerofree - skipping${NOCOLOR}"
			echo ""
		fi
	fi
	if command -v "zerofree" >/dev/null 2>&1; then
		#Zero out the freespace (this code is from here: https://github.com/shatteredsword/PiShrink/commit/ed6de32a981748056fa26a41f63495264ccce300)
		echo -e "${GREEN}Zeroing free space${NOCOLOR}"
		LOOP_DEV=$(losetup -f)
		losetup "$LOOP_DEV" -P "$img"
		if [[ $verbose == true ]]; then
			zerofree -v "${LOOP_DEV}"p2
		else
			zerofree "${LOOP_DEV}"p2
		fi
		rc=$?
		if (( rc )); then
			echo -e "${RED}Zerofree failed with rc $rc - skipping"
		fi
		losetup -d "$LOOP_DEV"
	fi
fi

# handle compression
if [[ -n $ziptool ]]; then
	options=""
	if [[ $parallel == true ]]; then
		options="${ZIP_PARALLEL_OPTIONS[$ziptool]}"
		[[ $verbose == true ]] && options="$options -v" # add verbose flag if requested
		parallel_tool="${ZIP_PARALLEL_TOOL[$ziptool]}"
		echo -e "${GREEN}Using $parallel_tool on the shrunk image${NOCOLOR}"
		# shellcheck disable=SC2086
		if ! $parallel_tool ${options} "$img"; then
			rc=$?
			echo -e "${RED}$parallel_tool failed with rc $rc${NOCOLOR}"
			exit 18
		fi

	else # sequential
		[[ "$ziptool" == "gzip" ]] && options="-9"
		[[ $verbose == true ]] && options="$options -v" # add verbose flag if requested
		echo -e "${GREEN}Using $ziptool on the shrunk image${NOCOLOR}"
		# shellcheck disable=SC2086
		if ! $ziptool ${options} "$img"; then
			rc=$?
			echo -e "${RED}$ziptool failed with rc $rc${NOCOLOR}"
			exit 19
		fi
	fi
	img=$img.${ZIPEXTENSIONS[$ziptool]}
fi

aftersize="$(du -h "$img" | cut -f -1)"
logVariables $LINENO aftersize

echo -e "${GREEN}Shrunk $img from $beforesize to $aftersize${NOCOLOR}"
