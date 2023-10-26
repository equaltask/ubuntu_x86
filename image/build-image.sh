#!/usr/bin/env bash

TempPath=temp
RootfsPath=$TempPath/rootfs
DownloadPath=$TempPath/download

function help_usage()
{
    echo "command guide:"
    echo "  build-image.sh -b -u 1/0 -h"
    echo "    -b|--build:        build ubuntu image"
    echo "    -u|--rootfs_update: rootfs update manually. 1-mount rootfs, 0-umount rootfs"
    echo "    -h|--help:         help"
    echo #empty line
    echo "modify parameters defined in param.json before run with root"
    echo "As gparted need GUI support, please run in ubuntu-desktop"
    echo "rootfs_update: update/configure rootfs manually with chroot. mounted rootfs path: temp/rootfs"
    echo #empty line
}

function exit_with_error()
{
    echo "${1}..."
    exit 1
}

function chroot_command()
{
    local cmd=$1
    echo "chroot_command: $cmd"
    chroot $RootfsPath /bin/bash -c "$cmd"
}

#param: $1: 1-mount, 0-umount
function mount_running_system()
{
    if [ $1 -ne 0 ]; then
        echo "mount_running_system: mount..."
        mkdir -p $RootfsPath/proc $RootfsPath/sys $RootfsPath/dev/pts
        mount -t proc  /proc $RootfsPath/proc
        mount -t sysfs /sys  $RootfsPath/sys
        mount -o bind  /dev  $RootfsPath/dev
        mount -o bind  /dev/pts $RootfsPath/dev/pts
    else
        echo "mount_running_system: umount..."
        if mountpoint -q $RootfsPath/proc; then
            umount $RootfsPath/proc
        fi
        if mountpoint -q $RootfsPath/sys; then
            umount $RootfsPath/sys
        fi
        if mountpoint -q $RootfsPath/dev/pts; then
            umount $RootfsPath/dev/pts
        fi
        if mountpoint -q $RootfsPath/dev; then
            umount $RootfsPath/dev
        fi
    fi
}

function init_build_param()
{
    local jsonfile=param.json

    ParamOsType=$(jq -r -c .common.os_type $jsonfile)
    [[ $ParamOsType == "null" ]] && exit_with_error "os_type is not set in $jsonfile"

    ParamUbuntuType=$(jq -r -c .common.ubuntu_type $jsonfile)
    [[ $ParamUbuntuType == "null" ]] && exit_with_error "ubuntu_type is not set in $jsonfile"

    ParamKernelVersion=$(jq -r -c .common.kernel_version $jsonfile)

    ParamDefaultUser=$(jq -r -c .common.default_user $jsonfile)
    [[ $ParamDefaultUser == "null" ]] && ParamDefaultUser="ubuntu"

    ParamTimezone=$(jq -r -c .common.timezone $jsonfile)
    [[ $ParamTimezone == "null" ]] && ParamTimezone="Etc/UTC"

    ParamDefaultPassword=$(jq -r -c .common.default_password $jsonfile)
    [[ $ParamDefaultPassword == "null" ]] && ParamDefaultUser="123"

    ParamHostname=$(jq -r -c .common.hostname $jsonfile)
    [[ $ParamHostname == "null" ]] && ParamHostname=$ParamDefaultUser

    ParamGrubCmd=$(jq -r -c .common.grub_cmd_default $jsonfile)
    [[ $ParamGrubCmd == "null" ]] && ParamGrubCmd="quiet splash"

    ParamAddSize=$(jq -r -c .common.add_disksize $jsonfile)
    ParamPackage=$(jq -r -c .$ParamOsType.package $jsonfile)

    #image file
    ImageFile=$ParamUbuntuType-preinstalled-$ParamOsType-amd64.img

    #create temp directory
    [ ! -d $RootfsPath ] && mkdir -p $RootfsPath
    [ ! -d $DownloadPath ] && mkdir -p $DownloadPath

    #install qemu-system-x86
    local qemu_system=$(dpkg-query -s qemu-system-x86 |grep install)
    [ -z "$qemu_system" ] && apt-get install qemu-system-x86
}

function init_image_env()
{
    [ ! -f $ImageFile ] && exit_with_error "ubuntu preinstalled image is not exist. please download it"

    local loopdev=$(losetup -f)     #get available loop device
    [[ -z $loopdev ]] && exit_with_error "cannot found available loop device"
    losetup $loopdev $ImageFile

    #parse partition table
    kpartx -av $loopdev

    #mount rootfs
    mount /dev/mapper/$(basename $loopdev)p1 $RootfsPath
    mount /dev/mapper/$(basename $loopdev)p15 $RootfsPath/boot/efi

    #for network issue, copy host resolv.conf to image. fix it when bug
    [ -L $RootfsPath/etc/resolv.conf ] && rm -rf $RootfsPath/etc/resolv.conf
    cp -L /etc/resolv.conf $RootfsPath/etc/resolv.conf

    mount_running_system 1

    #mount host download path to target /opt/download
    mkdir -p $RootfsPath/opt/download
    mount -t none $DownloadPath $RootfsPath/opt/download -o bind
}

