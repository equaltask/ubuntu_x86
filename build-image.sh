#!/usr/bin/env bash

TempPath=temp
RootfsPath=$TempPath/rootfs
DownloadPath=$TempPath/download

AddDiskSize=0
SeedFile=seed.iso
UsrDataFile=user-data
MetaDataFile=meta-data
ImageFile=ubuntu.img

function help_usage()
{
    echo "command guide:"
    echo "  build-image.sh -f filename -a -b -u 1/0 -r -ku 5.17 -h"
    echo "    -f|--file:          preinstalled(.img.xz)/install(.iso)/image(.img) file"
    echo "    -b|--build:         build ubuntu image"
    echo "    -a|--add_size:      add size for preinstalled image"
    echo "    -u|--rootfs_update: rootfs update manually. 1-mount rootfs, 0-umount rootfs"
    echo "    -r|--run:           run image with qemu"
    echo "    -ku|--kernel_local: update local kernel version"
    echo "    -h|--help:          help"
    echo #empty line
    echo "modify parameters defined in param.json before run with root"
    echo "As gparted need GUI support, please run in ubuntu-desktop"
    echo "rootfs_update: update/configure rootfs manually with chroot. mounted rootfs path: temp/rootfs"
    echo "recommanded disk size: server-5.5G(5500), desktop-15.7G(15700). modify it in param.json"
    echo "img.xz/iso file download path:"
    echo "    https://cdimage.ubuntu.com/ubuntu-server/jammy/daily-preinstalled/current"
    echo "    https://releases.ubuntu.com/22.04.4/"
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

    local pkgName=$(dpkg-query -s jq |grep install)
    [ -z "$pkgName" ] && apt-get install -y jq

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

    ParamDiskSize=$(jq -r -c .common.disk_size $jsonfile)
    ParamAddSize=$(jq -r -c .common.add_size $jsonfile)
    ParamPackage=$(jq -r -c .$ParamOsType.package $jsonfile)

    #create temp directory
    [ ! -d $RootfsPath ] && mkdir -p $RootfsPath

    #install required packages
    pkgName=$(dpkg-query -s qemu-system-x86 |grep install)
    [ -z "$pkgName" ] && apt-get install -y qemu-system-x86
    pkgName=$(dpkg-query -s kpartx |grep install)
    [ -z "$pkgName" ] && apt-get install -y kpartx
    pkgName=$(dpkg-query -s gparted |grep install)
    [ -z "$pkgName" ] && apt-get install -y gparted
    pkgName=$(dpkg-query -s cloud-image-utils |grep install)
    [ -z "$pkgName" ] && apt-get install -y cloud-image-utils
}

function init_image_env()
{
    [ ! -f $ImageFile ] && exit_with_error "ubuntu preinstalled image is not exist. please download it"

    local loopdev=$(losetup -f)     #get available loop device
    [[ -z $loopdev ]] && exit_with_error "cannot found available loop device"
    losetup $loopdev $ImageFile

    #parse partition table
    kpartx -av $loopdev
    #waiting available
    sleep 1s

    #mount rootfs
    if [ -a /dev/mapper/$(basename $loopdev)p2 ]; then
        #installed image with 3 partitions. p3 for rootfs and p2 for efi
        mount -t ext4 /dev/mapper/$(basename $loopdev)p3 $RootfsPath
        mount -t vfat /dev/mapper/$(basename $loopdev)p2 $RootfsPath/boot/efi
    else
        #preinstalled image with 2 partitions
        mount /dev/mapper/$(basename $loopdev)p1 $RootfsPath
        mount /dev/mapper/$(basename $loopdev)p15 $RootfsPath/boot/efi
    fi

    #for network issue, copy host resolv.conf to image. fix it when bug
    [ -L $RootfsPath/etc/resolv.conf ] && rm -rf $RootfsPath/etc/resolv.conf
    cp -L /etc/resolv.conf $RootfsPath/etc/resolv.conf

    mount_running_system 1
}

function close_image_env()
{
    #umount download path
    if mountpoint -q $RootfsPath/opt/download; then
        umount $RootfsPath/opt/download
    fi
    rm -rf $RootfsPath/opt/download

    mount_running_system 0
    umount $RootfsPath/boot/efi
    umount $RootfsPath

    #umount and remove loop device
    #find loop device as it can be mounted manually
    local loopdev=$(losetup -l |grep $ImageFile | awk '{print $1}')
    if [ -n "$loopdev" ]; then
        kpartx -dv $loopdev
        losetup -d $loopdev
    fi

    #remove temp directories
    rm -rf $RootfsPath/dev $RootfsPath/sys $RootfsPath/proc $RootfsPath/opt
}

