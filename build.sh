#!/bin/bash

# exit if any command (or subcommand) returns 1. to disable: set +e
set -e

if [ ${EUID} -ne 0 ]; then
  echo "this tool must be run as root ;3"
  exit 1
fi

# =================== #
#    CONFIGURATION    #
# =================== #

# When true, script will drop into a chroot shell at the end to inspect the
# bootstrapped system
if [ -z "$DEBUG" ]; then
    DEBUG=false
fi
# Try to get version string from Git
VERSION="$(git tag -l --contains HEAD)"
if [ -z "$RELEASE" ]; then
    # We append the date, since otherwise our loopback devices will
    # be broken on multiple runs if we use the same image name each time.
    VERSION="git@$(git log --pretty=format:'%h' -n 1)_$(date +%s)"
fi
# Make sure we have a version string, if not use the current date
if [ -z "$VERSION" ]; then
    VERSION="$(date +%s)"
fi
# Size of target SD card in MB
if [ -z "$IMAGESIZE" ]; then
    IMAGESIZE="4000"
fi
# Size of /boot partition
if [ -z "$BOOTSIZE" ]; then
    BOOTSIZE="64M"
fi
# Debian version
if [ -z "$DEB_RELEASE" ]; then
    DEB_RELEASE="wheezy"
fi
if [ -z "$DEFAULT_DEB_MIRROR" ]; then
    DEFAULT_DEB_MIRROR="http://mirrordirector.raspbian.org/raspbian"
fi
# Whether to use a local debian mirror (e.g. via 'apt-cacher-ng')
if [ -z "$USE_LOCAL_MIRROR" ]; then
    USE_LOCAL_MIRROR=false
fi
if [ -z "$LOCAL_DEB_MIRROR" ]; then
    LOCAL_DEB_MIRROR="http://localhost:3142/archive.raspbian.org/raspbian"
fi
if $USE_LOCAL_MIRROR; then
    DEB_MIRROR=$LOCAL_DEB_MIRROR
else
    DEB_MIRROR=$DEFAULT_DEB_MIRROR
fi
# Path to authorized SSH key, exported for scripts/04-users
if [ -z "$SSH_KEY" ]; then
    SSH_KEY="~/.ssh/id_rsa.pub"
fi
export SSH_KEY
# keyring for rasbian packages
if [ -z "$RASBIAN_KEY_URL" ]; then
    RASBIAN_KEY_URL="http://archive.raspbian.org/raspbian.public.key"
fi

# -------------------------------------------------------------------------- #

# Path to build directory, by default a temporary directory
echo "Creating temporary directory..."
BUILD_ENV=$(mktemp -d) 
echo "Temporary directory created at $BUILD_ENV"

BASE_DIR="$(dirname $0)"
SCRIPT_DIR="$(readlink -m $BASE_DIR)"
LOG="${SCRIPT_DIR}/buildlog_${VERSION}.txt"
IMG="${SCRIPT_DIR}/spreadpi_${VERSION}.img"
SRCIMG_ROOTFS="${BUILD_ENV}/srcmntroot"
SRCIMG_BOOTFS="${SRCIMG_ROOTFS}/boot"
DELIVERY_DIR="$SCRIPT_DIR/delivery"
rootfs="${BUILD_ENV}/rootfs"
bootfs="${rootfs}/boot"
QEMU_ARM_STATIC="/usr/bin/qemu-arm-static"

echo "Creating log file $LOG"
touch "$LOG" 
echo "Using mirror $DEB_MIRROR" | tee --append "$LOG"

# Create build dir
echo "Create directory $BUILD_ENV" | tee --append "$LOG"
mkdir -p "${BUILD_ENV}" 

# Install dependencies
for dep in  binfmt-support qemu qemu-user-static kpartx lvm2 dosfstools unzip; do
  problem=$(dpkg -s $dep|grep installed) 
  echo "Checking for $dep: $problem" | tee --append "$LOG"
  if [ "" == "$problem" ]; then
    echo "No $dep. Setting up $dep" | tee --append "$LOG"
    apt-get --force-yes --yes install "$dep" &>> "$LOG" 
  fi
