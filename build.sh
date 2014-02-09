#!/bin/bash

# exit if any command (or subcommand) returns 1. to disable: set +e
set -e

if [ ${EUID} -ne 0 ]; then
  echo "this tool must be run as root"
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
echo "Using mirror $DEB_MIRROR" | tee --append "$LOG"
# Path to authorized SSH key, exported for scripts/04-users
if [ -z "$SSH_KEY" ]; then
    SSH_KEY="~/.ssh/id_rsa.pub"
fi
export SSH_KEY
# keyring for rasbian packages
if [ -z "$RASBIAN_KEY_URL" ]; then
    RASBIAN_KEY_URL="http://archive.raspbian.org/raspbian.public.key"
fi
# Do we have an img to mogrify?
if [ -z "$1" ] && [ ! -e '2014-01-07-wheezy-rasbian.img' ]; then
	echo "You didn't supply an img to modify!"
	echo "Usage: $0 /path/to/...-rasbian.img"
	echo "Sleeping for 5, then downloading"
	echo "Downloading http://downloads.raspberrypi.org/raspbian_latest"
	echo "into the working directory. Hit Ctrl+C to cancel!"
	sleep 5
	wget --continue http://downloads.raspberrypi.org/raspbian_latest -O \
			'2014-01-07-wheezy-rasbian.img'
	echo "Unzipping..."
	unzip '2014-01-07-wheezy-rasbian.img'
	SRCIMG="$(pwd)"'/2014-01-07-wheezy-rasbian.img'
else
	SRCIMG="$1"
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

# Install dependencies
for dep in binfmt-support qemu qemu-user-static debootstrap kpartx lvm2 dosfstools; do
  echo "Checking for $dep: $problem" | tee --append "$LOG"
  problem=$(dpkg -s $dep|grep installed) 
  if [ "" == "$problem" ]; then
    echo "No $dep. Setting up $dep" | tee --append "$LOG"
    apt-get --force-yes --yes install "$dep" &>> "$LOG" 
  fi
done

# Create build dir
echo "Create directory $BUILD_ENV" | tee --append "$LOG"
mkdir -p "${BUILD_ENV}" 

# Create src image root fs mount dir
echo "Create image mount point $rootfs" | tee --append "$LOG"
mkdir -p "${SRCIMG_ROOTFS}" 
echo "Create image mount point $bootfs" | tee --append "$LOG"
mkdir -p "${SRCIMG_BOOTFS}" 

# Create dest image root fs mount dir
echo "Create image mount point $rootfs" | tee --append "$LOG"
mkdir -p "${rootfs}" 
echo "Create image mount point $bootfs" | tee --append "$LOG"
mkdir -p "${bootfs}" 

function cleanup()
{
	# Make sure we're not in the mounted filesystem anymore, or unmount -l would silently keep waiting!
	echo "Change working directory to ~ ..." | tee --append "$LOG"
	cd ~ 

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
	echo "sleep 30 seconds..." | tee --append "$LOG"
	sleep 30
	if [ ! -z ${lodevice} ]; then
		echo "remove $lodevice ..." | tee --append "$LOG"
		kpartx -vd ${lodevice} &>> $LOG 
		losetup -d ${lodevice} &>> $LOG 
	fi
	
	if [ ! -z "$1" ] && [ "$1" == "-exit" ]; then
		echo "Error occurred! Read $LOG for details" | tee --append "$LOG"
		exit 1
	fi
}



# Mount pseudo file systems
echo "Mounting pseudo filesystems in $rootfs ..." | tee --append "$LOG"
mount -t proc none ${rootfs}/proc || cleanup -exit
mount -t sysfs none ${rootfs}/sys || cleanup -exit
mount -o bind /dev ${rootfs}/dev || cleanup -exit
mount -o bind /dev/pts ${rootfs}/dev/pts || cleanup -exit

# Mount our delivery path
echo "Mounting $DELIVERY_DIR in $rootfs ..." | tee --append "$LOG"
mount -o bind ${DELIVERY_DIR} ${rootfs}/usr/src/delivery || cleanup -exit

# Second stage, using chroot and qemu-arm from the inside
echo "Copying $QEMU_ARM_STATIC into $rootfs" | tee --append "$LOG"
cp "$QEMU_ARM_STATIC" "${rootfs}/usr/bin/" &>> $LOG || cleanup -exit

# Configure Debian release and mirror
echo "Configure apt in $rootfs..." | tee --append "$LOG"
echo "deb ${DEB_MIRROR} ${DEB_RELEASE} main contrib non-free
" > "${rootfs}/etc/apt/sources.list"
# make sure the file we just wrote exists still
[ ! -e "${rootfs}/etc/apt/sources.list" ] && cleanup -exit

# Configure Raspberry Pi boot options
BOOT_CONF="${rootfs}/boot/cmdline.txt"
echo "Writing $BOOT_CONF ..." | tee --append "$LOG"
rm -f $BOOT_CONF
touch $BOOT_CONF
echo -n "dwc_otg.lpm_enable=0 console=ttyAMA0,115200" >> $BOOT_CONF
echo -n "kgdboc=ttyAMA0,115200 console=tty1" >> $BOOT_CONF
echo "root=/dev/mmcblk0p2 rootfstype=ext4 rootwait" >> $BOOT_CONF
[ ! -e "$BOOT_CONF" ] && cleanup -exit

# Set up mount points
echo "Writing $rootfs/etc/fstab ..." | tee --append "$LOG"
echo "proc	/proc	proc	defaults	0	0
/dev/mmcblk0p1	/boot	vfat	defaults	0	0
" > "$rootfs/etc/fstab"
[ ! -e "$rootfs/etc/fstab" ] && cleanup -exit

# Configure Hostname
echo "Writing $rootfs/etc/hostname ..." | tee --append "$LOG"
echo "spreadpi" > "$rootfs/etc/hostname"
[ ! -e "$rootfs/etc/hostname" ] && cleanup -exit

# Configure networking
echo "Writing $rootfs/etc/network/interfaces ..." | tee --append "$LOG"
echo "auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
" > "$rootfs/etc/network/interfaces"
[ ! -e "$rootfs/etc/network/interfaces" ] && cleanup -exit

# Configure loading of proprietary kernel modules
echo "Writing $rootfs/etc/modules ..." | tee --append "$LOG"
echo "vchiq
snd_bcm2835
" >> "$rootfs/etc/modules"
[ ! -e "$rootfs/etc/modules" ] && cleanup -exit

# TODO: What does this do?
echo "Writing $rootfs/debconf.set ..." | tee --append "$LOG"
echo "console-common	console-data/keymap/policy	select	Select keymap from full list
console-common	console-data/keymap/full	select	us
" > "$rootfs/debconf.set"
[ ! -e "$rootfs/debconf.set" ] && cleanup -exit

# Run user-defined scripts from DELIVERY_DIR/scripts
echo "Running custom bootstrapping scripts" | tee --append "$LOG"
for path in $rootfs/usr/src/delivery/scripts/*; do
		script=$(basename "$path")
    echo $script | tee --append "$LOG"
    DELIVERY_DIR=/usr/src/delivery LANG=C chroot ${rootfs} "/usr/src/delivery/scripts/$script" &>> $LOG || cleanup -exit
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
LANG=C chroot ${rootfs} /cleanup &>> $LOG || cleanup -exit

if $DEBUG; then
    echo "Dropping into shell" | tee --append "$LOG"
    LANG=C chroot ${rootfs} /bin/bash
fi

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
