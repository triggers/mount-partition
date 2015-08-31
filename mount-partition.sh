#!/bin/bash

mount-partition-usage()
{
    cat <<EOF
This file is meant to be sourced, and then the functions below
called directly.

mount-partition disk-image.raw
  # lists the partitions in the image

mount-partition {--force} /path/to/disk-image.raw N
  # mount partition, but do not mount file system

mount-partition {--force} /path/to/disk-image.raw N /path/to/mount-point
  # mounts partition number N at mount-point

umount-partition {--force} /path/to/disk-image.raw N
  # or
umount-partition {--force} /path/to/mount-point
  # unmounts partition number N

Information is kept in these 2 files for cleanup and sanity checks:
  /path/to/disk-image.raw.mount-info
  /path/to/mount-point.mount-info
  /tmp/mount-partition.info

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
	loopdev="$(losetup --find --show "$imageFile" -o "$start" --sizelimit "$size")"
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
    mount "$loopDev" "$mountPoint"
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
