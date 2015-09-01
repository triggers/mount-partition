#!/bin/bash

# What this code does is relatively simple, but worth encapsulating
# because it is code that must run as root that can be a little
# confusing and a little dangerous.

# In short, the code mounts a file system from a partition inside an
# image file. This only requires a few steps: (1) find the location
# of the partition inside the file, (2) attach that part of the file
# to a loop block device, (3) mount that loop device to a mount point.

# Other solutions already exist that encapsulate steps (1) and (2),
# such as: kpart, qemu-nbd, and even recent versions of the Linux
# kernel itself using just losetup(!).  A mount command with a '-o
# loop' option encapsulates steps (2) and (3).  (Plus there already
# have been at least two hacks done locally.)  Unfortunately, all have
# disadvantages, or we have had unexplained reliability problems with
# them, and none encapsulates all three steps.  (TODO: expand this
# paragraph somewhere to explain the disadvantages)

# One thing that perhaps makes such code confusing is that later the
# mount must be undone, and this requires root, and it is possible
# that the code will undo a mount of something else running on the OS
# (or its nested containers).  So it is necessary to keep enough
# information when mounting to safely unmount and detach everything
# later.

# An important insight that made the code below simpler is that the
# losetup command has an "--associated" option that makes it easy to
# find the loop device mapping a particular partition.  Therefore, if
# the calling code remembers the path of the image file and the
# partition number, it is easy find the loop device.  From the loop
# device, it is easy to find mount points from /proc/mounts.

# To keep things portable, the code below relies only on these commands
# and options:
# 
#     sfdisk -d "$imageFile1"
#     parted "$imageFile" unit B print
#     parted -s -m "$imageFile" unit B print
#     losetup --associated "$imageFile" --offset "$start"
#     losetup --find --show "$imageFile" --offset "$start" --sizelimit "$size"
#     mount "$loopDev" "$mountPoint"
#     umount "$loopDev"

# (A mistake made on the earlier version of the code was to save the
#  loop device information and use it later.  The problem this raised
#  was that it is difficult to verify that events outside the
#  process's control have not made the information invalid.  The the
#  first attempt to verify only worked with some versions of losetup.
#  It turned out to be easier to regenerate the loop device
#  information than to verify that saved information is correct! But
#  that is only true if regenerating is scripted...as it is below.)

mount-partition-usage()
{
    cat <<EOF
This file is meant to be sourced, and then the functions below
called directly.

MOUNT-PARTITION
===============

mount-partition disk-image.raw
  # lists the partitions in the image

mount-partition /path/to/disk-image.raw N
  # mount partition, but do not mount file system

mount-partition /path/to/disk-image.raw N /path/to/mount-point
  # mounts partition number N at mount-point


UMOUNT-PARTITION
===============

umount-partition /path/to/disk-image.raw
  # detach any loop devices for this image after removing any mounts

umount-partition /path/to/disk-image.raw N
  # detach any loop devices for this partition after removing any mounts

umount-partition /path/to/disk-image.raw N /path/to/mount-point
  # same as above, but verify that it is mounted to mount-point first as a sanity check
  # (so multiple processes can safely mount the partition read-only)

umount-partition /path/to/mount-point
  # unmounts loop device from mount-point and detaches the image file

For debugging, the script can be called with "mount*" or "umount*"
as the first parameter.  One of the above functions is then called
with the remaining arguments.

EOF
}

do-list-partitions()
{
    imageFile="$1"
    [ -f "$imageFile" ] || {
	echo "First parameter must an existing image file. Exiting." 1>&2
	exit 1
    }
    thecmd=( parted "$imageFile" unit B print )
    echo "Listing partitions with the command: \"${thecmd[*]}\""
    "${thecmd[@]}"
}

partition-info-from-parted()
{
    imageFile="$1"
    partionNumber="$2"
    parted -s -m "$1" unit B print | (
	# example output:
	# BYT;
	# /media/sdc1/images/win-2012.raw:32212254720B:file:512:512:msdos::;
	# 1:1048576B:368050175B:367001600B:ntfs::boot;
	# 2:368050176B:32211206143B:31843155968B:ntfs::;
	pattern="$partionNumber:*"
	while read ln; do
	    if [[ "$ln" == $pattern ]]; then
		ln="${ln//B/}" # get rid of the B suffixes
		IFS=: read n start end size fs rest <<<"$ln"
		echo "$start $size"
		exit 0 # (partition not found) exit from subshell
	    fi
	done
	echo "Partition number $partionNumber not found from parted" 1>&2
	exit 1 # (partition not found) exit from subshell
    )
}

