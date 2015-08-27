#!/bin/bash

mount-partition-usage()
{
    cat <<EOF
mount-partition disk-image.raw
  # lists the partitions in the image

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

EOF
}

mount-partition()
{
    :
}

mount-partition()
{
    :
}