done

function cleanup()
{
	# don't exit-on-error during cleanup!
	set +e
	
	# Unmount
	if [ ! -z ${SRCIMG_BOOTFS} ]; then
		umount -l ${SRCIMG_BOOTFS} &>> $LOG
	fi
	umount -l ${SRCIMG_ROOTFS} &>> $LOG 
	if [ ! -z ${bootp} ]; then
		umount -l ${bootp} &>> $LOG
	fi
	umount -l ${rootfs}/usr/src/delivery &>> $LOG 
	umount -l ${rootfs}/dev/pts &>> $LOG 
	umount -l ${rootfs}/dev &>> $LOG 
	umount -l ${rootfs}/sys &>> $LOG 
	umount -l ${rootfs}/proc &>> $LOG 
	umount -l ${rootfs} &>> $LOG 
	if [ ! -z ${rootp} ]; then
		umount -l ${rootp} &>> $LOG 
	fi

	# Remove build directory
	if [ ! -z "$BUILD_ENV" ]; then
		echo "Remove directory $BUILD_ENV ..." | tee --append "$LOG"
		rm -rf "$BUILD_ENV"
	fi

	# Remove partition mappings
	echo "sleep 10 seconds before removing loopbacks..." | tee --append "$LOG"
	sleep 10
	if [ ! -z ${lodevice} ]; then
		echo "remove $lodevice ..." | tee --append "$LOG"
		kpartx -vd ${lodevice} &>> $LOG 
		losetup -d ${lodevice} &>> $LOG 
	fi
	
	if [ ! -z "$1" ] && [ "$1" == "-exit" ]; then
		echo "Error occurred! Read $LOG for details" | tee --append "$LOG"
	fi
}

# if anything exits with an error code, call cleanup
trap "cleanup -exit" EXIT

[ -d ${BUILD_ENV} ] || exit 1

# Do we have an img to mogrify?
if [ -z "$1" ]; then
	if [ ! -e 'wheezy-rasbian.img' ]; then
		echo "You didn't supply an img to modify!"
		echo "Usage: $0 /path/to/...-rasbian.img"
		echo "Sleeping for 5, then downloading"
		echo "http://downloads.raspberrypi.org/raspbian_latest"
		echo "into ${BUILD_ENV} , then unzipping to working directory. "
		echo "Hit Ctrl+C to cancel!"
		sleep 5
		wget --continue http://downloads.raspberrypi.org/raspbian_latest \
				-O "${BUILD_ENV}/wheezy-rasbian.zip"
		echo "Unzipping..."
		unzip "${BUILD_ENV}/wheezy-rasbian.zip" -d "${BUILD_ENV}"
		echo "Moving .img to working directory..."
		if [ $(ls "${BUILD_ENV}/*.img" | wc -l) -eq 1 ]; then
			mv "${BUILD_ENV}/*.img" "$(pwd)"'/wheezy-rasbian.img'
		else
			echo "None or multiple .img files found in ${BUILD_ENV} :"
			ls "${BUILD_ENV}/*.img"
			echo "...aborting!"
			exit 1
		fi
	fi
	SRCIMG="$(pwd)"'/wheezy-rasbian.img'
else
	SRCIMG="$1"
fi

# Create src image root fs mount dirs
echo "Create source image mount points $SRCIMG_ROOTFS and $SRCIMG_BOOTFS" | tee --append "$LOG"
mkdir -p "${SRCIMG_ROOTFS}" "${SRCIMG_BOOTFS}" 
# Create dest image root fs dirs
echo "Create dest image directories $rootfs and $bootfs" | tee --append "$LOG"
mkdir -p "${rootfs}" "${bootfs}" 