partition-info-from-sfdisk()
{
    imageFile="$1"
    partionNumber="$2"
    sfdisk -d "$1" | (
	# example output:
	# label: dos
	# label-id: 0x0188d0f2
	# device: builddirs/friday1/win-2012.raw
	# unit: sectors
	# ./win-2012.raw1 : start=        2048, size=      716800, type=7, bootable
	# ./win-2012.raw2 : start=      718848, size=    62193664, type=7
	n=0
	while read ln; do
	    if [[ "$ln" == *start=*size=* ]]; then
		n=$(( n + 1 ))
		if [ "$n" -eq "$partionNumber" ]; then
		    ln="${ln##*:}"
		    IFS=', ' read startLabel start sizeLabel size rest <<<"$ln"
		    echo "$(( 512 * start )) $(( 512 * size ))"
		    exit 0 # (partition not found) exit from subshell
		fi
	    fi
	done
	echo "Partition number $partionNumber not found from sfdisk" 1>&2
	exit 1 # (partition not found) exit from subshell
    )
}

do-attach-partition()
{
    imageFile="$1"
    partionNumber="$2"
    [ -f "$imageFile" ] || {
	echo "First parameter must an existing image file. Exiting." 1>&2
	exit 1
    }
    [ "$partionNumber" != "" ] && [ "${partionNumber//[0-9]/}" = "" ] || {
	echo "Second parameter must a number. Exiting." 1>&2
	exit 1
    }
    pinfo="$(partition-info-from-parted "$imageFile" "$partionNumber")" || exit
    sinfo="$(partition-info-from-sfdisk "$imageFile" "$partionNumber")" || exit
    [ "$pinfo" = "$sinfo" ] || {
	echo "Information parsed from sfdisk and parted do not agree. Exiting." 1>&2
	exit 1
    }
    read start size <<<"$pinfo"
    precheck="$(losetup --associated "$imageFile" --offset "$start")"
    if [ "$precheck" != "" ]; then
	loopdev="${precheck%%:*}"
	echo "Reusing exiting mount:" 1>&2
	echo "$precheck" 1>&2
    else
	loopdev="$(losetup --find --show "$imageFile" --offset "$start" --sizelimit "$size")"
	rc="$?"
	[ "$rc" = 0 ] && [[ "$loopdev" == /dev/loop* ]] || {
	    echo "Error occured with losetup command (rc=$rc) or output was unexpected ($loopdev)." 1>&2
	    exit 1
	}
    fi
    echo "$loopdev"
}

do-mount-partition()
{
    imageFile="$1"
    partionNumber="$2"
    mountPoint="$3"
    [ -d "$mountPoint" ] && (
	cd "$mountPoint"
	shopt -s nullglob
	[ "$(echo *)" = "" ]
    ) || {
	echo "Third parameter must be an existing directory that is empty. Exiting." 1>&2
	exit 1
    }
    loopDev="$(do-attach-partition "$imageFile" "$partionNumber")" || exit
    mounts="$(mount | grep ^"$loopDev")"
    [ "$mounts" = "" ] || {
	echo "Exiting without mounting, because the loop device $loopDev is already mounted:" 1>&2
	echo "$mounts"
	exit 1
    }
    mount "$loopDev" "$mountPoint" || {
	echo "The mount command failed ($?). $loopDev is still attached to the image file." 1>&2
	exit 1
    }
}

mount-partition()
{
    case "$#" in
	1)  do-list-partitions "$@" ;;
	2)  do-attach-partition "$@" ;;
	3)  do-mount-partition "$@" ;;
	*)  mount-partition-usage ;;
    esac	    
}

umount-partition()
{
    :
}

if [ "$#" != 0 ]; then
    cmd="$1"
    shift
    case "$cmd" in
	mount) mount-partition "$@" ;; 
	umount) umount-partition "$@" ;;
	*) mount-partition-usage
    esac
fi
