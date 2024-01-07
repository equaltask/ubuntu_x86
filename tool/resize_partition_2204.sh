#!/bin/bash

## This script is to extend root partion to its maximum after you dd from a compressed small image
## Assumption: 
## 1. The 1st partition /dev/sda1 is swap.
## 2. The 2nd partition /dev/sda2 is the root(/) partition
## If Swap is the last partition, we need to
## 1. swapoff -a
## 2. "parted /dev/sda -s rm 3" to delete swap
## 3. "resizepart 2 -4G" (-4G is count from end, and leave 4G for swap partition. how much left depends on system memory size, general rule is (swap size) = (system memory * 2)
## 4. " parted /dev/sda -s 'mkpart primary linux-swap(v1) -4G -0G' "
## 5. mkswap /dev/sda3
## 6. edit /etc/fstab by "sed s%UUID=[0-9a-f-]*.*swap%/dev/sda3\ none\ swap% /etc/fstab"
## 7. swapon -a

#Skip this resize if running on virtual box!
bios_version=$(dmidecode -s bios-version)

if [ $bios_version == VirtualBox ]; then
  echo "Skipping resize due to this running on Virtual Box!"
  exit
fi

LOG_FILE=resize_partition.log
UEFI_PATH=/sys/firmware/efi

#rootfs disk. such as /dev/sda2 or /dev/nvme0n1p2
rootfsDisk=$(df -h / | grep dev | awk '{print $1}')
#rootfs disk id. for parted parameter
rootfsDiskId=${rootfsDisk: -1}

#from rootfs disk name to get boot disk name (/dev/sda or /dev/nvme0n1)
if [[ "$rootfsDisk" =~ "nvme" ]]; then #remove p2
    bootDisk=${rootfsDisk%p*}
elif [[ "$rootfsDisk" =~ "sd" ]]; then #remove last char 2
    bootDisk=${rootfsDisk%?}
else
    echo "rootfs_disk $rootfsDisk not support. Please resize manually!"
    exit
fi

memsize=$(free -m | grep Mem: | awk '{print $2}')
echo "memsize=$memsize MB" >> $LOG_FILE
swapsize=3200
echo "swapsize=$swapsize MB" >> $LOG_FILE
#The swap parition must land on a sector divisible by 8 for maximum performance!
#Therefore, I need to increase swapsize by 1 (which is swapsize2) since we are doing -${swapsize} below.
#What I mean is I need enough room between partition 2 and 3 so parted can line up the
#swap drive correctly!
#The old script did not leave enough room available and the swap was miss aligned!
#you can tell by running "sgdisk -v /dev/nvme0n1" and if it reports nothing then swap is aligned!
swapsize2=$(expr $swapsize \+ 1)

execute_cmd()
{
    if [ -z "$1" ]; then
        echo "execute_cmd incorrect parameter, parameter length is 0" && exit -1 >> $LOG_FILE
    fi

    echo $1 >> $LOG_FILE
    $1 &>> $LOG_FILE
    result=$?

    echo -e "-------command finished (exit code $result)-------\n" >> $LOG_FILE
    if [ $result -ne 0 ]; then
        echo "Command failed! $1" && exit $result >> $LOG_FILE
    fi
}

save_log_file()
{
    cat $LOG_FILE >>  /lib/modules/resize_partition.log
}