# Set up loopback devices
echo "Creating a loopback device for $SRCIMG..." | tee --append "$LOG"
srclodevice=$(losetup -f --show ${SRCIMG})
echo "Loopback $srclodevice created." | tee --append "$LOG"
echo "Removing $srclodevice ..." | tee --append "$LOG"
dmsetup remove_all &>> "$LOG"
losetup -d "${srclodevice}" &>> "$LOG"
echo "Creating device map for $SRCIMG ... " | tee --append "$LOG"
srcdevice=$(kpartx -va ${SRCIMG} | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1)
srcdevice="/dev/mapper/${srcdevice}"
echo "Device map created at $srcdevice" | tee --append "$LOG"
SRC_BOOTP="${srcdevice}p1"
SRC_ROOTP="${srcdevice}p2"
# make sure SRC_{B,R}OOTP exists
[ ! -e "$SRC_BOOTP" ] && exit 1
[ ! -e "$SRC_ROOTP" ] && exit 1
# Mount src img
echo "Mounting $SRC_ROOTP to $SRCIMG_ROOTFS ..." | tee --append "$LOG"
mount ${SRC_ROOTP} ${SRCIMG_ROOTFS} &>> "$LOG"
echo "Mounting $SRC_BOOTP to $SRCIMG_BOOTFS ..." | tee --append "$LOG"
mount ${SRC_BOOTP} ${SRCIMG_BOOTFS} &>> "$LOG"

# Create image file
echo "Initializing image file $IMG" | tee --append "$LOG"
dd if=/dev/zero of="${IMG}" bs=1MB count=$IMAGESIZE &>> "$LOG"
echo "Creating a loopback device for $IMG..." | tee --append "$LOG"
lodevice=$(losetup -f --show ${IMG})
echo "Loopback $lodevice created." | tee --append "$LOG"
# Setup up /boot and /root partitions
# TODO: fdisk always returns 1, so we can't use '|| exit 1'
# TODO: find other way to verify partitions made (maybe fdisk | wc -l)
set +e
echo "Creating partitions on $IMG..." | tee --append "$LOG"
echo "
n
p
1
 
+${BOOTSIZE}
t
c
n
p
2


w
" | fdisk ${lodevice} &>> "$LOG"
set -e
# Set up loopback devices
echo "Removing $lodevice ..." | tee --append "$LOG"
dmsetup remove_all &>> "$LOG" 
losetup -d ${lodevice} &>> "$LOG"
echo "Creating device map for $IMG ... " | tee --append "$LOG"
device=$(kpartx -va ${IMG} | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1)
device="/dev/mapper/${device}"
echo "Device map created at $device" | tee --append "$LOG"
bootp="${device}p1"
rootp="${device}p2"
# Do bootp and rootp exist?
echo "Checking if $bootp and $rootp exist..." | tee --append "$LOG"
[ ! -e "$bootp" ] && exit 1
[ ! -e "$rootp" ] && exit 1
# Create file systems
echo "Creating filesystems on $IMG ..." | tee --append "$LOG"
mkfs.vfat ${bootp} &>> "$LOG"
mkfs.ext4 ${rootp} &>> "$LOG"
# mount created filesystems
echo "Mounting $rootp to $rootfs ..." | tee --append "$LOG"
mount ${rootp} ${rootfs} &>> "$LOG"
echo "Mounting $bootp to $bootfs ..." | tee --append "$LOG"
mkdir -p ${bootfs} &>> "$LOG"
mount ${bootp} ${bootfs} &>> "$LOG"

# Copy img contents
echo "Copying $SRCIMG_ROOTFS filesystem to $rootfs..." | tee --append "$LOG"
rsync --archive "$SRCIMG_ROOTFS/" "$rootfs" &>> "$LOG"
echo "Copying $SRCIMG_BOOTFS filesystem to $bootfs..." | tee --append "$LOG"
rsync --archive "$SRCIMG_BOOTFS/" "$bootfs" &>> "$LOG"

# Mount pseudo file systems
echo "Mounting pseudo filesystems in $rootfs ..." | tee --append "$LOG"
mount -t proc none ${rootfs}/proc
mount -t sysfs none ${rootfs}/sys
mount -o bind /dev ${rootfs}/dev
mount -o bind /dev/pts ${rootfs}/dev/pts