function close_image_env()
{
    #umount download path
    umount $RootfsPath/opt/download
    rm -rf $RootfsPath/opt/download

    mount_running_system 0
    umount $RootfsPath/boot/efi
    umount $RootfsPath

    #umount and remove loop device
    #find loop device as it can be mounted manually
    local loopdev=$(losetup -l |grep $ParamUbuntuType | awk '{print $1}')
    if [ -n "$loopdev" ]; then
        kpartx -dv $loopdev
        losetup -d $loopdev
    fi
}

function update_kernel()
{
    local download_addr=https://kernel.ubuntu.com/mainline/
    local version=v$ParamKernelVersion/

    #it will download index.html
    wget -P $DownloadPath $download_addr$version
    [ ! -f $DownloadPath/index.html ] && exit_with_error "$download_addr$version have no index.html. please check"

    htmltxt=$(grep -r amd $DownloadPath/index.html |grep deb |grep linux)
    for filename in $htmltxt; do
        filename=${filename#*\"}     #delete left of "
        filename=${filename%\"*}     #delete right of "
        onlyfile=${filename##*/}     #delete left of /
        if [[ $filename =~ "/" ]] && [ ! -f $DownloadPath/$onlyfile ]; then
            wget -c -t 0 -P $DownloadPath $download_addr$version$filename
            [[ $? != 0 ]] && exit_with_error "failed to download $filename"
        fi
    done

    [ -f $DownloadPath/index.html ] && rm -f $DownloadPath/index.html

    #install kernel
    chroot_command "dpkg -i /opt/download/*.deb"
    chroot_command "apt-get clean"
    chroot_command "update-grub"
}

function configure_ubuntu_rootfs()
{
    chroot_command "apt-get update"
    chroot_command "apt-get upgrade"
    chroot_command "apt-get clean"

    #install customized package
    chroot_command "apt-get install $ParamPackage"
    chroot_command "apt-get clean"

    echo "set root and default user with passwd ..."
    chroot_command "useradd -m -G audio,lp,cdrom -s /bin/bash $ParamDefaultUser"
    chroot_command "(echo $ParamDefaultPassword;echo $ParamDefaultPassword;) | passwd $ParamDefaultUser >/dev/null 2>&1"
    chroot_command "(echo $ParamDefaultPassword;echo $ParamDefaultPassword;) | passwd root >/dev/null 2>&1"

    #set hostname
    chroot_command "echo $ParamHostname > /etc/hostname"

    #ssh enable root login
    local context="PermitRootLogin yes"
    chroot_command "sed -i 's/.*PermitRootLogin.*/$context/' /etc/ssh/sshd_config"

    #grub cmdlind
    context="GRUB_CMDLINE_LINUX_DEFAULT=\"$ParamGrubCmd\""
    chroot_command "sed -i 's/.*GRUB_CMDLINE_LINUX_DEFAULT.*/$context/' /etc/default/grub"

    #remove GRUB_CMDLINE_LINUX_DEFAULT in cloudimg-settings
    local cloud_cmd_file=$RootfsPath/etc/default/grub.d/50-cloudimg-settings.cfg
    [ -f $cloud_cmd_file ] && sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/d' $cloud_cmd_file

    #set timezone
    [ -n "$ParamTimezone" ] && chroot_command "timedatectl set-timezone $ParamTimezone"
}

function handle_ubuntu_image()
{
    #image file not exist, download and resize it
    if [ ! -f $ImageFile ]; then
        echo "$ImageFile not exist. begint to download it"
        if [ $ParamUbuntuType == "jammy" ]; then
            wget -c -t 0 https://cdimage.ubuntu.com/ubuntu-server/jammy/daily-preinstalled/current/$ImageFile.xz
        else
            wget -c -t 0 https://cdimage.ubuntu.com/ubuntu-server/daily-preinstalled/current/$ImageFile.xz
        fi
        [ ! -f $ImageFile.xz ] && exit_with_error "fail to download $ImageFile.xz. Please check"

        xz -d $ImageFile.xz
        [[ $? != 0 ]] && exit_with_error "failed to decompress $DownloadPath/$ImageFile.xz"

        #increase disk size
        if [ $ParamAddSize -gt 0 ]; then
            local addSize=M
            addSize=$ParamAddSize$addSize
            qemu-img resize $ImageFile +$addSize

            #increase disk size manually
            local loopdev=$(losetup -f)
            losetup $loopdev $ImageFile
            partprobe $loopdev      #refresh partition
            gparted $loopdev        #add unpartitioned space to rootfs manually"
            losetup -d $loopdev
        fi
    fi
}

#param: $1: 1-mount, 0-umount
function handle_rootfs()
{
    if [ $1 -ne 0 ]; then
        init_image_env
    else
        close_image_env
    fi
}

init_build_param
#main function
while [[ $# -gt 0 ]]; do
    key=$1
    case $key in
        -h|--help)
            help_usage
            exit 0
            ;;
        -u|--rootfs_update)
            handle_rootfs $2
            shift 2
            ;;
        *)
            handle_ubuntu_image
            init_image_env
            configure_ubuntu_rootfs
            update_kernel
            close_image_env
            shift
            ;;
    esac
done
