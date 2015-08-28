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

list-partitions()
{
    thecmd=( parted "$1" unit B print )
    echo "Listing partitions with the command: \"${thecmd[*]}\""
    "${thecmd[@]}"
}

mount-partition()
{
    case "$#" in
	1)  list-partitions "$@" ;;
	2)  attach-partition "$@" ;;
	3)  mount-partition "$@" ;;
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