# Mount our delivery path
echo "Mounting $DELIVERY_DIR in $rootfs ..." | tee --append "$LOG"
mkdir -p ${rootfs}/usr/src/delivery 
mount -o bind ${DELIVERY_DIR} ${rootfs}/usr/src/delivery 

# copy qemu-arm so we can chroot
echo "Copying $QEMU_ARM_STATIC into $rootfs" | tee --append "$LOG"
cp "$QEMU_ARM_STATIC" "${rootfs}/usr/bin/" &>> $LOG 
# modify etc/ld.so.preload (maybe only needed for interactive bash?)
mv "${rootfs}/etc/ld.so.preload" "${rootfs}/etc/ld.so.preload.old"
sed 's/^/#/' "${rootfs}/etc/ld.so.preload.old" \
		> "${rootfs}/etc/ld.so.preload"
		
# Configure Debian release and mirror
echo "Configure apt in $rootfs..." | tee --append "$LOG"
echo "deb ${DEB_MIRROR} ${DEB_RELEASE} main contrib non-free
" > "${rootfs}/etc/apt/sources.list"
# make sure the file we just wrote exists still
[ ! -e "${rootfs}/etc/apt/sources.list" ] && cleanup -exit

# Configure Hostname
echo "Writing $rootfs/etc/hostname ..." | tee --append "$LOG"
echo "spreadpi" > "$rootfs/etc/hostname"
[ ! -e "$rootfs/etc/hostname" ] && cleanup -exit

# TODO: What does this do?
echo "Writing $rootfs/debconf.set ..." | tee --append "$LOG"
echo "console-common	console-data/keymap/policy	select	Select keymap from full list
console-common	console-data/keymap/full	select	us
" > "$rootfs/debconf.set"
[ ! -e "$rootfs/debconf.set" ] && exit 1

# Run user-defined scripts from DELIVERY_DIR/scripts
echo "Running custom bootstrapping scripts" | tee --append "$LOG"
for path in $rootfs/usr/src/delivery/scripts/*; do
		script=$(basename "$path")
    echo $script | tee --append "$LOG"
    DELIVERY_DIR=/usr/src/delivery LANG=C chroot ${rootfs} "/usr/src/delivery/scripts/$script" &>> $LOG 
done

# Configure default mirror
echo "Writing $rootfs/apt/sources.list again, using non-local mirror..." | tee --append "$LOG"
echo "deb ${DEFAULT_DEB_MIRROR} ${DEB_RELEASE} main contrib non-free
" > "$rootfs/etc/apt/sources.list"
[ ! -e "$rootfs/etc/apt/sources.list" ] && cleanup -exit

# Clean up
echo "Cleaning up bootstrapped system" | tee --append "$LOG"
echo "#!/bin/bash
aptitude update 
aptitude clean 
apt-get clean 
rm -f cleanup 
" > "$rootfs/cleanup"
chmod +x "$rootfs/cleanup"
LANG=C LC_ALL=C chroot ${rootfs} /cleanup &>> $LOG 

if $DEBUG; then
    echo "Dropping into shell" | tee --append "$LOG"
    LANG=C LC_ALL=C PS1="\u@CHROOT\w# " chroot ${rootfs} /bin/bash
fi

# Put back the default ld.so.preload (hopefully no processes touched it
# in the meanwhile
mv "${rootfs}/etc/ld.so.preload.old" "${rootfs}/etc/ld.so.preload"

# okay, don't care about errors anymore
set +e

# Kill remaining qemu-arm-static processes
echo "Killing remaining qemu-arm-static processes..." | tee --append "$LOG"
pkill -9 -f ".*qemu-arm-static.*"

# Synchronize file systems
echo "sync filesystems, sleep 15 seconds" | tee --append "$LOG"
sync
sleep 15

cleanup

echo "Successfully created image ${IMG}" | tee --append "$LOG"
exit 0
