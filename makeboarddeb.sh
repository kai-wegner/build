#!/bin/bash
#
# Copyright (c) 2015 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.
#
# This file is a part of tool chain https://github.com/igorpecovnik/lib
#
#
# Create board support packages
#
# Functions:
# create_board_package

create_board_package()
{
	display_alert "Creating board support package" "$BOARD $BRANCH" "info"

	local destination=$DEST/debs/$RELEASE/${CHOSEN_ROOTFS}_${REVISION}_${ARCH}
	rm -rf $destination
	mkdir -p $destination/DEBIAN

	# Replaces: base-files is needed to replace /etc/update-motd.d/ files on Xenial
	# Replaces: unattended-upgrades may be needed to replace /etc/apt/apt.conf.d/50unattended-upgrades
	# (distributions provide good defaults, so this is not needed currently)
	# Depends: linux-base is needed for "linux-version" command in initrd cleanup script
	cat <<-EOF > $destination/DEBIAN/control
	Package: linux-${RELEASE}-root-${DEB_BRANCH}${BOARD}
	Version: $REVISION
	Architecture: $ARCH
	Maintainer: $MAINTAINER <$MAINTAINERMAIL>
	Installed-Size: 1
	Section: kernel
	Priority: optional
	Depends: bash, linux-base, u-boot-tools, initramfs-tools
	Provides: armbian-bsp
	Conflicts: armbian-bsp
	Replaces: base-files, mpv
	Recommends: bsdutils, parted, python3-apt, util-linux, toilet, wireless-tools
	Description: Armbian tweaks for $RELEASE on $BOARD ($BRANCH branch)
	EOF

	# set up pre install script
	cat <<-EOF > $destination/DEBIAN/preinst
	#!/bin/sh
	[ "\$1" = "upgrade" ] && touch /var/run/.reboot_required
	[ -d "/boot/bin.old" ] && rm -rf /boot/bin.old
	[ -d "/boot/bin" ] && mv -f /boot/bin /boot/bin.old
	if [ -L "/etc/network/interfaces" ]; then
		cp /etc/network/interfaces /etc/network/interfaces.tmp
		rm /etc/network/interfaces
		mv /etc/network/interfaces.tmp /etc/network/interfaces
	fi
	# make a backup since we are unconditionally overwriting this on update
	cp /etc/default/cpufrequtils /etc/default/cpufrequtils.dpkg-old
	dpkg-divert --package linux-${RELEASE}-root-${DEB_BRANCH}${BOARD} --add --rename \
		--divert /etc/mpv/mpv-dist.conf /etc/mpv/mpv.conf
	exit 0
	EOF

	chmod 755 $destination/DEBIAN/preinst

	# postrm script
	cat <<-EOF > $destination/DEBIAN/postrm
	#!/bin/sh
	[ remove = "\$1" ] || [ abort-install = "\$1" ] && dpkg-divert --package linux-${RELEASE}-root-${DEB_BRANCH}${BOARD} --remove --rename \
		--divert /etc/mpv/mpv-dist.conf /etc/mpv/mpv.conf
	systemctl disable log2ram.service armhwinfo.service >/dev/null 2>&1
	exit 0
	EOF

	chmod 755 $destination/DEBIAN/postrm

	# set up post install script
	cat <<-EOF > $destination/DEBIAN/postinst
	#!/bin/sh
	[ ! -f "/etc/network/interfaces" ] && cp /etc/network/interfaces.default /etc/network/interfaces
	ln -sf /var/run/motd /etc/motd
	rm -f /etc/update-motd.d/00-header /etc/update-motd.d/10-help-text
	if [ -f "/boot/bin/$BOARD.bin" ] && [ ! -f "/boot/script.bin" ]; then ln -sf bin/$BOARD.bin /boot/script.bin >/dev/null 2>&1 || cp /boot/bin/$BOARD.bin /boot/script.bin; fi
	rm -f /usr/local/bin/h3disp /usr/local/bin/h3consumption
	[ ! -f /etc/default/armbian-motd ] && cp /usr/lib/armbian/armbian-motd.default /etc/default/armbian-motd
	if [ ! -f "/etc/default/log2ram" ]; then
		cp /etc/default/log2ram.dpkg-dist /etc/default/log2ram
	fi
	if [ -f "/etc/systemd/system/log2ram.service" ]; then
		mv /etc/systemd/system/log2ram.service /etc/systemd/system/log2ram-service.dpkg-old
	fi
	if [ -f "/lib/systemd/system/pinebook-enable-sound.service" ]; then
		systemctl enable pinebook-enable-sound.service
	fi
	exit 0
	EOF

	chmod 755 $destination/DEBIAN/postinst

	# won't recreate files if they were removed by user
	# TODO: Add proper handling for updated conffiles
	#cat <<-EOF > $destination/DEBIAN/conffiles
	#EOF

	# trigger uInitrd creation after installation, to apply
	# /etc/initramfs/post-update.d/99-uboot
	cat <<-EOF > $destination/DEBIAN/triggers
	activate update-initramfs
	EOF

	# create directory structure
	mkdir -p $destination/etc/{init.d,default,update-motd.d,profile.d,network,cron.d,cron.daily}
	mkdir -p $destination/usr/{bin,sbin} $destination/usr/lib/armbian/ $destination/usr/lib/nand-sata-install/ $destination/usr/share/armbian/ $destination/usr/share/log2ram/
	mkdir -p $destination/etc/initramfs/post-update.d/
	mkdir -p $destination/etc/kernel/preinst.d/
	mkdir -p $destination/etc/apt/apt.conf.d/
	mkdir -p $destination/etc/X11/xorg.conf.d/
	mkdir -p $destination/lib/systemd/system/ $destination/lib/udev/rules.d/
	mkdir -p $destination/var/lib/polkit-1/localauthority/

	install -m 755 $SRC/lib/packages/bsp/armhwinfo $destination/etc/init.d/

	# configure MIN / MAX speed for cpufrequtils
	cat <<-EOF > $destination/etc/default/cpufrequtils
	ENABLE=true
	MIN_SPEED=$CPUMIN
	MAX_SPEED=$CPUMAX
	GOVERNOR=$GOVERNOR
	EOF

	# armhwinfo, firstrun, armbianmonitor, etc. config file
	cat <<-EOF > $destination/etc/armbian-release
	# PLEASE DO NOT EDIT THIS FILE
	BOARD=$BOARD
	BOARD_NAME="$BOARD_NAME"
	VERSION=$REVISION
	LINUXFAMILY=$LINUXFAMILY
	BRANCH=$BRANCH
	ARCH=$ARCHITECTURE
	IMAGE_TYPE=$IMAGE_TYPE
	BOARD_TYPE=$BOARD_TYPE
	INITRD_ARCH=$INITRD_ARCH
	EOF

	# armbianmonitor (currently only to toggle boot verbosity and log upload)
	install -m 755 $SRC/lib/packages/bsp/armbianmonitor/armbianmonitor $destination/usr/bin

	# updating uInitrd image in update-initramfs trigger
	install -m 755 $SRC/lib/packages/bsp/99-uboot $destination/etc/initramfs/post-update.d/99-uboot

	# removing old initrd.img on upgrade
	# this will be obsolete after kernel packages rework
	install -m 755 $SRC/lib/packages/bsp/initramfs-cleanup $destination/etc/kernel/preinst.d/initramfs-cleanup

	# network interfaces configuration
	cp $SRC/lib/packages/bsp/network/interfaces.* $destination/etc/network/
	# this is required for NFS boot to prevent deconfiguring the network on shutdown
	[[ $RELEASE == xenial || $RELEASE == stretch ]] && sed -i 's/#no-auto-down/no-auto-down/g' $destination/etc/network/interfaces.default

	# apt configuration
	cp $SRC/lib/packages/bsp/apt/71-no-recommends $destination/etc/apt/apt.conf.d/71-no-recommends

	# configure the system for unattended upgrades
	cp $SRC/lib/packages/bsp/apt/02periodic $destination/etc/apt/apt.conf.d/02periodic

	# xorg configuration
	cp $SRC/lib/packages/bsp/xorg/01-armbian-defaults.conf $destination/etc/X11/xorg.conf.d/01-armbian-defaults.conf

	# script to install to SATA
	cp -R $SRC/lib/packages/bsp/nand-sata-install/lib/* $destination/usr/lib/nand-sata-install/
	install -m 755 $SRC/lib/packages/bsp/nand-sata-install/nand-sata-install $destination/usr/sbin/nand-sata-install

	install -m 755 $SRC/sources/armbian-config/scripts/tv_grab_file $destination/usr/bin/tv_grab_file
	install -m 755 $SRC/sources/armbian-config/debian-config $destination/usr/bin/armbian-config
	install -m 755 $SRC/sources/armbian-config/softy $destination/usr/bin/softy

	# install custom motd with reboot and upgrade checking
	install -m 755 $SRC/lib/packages/bsp/motd/* $destination/etc/update-motd.d/

	install -m 755 $SRC/lib/packages/bsp/apt/apt-updates $destination/usr/lib/armbian/apt-updates
	cp $SRC/lib/packages/bsp/apt/armbian-updates $destination/etc/cron.d/armbian-updates

	# install bash profile scripts
	cp $SRC/lib/packages/bsp/profile/* $destination/etc/profile.d/

	# install various udev rules
	cp $SRC/lib/packages/bsp/udev/*.rules $destination/lib/udev/rules.d/

	cp $SRC/lib/packages/bsp/armbian-motd.default $destination/usr/lib/armbian/armbian-motd.default

	# install copy of boot script & environment file
	local bootscript_src=${BOOTSCRIPT%%:*}
	local bootscript_dst=${BOOTSCRIPT##*:}
	cp $SRC/lib/config/bootscripts/$bootscript_src $destination/usr/share/armbian/$bootscript_dst
	[[ -n $BOOTENV_FILE && -f $SRC/lib/config/bootenv/$BOOTENV_FILE ]] && \
		cp $SRC/lib/config/bootenv/$BOOTENV_FILE $destination/usr/share/armbian/armbianEnv.txt

	# install policykit files used on desktop images to alllow unprivileged users to shutdown/reboot,
	# change brightness, configure network, etc.
	cp $SRC/lib/packages/bsp/policykit/*.pkla $destination/var/lib/polkit-1/localauthority/

	# h3disp for sun8i/3.4.x
	if [[ $LINUXFAMILY == sun8i && $BRANCH == default ]]; then
		install -m 755 $SRC/lib/packages/bsp/{h3disp,h3consumption} $destination/usr/bin
	fi

	# add configuration for setting uboot environment from userspace with: fw_setenv fw_printenv
	if [[ -n $UBOOT_FW_ENV ]]; then
		UBOOT_FW_ENV=($(tr ',' ' ' <<< "$UBOOT_FW_ENV"))
		echo "# Device to access      offset           env size" > $destination/etc/fw_env.config
		echo "/dev/mmcblk0	${UBOOT_FW_ENV[0]}	${UBOOT_FW_ENV[1]}" >> $destination/etc/fw_env.config
	fi

	# log2ram - systemd compatible ramlog alternative
	cp $SRC/lib/packages/bsp/log2ram/LICENSE.log2ram $destination/usr/share/log2ram/LICENSE
	cp $SRC/lib/packages/bsp/log2ram/log2ram.service $destination/lib/systemd/system/log2ram.service
	install -m 755 $SRC/lib/packages/bsp/log2ram/log2ram $destination/usr/sbin/log2ram
	install -m 755 $SRC/lib/packages/bsp/log2ram/log2ram.hourly $destination/etc/cron.daily/log2ram
	cp $SRC/lib/packages/bsp/log2ram/log2ram.default $destination/etc/default/log2ram.dpkg-dist

	if [[ $LINUXFAMILY == sun*i* ]]; then
		install -m 755 $SRC/lib/packages/bsp/armbian-add-overlay $destination/usr/sbin
		if [[ $BRANCH == default ]]; then
			arm-linux-gnueabihf-gcc $SRC/lib/packages/bsp/sunxi-temp/sunxi_tp_temp.c -o $destination/usr/bin/sunxi_tp_temp
			# convert and add fex files
			mkdir -p $destination/boot/bin
			for i in $(ls -w1 $SRC/lib/config/fex/*.fex | xargs -n1 basename); do
				fex2bin $SRC/lib/config/fex/${i%*.fex}.fex $destination/boot/bin/${i%*.fex}.bin
			done
		fi
	fi

	if [[ ( $LINUXFAMILY == sun*i || $LINUXFAMILY == pine64 ) && $BRANCH == default ]]; then
		# add mpv config for vdpau_sunxi
		mkdir -p $destination/etc/mpv/
		cp $SRC/lib/packages/bsp/mpv/mpv_sunxi.conf $destination/etc/mpv/mpv.conf
		echo "export VDPAU_OSD=1" > $destination/etc/profile.d/90-vdpau.sh
		chmod 755 $destination/etc/profile.d/90-vdpau.sh
	fi
	if [[ ( $LINUXFAMILY == sun50i* || $LINUXFAMILY == sun8i ) && $BRANCH == dev ]]; then
		# add mpv config for x11 output - slow, but it works compared to no config at all
		mkdir -p $destination/etc/mpv/
		cp $SRC/lib/packages/bsp/mpv/mpv_mainline.conf $destination/etc/mpv/mpv.conf
	fi

	#TODO: move to sources.conf and to a subdirectory in packages/bsp
	if [[ $BOARD == pinebook-a64 ]]; then
		cp $SRC/lib/packages/bsp/pinebook-enable-sound.service $destination/lib/systemd/system/
	fi

	# add some summary to the image
	fingerprint_image "$destination/etc/armbian.txt"

	# create board DEB file
	display_alert "Building package" "$CHOSEN_ROOTFS" "info"
	cd $DEST/debs/$RELEASE/
	dpkg -b ${CHOSEN_ROOTFS}_${REVISION}_${ARCH} >/dev/null

	# cleanup
	rm -rf ${CHOSEN_ROOTFS}_${REVISION}_${ARCH}
}
