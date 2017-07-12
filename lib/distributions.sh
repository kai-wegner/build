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
# Functions:
# install_common
# install_distribution_specific
# post_debootstrap_tweaks

install_common()
{
	display_alert "Applying common tweaks" "" "info"

	# add dummy fstab entry to make mkinitramfs happy
	echo "/dev/mmcblk0p1 / $ROOTFS_TYPE defaults 0 1" >> $SDCARD/etc/fstab

	# create modules file
	if [[ $BRANCH == dev && -n $MODULES_DEV ]]; then
		tr ' ' '\n' <<< "$MODULES_DEV" > $SDCARD/etc/modules
	elif [[ $BRANCH == next || $BRANCH == dev ]]; then
		tr ' ' '\n' <<< "$MODULES_NEXT" > $SDCARD/etc/modules
	else
		tr ' ' '\n' <<< "$MODULES" > $SDCARD/etc/modules
	fi

	# create blacklist files
	if [[ $BRANCH == dev && -n $MODULES_BLACKLIST_DEV ]]; then
		tr ' ' '\n' <<< "$MODULES_BLACKLIST_DEV" | sed -e 's/^/blacklist /' > $SDCARD/etc/modprobe.d/blacklist-${BOARD}.conf
	elif [[ ($BRANCH == next || $BRANCH == dev) && -n $MODULES_BLACKLIST_NEXT ]]; then
		tr ' ' '\n' <<< "$MODULES_BLACKLIST_NEXT" | sed -e 's/^/blacklist /' > $SDCARD/etc/modprobe.d/blacklist-${BOARD}.conf
	elif [[ $BRANCH == default && -n $MODULES_BLACKLIST ]]; then
		tr ' ' '\n' <<< "$MODULES_BLACKLIST" | sed -e 's/^/blacklist /' > $SDCARD/etc/modprobe.d/blacklist-${BOARD}.conf
	fi

	# remove default interfaces file if present
	# before installing board support package
	rm -f $SDCARD/etc/network/interfaces

	mkdir -p $SDCARD/selinux

	# console fix due to Debian bug
	sed -e 's/CHARMAP=".*"/CHARMAP="'$CONSOLE_CHAR'"/g' -i $SDCARD/etc/default/console-setup

	# change time zone data
	echo $TZDATA > $SDCARD/etc/timezone
	chroot $SDCARD /bin/bash -c "dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1"

	# set root password
	chroot $SDCARD /bin/bash -c "(echo $ROOTPWD;echo $ROOTPWD;) | passwd root >/dev/null 2>&1"
	# force change root password at first login
	chroot $SDCARD /bin/bash -c "chage -d 0 root"

	# display welcome message at first root login
	touch $SDCARD/root/.not_logged_in_yet

	# NOTE: this needs to be executed before family_tweaks
	local bootscript_src=${BOOTSCRIPT%%:*}
	local bootscript_dst=${BOOTSCRIPT##*:}
	cp $SRC/config/bootscripts/$bootscript_src $SDCARD/boot/$bootscript_dst

	[[ -n $BOOTENV_FILE && -f $SRC/config/bootenv/$BOOTENV_FILE ]] && \
		cp $SRC/config/bootenv/$BOOTENV_FILE $SDCARD/boot/armbianEnv.txt

	# TODO: modify $bootscript_dst or armbianEnv.txt to make NFS boot universal
	# instead of copying sunxi-specific template
	if [[ $ROOTFS_TYPE == nfs ]]; then
		display_alert "Copying NFS boot script template"
		if [[ -f $SRC/userpatches/nfs-boot.cmd ]]; then
			cp $SRC/userpatches/nfs-boot.cmd $SDCARD/boot/boot.cmd
		else
			cp $SRC/scripts/nfs-boot.cmd.template $SDCARD/boot/boot.cmd
		fi
	fi

	[[ -n $OVERLAY_PREFIX && -f $SDCARD/boot/armbianEnv.txt ]] && \
		echo "overlay_prefix=$OVERLAY_PREFIX" >> $SDCARD/boot/armbianEnv.txt

	# initial date for fake-hwclock
	date -u '+%Y-%m-%d %H:%M:%S' > $SDCARD/etc/fake-hwclock.data

	echo $HOST > $SDCARD/etc/hostname

	# set hostname in hosts file
	cat <<-EOF > $SDCARD/etc/hosts
	127.0.0.1   localhost $HOST
	::1         localhost $HOST ip6-localhost ip6-loopback
	fe00::0     ip6-localnet
	ff00::0     ip6-mcastprefix
	ff02::1     ip6-allnodes
	ff02::2     ip6-allrouters
	EOF

	display_alert "Installing kernel" "$CHOSEN_KERNEL" "info"
	chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1

	display_alert "Installing u-boot" "$CHOSEN_UBOOT" "info"
	chroot $SDCARD /bin/bash -c "DEVICE=/dev/null dpkg -i /tmp/debs/${CHOSEN_UBOOT}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1

	display_alert "Installing headers" "${CHOSEN_KERNEL/image/headers}" "info"
	chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/${CHOSEN_KERNEL/image/headers}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1

	# install firmware
	#if [[ -f $SDCARD/tmp/debs/${CHOSEN_KERNEL/image/firmware-image}_${REVISION}_${ARCH}.deb ]]; then
	#	display_alert "Installing firmware" "${CHOSEN_KERNEL/image/firmware-image}" "info"
	#	chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/${CHOSEN_KERNEL/image/firmware-image}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1
	#fi

	if [[ -f $SDCARD/tmp/debs/armbian-firmware_${REVISION}_${ARCH}.deb ]]; then
		display_alert "Installing generic firmware" "armbian-firmware" "info"
		chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/armbian-firmware_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1
	fi

	if [[ -f $SDCARD/tmp/debs/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb ]]; then
		display_alert "Installing DTB" "${CHOSEN_KERNEL/image/dtb}" "info"
		chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1
	fi

	# install board support package
	display_alert "Installing board support package" "$BOARD" "info"
	chroot $SDCARD /bin/bash -c "dpkg -i /tmp/debs/$RELEASE/${CHOSEN_ROOTFS}_${REVISION}_${ARCH}.deb" >> $DEST/debug/install.log 2>&1

	# freeze armbian packages
	if [[ $BSPFREEZE == "yes" ]]; then
		display_alert "Freeze armbian packages" "$BOARD" "info"
		if [[ "$BRANCH" != "default" ]]; then MINIBRANCH="-"$BRANCH; fi
		chroot $SDCARD /bin/bash -c "apt-mark hold ${CHOSEN_KERNEL} ${CHOSEN_KERNEL/image/headers} \
		linux-u-boot-${BOARD}-${BRANCH} linux-dtb${MINIBRANCH}-${LINUXFAMILY}" >> $DEST/debug/install.log 2>&1
	fi

	# copy boot splash images
	cp $SRC/bin/splash/armbian-u-boot.bmp $SDCARD/boot/boot.bmp
	cp $SRC/bin/splash/armbian-desktop.png $SDCARD/boot/boot-desktop.png

	# execute $LINUXFAMILY-specific tweaks from $BOARD.conf
	[[ $(type -t family_tweaks) == function ]] && family_tweaks

	install -m 755 $SRC/scripts/resize2fs $SDCARD/etc/init.d/
	install -m 755 $SRC/scripts/firstrun  $SDCARD/etc/init.d/
	install -m 644 $SRC/scripts/resize2fs.service $SDCARD/etc/systemd/system/
	install -m 644 $SRC/scripts/firstrun.service $SDCARD/etc/systemd/system/

	# enable additional services
	chroot $SDCARD /bin/bash -c "systemctl --no-reload enable firstrun.service resize2fs.service armhwinfo.service log2ram.service >/dev/null 2>&1"

	# copy "first run automated config, optional user configured"
 	cp $SRC/config/armbian_first_run.txt $SDCARD/boot/armbian_first_run.txt

	# switch to beta repository at this stage if building nightly images
	[[ $IMAGE_TYPE == nightly ]] && echo "deb http://beta.armbian.com $RELEASE main utils ${RELEASE}-desktop" > $SDCARD/etc/apt/sources.list.d/armbian.list

	# disable low-level kernel messages for non betas
	if [[ -z $BETA ]]; then
		sed -i "s/^#kernel.printk*/kernel.printk/" $SDCARD/etc/sysctl.conf
	fi

	# enable getty on serial console
	chroot $SDCARD /bin/bash -c "systemctl --no-reload enable serial-getty@$SERIALCON.service >/dev/null 2>&1"

	# don't clear screen tty1
	mkdir -p "$SDCARD/etc/systemd/system/getty@tty1.service.d/"
	printf "[Service]\nTTYVTDisallocate=no" > "$SDCARD/etc/systemd/system/getty@tty1.service.d/10-noclear.conf"

	# reduce modules unload timeout
	mkdir -p $SDCARD/etc/systemd/system/systemd-modules-load.service.d/
	printf "[Service]\nTimeoutStopSec=10" > $SDCARD/etc/systemd/system/systemd-modules-load.service.d/10-timeout.conf

	# handle PMU power button
	mkdir -p $SDCARD/etc/udev/rules.d/
	cp $SRC/config/71-axp-power-button.rules $SDCARD/etc/udev/rules.d/

	[[ $LINUXFAMILY == sun*i ]] && mkdir -p $SDCARD/boot/overlay-user

	# Fix for PuTTY/KiTTY & ncurses-based dialogs (i.e. alsamixer) over serial
	# may break other terminals like screen
	mkdir -p $SDCARD/etc/systemd/system/serial-getty@.service.d/
	printf "[Service]\nEnvironment=TERM=linux" > $SDCARD/etc/systemd/system/serial-getty@.service.d/10-term.conf

	# to prevent creating swap file on NFS (needs specific kernel options)
	# and f2fs/btrfs (not recommended or needs specific kernel options)
	[[ $ROOTFS_TYPE != ext4 ]] && touch $SDCARD/var/swap

	# install initial asound.state if defined
	mkdir -p $SDCARD/var/lib/alsa/
	[[ -n $ASOUND_STATE ]] && cp $SRC/config/$ASOUND_STATE $SDCARD/var/lib/alsa/asound.state

	# save initial armbian-release state
	cp $SDCARD/etc/armbian-release $SDCARD/etc/armbian-image-release
}

install_distribution_specific()
{
	display_alert "Applying distribution specific tweaks for" "$RELEASE" "info"
	case $RELEASE in
	jessie)
		# enable root login for latest ssh on jessie
		sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/' $SDCARD/etc/ssh/sshd_config

		mkdir -p $SDCARD/etc/NetworkManager/dispatcher.d/
		cat <<-'EOF' > $SDCARD/etc/NetworkManager/dispatcher.d/99disable-power-management
		#!/bin/sh
		case "$2" in
			up) /sbin/iwconfig $1 power off || true ;;
			down) /sbin/iwconfig $1 power on || true ;;
		esac
		EOF
		chmod 755 $SDCARD/etc/NetworkManager/dispatcher.d/99disable-power-management
		;;

	xenial)
		# enable root login for latest ssh on jessie
		sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' $SDCARD/etc/ssh/sshd_config

		# remove legal info from Ubuntu
		[[ -f $SDCARD/etc/legal ]] && rm $SDCARD/etc/legal

		# Fix for haveged service
		mkdir -p -m755 $SDCARD/etc/systemd/system/haveged.service.d
		cat <<-EOF > $SDCARD/etc/systemd/system/haveged.service.d/10-no-new-privileges.conf
		[Service]
		NoNewPrivileges=false
		EOF

		# disable not working on unneeded services
		# ureadahead needs kernel tracing options that AFAIK are present only in mainline
		chroot $SDCARD /bin/bash -c "systemctl --no-reload mask ondemand.service ureadahead.service setserial.service etc-setserial.service >/dev/null 2>&1"

		# properly disable powersaving wireless mode for NetworkManager
		mkdir -p $SDCARD/etc/NetworkManager/conf.d/
		cat <<-EOF > $SDCARD/etc/NetworkManager/conf.d/zz-override-wifi-powersave-off.conf
		[connection]
		wifi.powersave = 2
		EOF
		;;

	stretch)
	;;
	esac
}

post_debootstrap_tweaks()
{
	# remove service start blockers and QEMU binary
	rm -f $SDCARD/sbin/initctl $SDCARD/sbin/start-stop-daemon
	chroot $SDCARD /bin/bash -c "dpkg-divert --quiet --local --rename --remove /sbin/initctl"
	chroot $SDCARD /bin/bash -c "dpkg-divert --quiet --local --rename --remove /sbin/start-stop-daemon"
	rm -f $SDCARD/usr/sbin/policy-rc.d $SDCARD/usr/bin/$QEMU_BINARY

	# reenable resolvconf managed resolv.conf
	ln -sf /run/resolvconf/resolv.conf $SDCARD/etc/resolv.conf
}