function update_kernel()
{
    #when no kernel verison defined, skip
    if [ -z $ParamKernelVersion ]; then
        echo "kernel version is not set"
        return
    fi

    local download_addr=https://kernel.ubuntu.com/mainline/
    local version=v$ParamKernelVersion/

    [ ! -d $DownloadPath ] && mkdir -p $DownloadPath
    #mount host download path to target /opt/download
    mkdir -p $RootfsPath/opt/download
    mount -t none $DownloadPath $RootfsPath/opt/download -o bind

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
    if [ $1 -eq 0 ]; then #image kernel
        echo "update image kernel to version v$ParamKernelVersion"
        chroot_command "dpkg -i /opt/download/*.deb"
        chroot_command "apt-get clean"
        chroot_command "update-grub"
    else #local kernel
        echo "update local kernel to version v$ParamKernelVersion"
        dpkg -i $DownloadPath/*.deb
        apt-get clean
        update-grub
    fi
}

function configure_os_image()
{
    local resizeFile=resize_partition_2204.sh
    if [ -f tool/$resizeFile ]; then
        cp tool/$resizeFile $RootfsPath/lib/modules
        chmod 777 $RootfsPath/lib/modules/$resizeFile

        #resize disk in startup
        echo "#!/bin/sh" > $RootfsPath/etc/rc.local
        echo "/lib/modules/$resizeFile" >> $RootfsPath/etc/rc.local
        echo "exit 0" >> $RootfsPath/etc/rc.local
        chmod 777 $RootfsPath/etc/rc.local
    fi

    local serviceFile=$RootfsPath/lib/systemd/system/rc-local.service
    if [ -f $serviceFile ]; then
        local installTxt=$(grep -r Install $serviceFile)
        if [ -z "$installTxt" ]; then #add when 'Install' not exist
            echo "" >> $serviceFile
            echo "[Install]" >> $serviceFile
            echo "WantedBy=multi-user.target" >> $serviceFile
            echo "Alias=rc-local.service" >> $serviceFile
        fi

        chroot_command "ln -s /lib/systemd/system/rc-local.service /etc/systemd/system/rc-local.service"
    fi

    local kernelUpdateFile=ubuntu-mainline-kernel.sh
    if [ -f tool/$kernelUpdateFile ]; then
        cp tool/$kernelUpdateFile $RootfsPath/usr/local/bin
        chmod 777 $RootfsPath/usr/local/bin/$kernelUpdateFile
    fi
}

function configure_ubuntu()
{
    #install customized package
    chroot_command "apt-get clean"
    chroot_command "apt-get install -y $ParamPackage"
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

    configure_os_image
}

function increase_image_size()
{
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

function handle_input_file()
{
    local fileName=$1
    [ ! -f $fileName ] && exit_with_error "file $fileName not exist. Please download it"

    if [ "${fileName##*.}" == "xz" ]; then    #xz file, decompress it
        local tempFile=${fileName%.*}         #remove . and right char
        xz -d -k $fileName
        [[ $? != 0 ]] && exit_with_error "failed to decompress $fileName"
        mv $tempFile $ImageFile
        BuildType=xz
    elif [ "${fileName##*.}" == "img" ]; then #img file, no decompress
        if [ "$fileName" != "$ImageFile" ]; then
            cp $fileName $ImageFile
        fi
        BuildType=img
    elif [ "${fileName##*.}" == "iso" ]; then #iso file, install image
        IsoFileName=$fileName
        BuildType=iso
    fi
}

function install_iso_image()
{
    [ ! -f $IsoFileName ] && exit_with_error "iso file not exist"
    [ ! -f $UsrDataFile ] && exit_with_error "user-data not exist"

    [ ! -f $MetaDataFile ] && touch $MetaDataFile

    [ -f $ImageFile ] && rm $ImageFile
    #create target disk
    local diskSize=M
    diskSize=$ParamDiskSize$diskSize
    truncate -s $diskSize $ImageFile

    [ -f $SeedFile ] && rm $SeedFile
    cloud-localds $SeedFile $UsrDataFile $MetaDataFile

    #run the install
    kvm -no-reboot -m 2048 \
        -drive file=$ImageFile,format=raw,cache=none,if=virtio \
        -drive file=$SeedFile,format=raw,cache=none,if=virtio \
        -cdrom $IsoFileName

    [ -f $MetaDataFile ] && rm -f $MetaDataFile
}

function build_image()
{
    if [ "$BuildType" == "xz" ]; then
        echo "build ubuntu with preinstalled image..."
        if [ $AddDiskSize -eq 1 ]; then
            increase_image_size
        fi
    elif [ "$BuildType" == "iso" ]; then
        echo "build ubuntu with iso image..."
        install_iso_image
    fi

    init_image_env
    configure_ubuntu
    #update image kernel
    update_kernel 0
    close_image_env
    echo "end of building ubuntu!"
}

init_build_param
#main function
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            help_usage
            exit 0
            ;;
        -u|--rootfs_update) #update rootfs with chroot
            handle_rootfs $2
            shift 2
            ;;
        -f|--file)         #img/iso file
            handle_input_file $2
            shift 2
            ;;
        -a|--add_size)     #add disk size for preinstalled image
            AddDiskSize=1
            shift
            ;;
        -r|--run)          #run installed image with qemu
            kvm -no-reboot -m 2048 -drive file=$ImageFile,format=raw,cache=none,if=virtio
            shift
            ;;
        -ku|--kernel_local)
            ParamKernelVersion=$2
            #update local kernel
            update_kernel 1
            shift 2
            ;;
        *)
            build_image
            shift
            ;;
    esac
done