set_grub_config()
{
  # ------ Board cpu vendor detect ---------#
  vendor_detect=`cat /proc/cpuinfo | grep vendor_id | awk 'NR==1 {print $3}'`
  # --------- GRUB Settings -------- #
  # DEFAULT options are ones that usually don't change from system to system.
  CFG_GRUB_DEFAULT_OPTS_AMD="rootdelay=120 biosdevname=0 net.ifnames=0 consoleblank=0 noexec=off nosmap nosmep idle=poll reboot=acpi"

  CFG_GRUB_DEFAULT_OPTS_INTEL="rootdelay=120 biosdevname=0 net.ifnames=0 consoleblank=0"
  # ALT options can change from system to system.
  # Only change them if you know what you're doing.
  CFG_GRUB_ALT_OPTS_AMD="iommu=off nomodeset nokaslr"
  CFG_GRUB_ALT_OPTS_INTEL="nomodeset nokaslr"
  # DEBUG settings that could change from system to system.
  CFG_GRUB_DEBUG_OPTS=" "
  #CFG_GRUB_MEM="2048M"  # Forces the kernel boot parameter mem= to this value.
  SYS_MEM=`free -m | grep Mem: | awk '{print $2}'`
  if [ $SYS_MEM -le 4096 ]; then
    CFG_GRUB_MEM="`expr $SYS_MEM \/ 2`M"  # Forces the kernel boot parameter mem= to this value.
  else
    CFG_GRUB_MEM="`expr $SYS_MEM \- 2048`M"
  fi
  CFG_GRUB_TIMEOUT="5"  # Number of seconds for the GRUB boot menu to appear

  if [ $vendor_detect == "AuthenticAMD" ]; then
    opts_tmp="$CFG_GRUB_DEFAULT_OPTS_AMD $CFG_GRUB_DEBUG_OPTS $CFG_GRUB_ALT_OPTS_AMD "
    #set the mem=6144 for MVG.  Mero has 32GB of memory.  Should be plenty of room for tserver beyond the 6144MiB!
    opts="$CFG_GRUB_DEFAULT_OPTS_AMD $CFG_GRUB_DEBUG_OPTS $CFG_GRUB_ALT_OPTS_AMD mem=6144M"
  elif [ $vendor_detect == "GenuineIntel" ]; then
    opts_tmp="$CFG_GRUB_DEFAULT_OPTS_INTEL $CFG_GRUB_ALT_OPTS_INTEL "
    opts="$CFG_GRUB_DEFAULT_OPTS_INTEL $CFG_GRUB_ALT_OPTS_INTEL mem=$CFG_GRUB_MEM"
  fi

  echo "needed grub option: $opts"
  echo "needed grub option: $opts" >> $LOG_FILE
  opts_cur=`cat /etc/default/grub  | grep 'GRUB_CMDLINE_LINUX_DEFAULT=' | awk -F \" '{print $2}' | awk -F\mem '{print $1}'`
  echo "opts_cur=|$opts_cur|"
  echo "opts_tmp=|$opts_tmp|"
  if [[ $opts_cur != $opts_tmp ]]; then
    echo "need updated grub!"
  	sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\".*\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$opts\"/" /etc/default/grub
  	sed -i "s/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=$CFG_GRUB_TIMEOUT/" /etc/default/grub
    execute_cmd "update-grub"
    #sleep 2s
    execute_cmd "reboot -f"
  else
    echo "This Ubuntu grub had been set before!"
    echo "This Ubuntu grub had been set before!" >> $LOG_FILE
    #sleep 2s
  fi
}

extend_root_partition()
{
    echo "System original hard disk and memory info: " >> $LOG_FILE 
    system_info

    #UEFI boot use GPT partition table, which need to fix GPT to use all the space.
    if [ -d "$UEFI_PATH" ]; then
        echo "******** fix the GPT to use all the space, only be valid when not all of the dev space available ******" >> $LOG_FILE
        sgdisk -e $bootDisk
    fi

    echo "************************ extend root partition ********************" >> $LOG_FILE
    if [ -e "$bootDisk" ]; then
        cat <<EOF | parted ---pretend-input-tty $bootDisk
unit MB
resizepart $rootfsDiskId
yes
-${swapsize2}
print all
EOF

        execute_cmd "resize2fs $rootfsDisk"
    fi
}

create_swap()
{
    echo "************************ create swap partition ********************" >> $LOG_FILE
    let swapDiskId=$rootfsDiskId+1
    if [ -e "$bootDisk" ]; then
       #I removed the -s switch since we do not need to do this in sectors.  MB is fine for this operation.
       parted $bootDisk --align minimal "mkpart primary linux-swap(v1) -${swapsize} -0G" >> $LOG_FILE
       if [[ "$bootDisk" =~ "nvme" ]]; then
           execute_cmd "mkswap $bootDiskp$swapDiskId"
           echo "$bootDiskp$swapDiskId none swap   sw  0   0 " >> /etc/fstab
       else
           execute_cmd "mkswap $bootDisk$swapDiskId"
           echo "$bootDisk$swapDiskId none swap   sw  0   0 " >> /etc/fstab
       fi
    fi
    execute_cmd "swapon -a"
}

system_info()
{
    execute_cmd "free -h"
    execute_cmd "df -h"
    execute_cmd "fdisk -l"
}

result_check()
{
    echo "************************ execute result check ********************" >> $LOG_FILE
    execute_cmd "sed -i "/resize_partition_2204.sh/d" /etc/rc.local"
    echo "System new hard disk and memory info: " >> $LOG_FILE
    system_info
}

#set_grub_config
extend_root_partition
create_swap
result_check
save_log_file
