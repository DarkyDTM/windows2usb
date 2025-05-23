#!/usr/bin/env bash
set -e               # errexit
set -f               # noglob
set +o braceexpand   # disable braceexpand
shopt -s nocasematch # for "if labeltype"

export LANG=C.utf8

header='
| __        _____ _   _     ____    _   _ ____  ____   |
| \ \      / /_ _| \ | |   |___ \  | | | / ___|| __ )  |
|  \ \ /\ / / | ||  \| |     __) | | | | \___ \|  _ \  |
|   \ V  V /  | || |\  |    / __/  | |_| |___) | |_) | |
|    \_/\_/  |___|_| \_(_) |_____|  \___/|____/|____/  |
========================================================
.    Windows 7+ ISO to Flash Drive burning utility     .'

scriptpath="$(readlink -f -- "$0")"
dirpath="$(dirname "$scriptpath")"

function check_requirements() {
	local reqs=(awk lsblk 7z mkfs.vfat mkfs.ntfs sfdisk ms-sys mktemp wimsplit tr)

	for req in ${reqs[*]}; do
		if ! command -v "$req" >/dev/null; then
			echo " == ERROR: $req is required but not found =="
			exit 104
		fi
	done
}

function check_iso_and_device() {
	if [ ! -f "$1" ]; then
		echo " == ERROR: ISO file not found! =="
		exit 106
	fi

	if [ ! -b "$2" ]; then
		echo " == ERROR: Device file not found! =="
		exit 107
	fi
}

function list_removable_drives() {
	lsblk=$(lsblk -d -I 8 -o RM,NAME,SIZE,MODEL |
		awk '($1 == 1) {print "/dev/" substr($0, index($0, $2))}')
	if [[ "$lsblk" ]]; then
		echo "$lsblk"
	else
		echo "No removable storage found!"
	fi
}

function format_drive() {
	if [[ "$1" == "dos" ]] || [[ "$1" == "gpt" ]]; then
		echo "label: $1" | sfdisk "$2"
		sleep 3
	else
		echo " == format_drive: INTERNAL ERROR =="
		exit 101
	fi
}

function get_iso_name() {
	7z l "$1" | awk '/Comment = / {print $3; exit 0}'
}

function sanitize_iso_name() {
	# FAT32 does not allow certain characters in names, see
	# https://github.com/dosfstools/dosfstools/blob/1da41f0e70dcbfb874e8191c639b91fa58205ea4/src/fatlabel.c#L96
	echo "$1" | tr -d '*?.,;:/\\|+=<>[]"'
}

function check_installwim_gt4gib() {
	7z l "$1" | awk 'BEGIN {doend=1} ($6 ~ /install.wim/) {if ($4 > 4294967296) {doend=0; exit 0}; doend=0; exit 1} END {if (doend) {exit 1}}'
}

function create_partitions() {
	local mbrscript="- - 7 *"
	local gptscript="- - EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 *"
	local gptuefintfsscript="- 1MiB U *\n- - EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 *"

	if [[ "$1" == "dos" ]] || [[ "$1" == "gpt" ]] || [[ "$1" == "gptntfs" ]] ||
		[[ "$1" == "gpt+uefintfs" ]]; then
		if [[ "$1" == "dos" ]]; then
			echo -e "$mbrscript" | sfdisk "$2"

		elif [[ "$1" == "gpt" ]]; then
			echo -e "$gptscript" | sfdisk "$2"

		elif [[ "$1" == "gptntfs" ]]; then
			echo -e "$gptscript" | sfdisk "$2"

		elif [[ "$1" == "gpt+uefintfs" ]]; then
			echo -e "$gptuefintfsscript" | sfdisk "$2"
		fi
	else
		echo " == create_partitions: INTERNAL ERROR =="
		exit 102
	fi
	# Wait 1 second to settle new partition table
	# See bug #24
	sleep 1
}

function get_dev_partition_num() {
	# $1 - device
	# $2 - partition number

	if [ -b "${1}${2}" ]; then
		echo "${1}${2}"
		return
	fi

	if [ -b "${1}p${2}" ]; then
		echo "${1}p${2}"
		return
	fi

	echo " == get_dev_partition_num: INTERNAL ERROR =="
	exit 105
}

function write_uefintfs() {
	if [ -e "$dirpath/uefi-ntfs.img" ]; then
		cat "$dirpath/uefi-ntfs.img" >"$1"
	elif [ -e "/usr/share/windows2usb/uefi-ntfs.img" ]; then
		cat "/usr/share/windows2usb/uefi-ntfs.img" >"$1"
	fi
}

function extract_iso() {
	# $1 - isopath
	# $2 - destdir
	# $3 - exclude install.wim extraction flag

	if [[ "$3" == "skipinstallwim" ]]; then
		7z x "$1" -o"$2" '-x!sources/install.wim'
	else
		7z x "$1" -o"$2"
	fi
}

function split_wim() {
	# $1 - isopath
	# $2 - isomountpath
	# $3 - destdir

	mount -o ro "$1" "$2"
	wimsplit "$2/sources/install.wim" "$3/sources/install.swm" 3800
	umount "$2"
}

function extract_bootmgfw_from_installwim() {
	# $1 - isopath
	# $2 - isomountpath
	# $3 - destdir

	mount -o ro "$1" "$2"
	local fpath="$2/sources/install.wim"
	[ ! -e "$fpath" ] && fpath="$2/sources/install.esd"

	7z e "$fpath" -aoa -o"$3/efi/boot/" 'Windows/Boot/EFI/bootmgfw.efi' '?/Windows/Boot/EFI/bootmgfw.efi'
	umount "$2"
}

function umount_rm_path() {
	if [ -d "$1" ]; then
		umount "$1" || true
		rm -r "$1"
	fi

	if [ -d "$2" ]; then
		umount "$2" 2>/dev/null || true
		rm -r "$2"
	fi
}

function sigint_handler() {
	umount_rm_path "$partpath" "$isomountpath"
}

if [[ ! "$2" ]]; then
	echo "${header}"
	echo "WARNING: this program will delete all existing data on your drive!"
	echo
	echo "$(basename "$0")" "<device> <windows iso> [mbr/gpt/gptntfs/gpt+uefintfs]"
	echo
	echo "mbr mode: the most universal, RECOMMENDED and DEFAULT method."
	echo "   This mode creates MBR partition table with FAT32 partition,"
	echo "   installs BIOS and UEFI bootloaders, supports Secure Boot."
	echo "   install.wim file larger than 4 GiB will be split."
	echo "   Suitable for all computers (UEFI/CSM/BIOS)."
	echo
	echo "gpt mode: less universal mode, for modern (UEFI) computers."
	echo "   GPT+FAT32, UEFI only, supports Secure Boot."
	echo
	echo "gptntfs mode: all the same as 'gpt' but NTFS is used."
	echo "   GPT+NTFS, UEFI only, supports Secure Boot."
	echo "   Large install.wim file will not be split."
	echo "   NOTE: not all UEFI are compatible with this mode,"
	echo "   NTFS driver should be present on the motherboard."
	echo
	echo "gpt+uefintfs mode: alternative hacky installation method, not recommended."
	echo "   This mode uses NTFS partition and third-party 'uefintfs' bootloader."
	echo "   GPT+NTFS(data)+FAT32(efi), UEFI only, supports Secure Boot"
	echo "   (since uefintfs Oct 23, 2021 release)."
	echo "   Large install.wim file will not be split."
	echo
	echo " == Removable storage list =="

	list_removable_drives
	exit
fi

if [[ "$EUID" == "0" ]]; then
	dev="$1"
	isopath="$2"
	isolabel=""
	labeltype="$3"
	[[ ! "$labeltype" ]] && labeltype="mbr"
	mountntfs_cmd="mount.ntfs-3g"
	if ! command -v "$mountntfs_cmd" >/dev/null; then
		mountntfs_cmd="mount"
	fi

	check_requirements
	check_iso_and_device "$isopath" "$dev"

	isolabel="$(get_iso_name "$isopath")"
	if [ $? -ne 0 ]; then
		isolabel=""
	fi
	echo " == Working with ISO $isolabel =="

	skipinstallwim=""
	splitinstallwim=1
	partpath="$(mktemp -d /run/windows2usb.XXXXXXXXXX)"
	isomountpath="$(mktemp -d /run/windows2usb-mount.XXXXXXXXXX)"
	trap sigint_handler INT EXIT

	# MBR FAT32
	if [[ "$labeltype" == "mbr" ]]; then
		isolabel="$(sanitize_iso_name "$isolabel")"

		echo " == Creating new MBR-formatted partition table =="
		format_drive "dos" "$dev"

		echo " == Creating FAT partition =="
		create_partitions "dos" "$dev"
		mkfs.vfat -n "${isolabel:0:11}" "$(get_dev_partition_num "${dev}" "1")"

		echo " == Writing bootloader =="
		ms-sys -7 -f "${dev}"
		ms-sys -e "$(get_dev_partition_num "${dev}" "1")"

		echo " == Mounting data partition =="
		mount -o utf8=true "$(get_dev_partition_num "${dev}" "1")" "$partpath"

	# GPT FAT32
	elif [[ "$labeltype" == "gpt" ]]; then
		isolabel="$(sanitize_iso_name "$isolabel")"

		echo " == Creating new GPT-formatted partition table =="
		format_drive "gpt" "$dev"

		echo " == Creating FAT partition =="
		create_partitions "gpt" "$dev"
		mkfs.vfat -n "${isolabel:0:11}" "$(get_dev_partition_num "${dev}" "1")"

		echo " == Mounting data partition =="
		mount -o utf8=true "$(get_dev_partition_num "${dev}" "1")" "$partpath"

	# GPT NTFS
	elif [[ "$labeltype" == "gptntfs" ]]; then
		splitinstallwim="" # do NOT split install.wim in this mode

		echo " == Creating new GPT-formatted partition table =="
		format_drive "gpt" "$dev"

		echo " == Creating Microsoft NTFS partition =="
		create_partitions "gptntfs" "$dev"
		mkfs.ntfs -L "$isolabel" -f "$(get_dev_partition_num "${dev}" "1")"

		echo " == Mounting data partition =="
		"$mountntfs_cmd" "$(get_dev_partition_num "${dev}" "1")" "$partpath"

	# GPT FAT32 (UEFINTFS) + NTFS
	elif [[ "$labeltype" == "gpt+uefintfs" ]]; then
		splitinstallwim="" # do NOT split install.wim in this mode

		echo " == Creating new GPT-formatted partition table =="
		format_drive "gpt" "$dev"

		echo " == Creating UEFI FAT and Microsoft NTFS partitions =="
		create_partitions "gpt+uefintfs" "$dev"
		write_uefintfs "$(get_dev_partition_num "${dev}" "1")"
		mkfs.ntfs -L "$isolabel" -f "$(get_dev_partition_num "${dev}" "2")"

		echo " == Mounting data partition =="
		"$mountntfs_cmd" "$(get_dev_partition_num "${dev}" "2")" "$partpath"
	fi

	if [[ "$splitinstallwim" ]] && check_installwim_gt4gib "$isopath"; then
		echo " == NOTE: install.wim is greater than 4 GiB and will be split to fit FAT32 limit =="
		skipinstallwim="skipinstallwim"
	fi

	echo " == Extracting files from ISO to the partition =="
	extract_iso "$isopath" "$partpath" "$skipinstallwim"

	if [[ "$skipinstallwim" ]]; then
		split_wim "$isopath" "$isomountpath" "$partpath"
	fi

	# If there's no .efi bootloader files inside the iso,
	# extract them from install.wim
	# This is true for older Windows 7 ISO files.
	if [ ! -f "$partpath/efi/boot/bootx64.efi" ] &&
		[ ! -f "$partpath/efi/boot/bootia32.efi" ]; then
		echo " == Extracting UEFI bootloader from install.wim =="
		mkdir -p "$partpath/efi/boot/" || true
		extract_bootmgfw_from_installwim "$isopath" "$isomountpath" "$partpath"
		if [ -e "$partpath/efi/boot/bootmgfw.efi" ]; then
			mv "$partpath/efi/boot/bootmgfw.efi" "$partpath/efi/boot/bootx64.efi"
			cp "$partpath/efi/boot/bootx64.efi" "$partpath/efi/boot/bootia32.efi"
		else
			echo "NOTE: your ISO file does not have UEFI bootloader, UEFI boot would be unavailable!"
		fi
	fi

	echo " == Unmounting partition =="
	echo "NOTE: If this process takes very long to complete, your system is misconfigured!"
	echo "More info: https://github.com/ValdikSS/windows2usb/issues/3#issuecomment-771534058"
	umount_rm_path "$partpath" "$isomountpath"

	echo " == All done! =="
else
	if [[ "$APPIMAGE" ]]; then
		scriptpath="$APPIMAGE"
	fi

	[ -f "$1" ] && PARAM1="$(readlink -f -- "$1")" || PARAM1="$1"
	[ -f "$2" ] && PARAM2="$(readlink -f -- "$2")" || PARAM2="$2"
	shift
	shift

	privescs=(pkexec sudo)
	for privesc in ${privescs[*]}; do
		if command -v "$privesc" >/dev/null; then
			"$privesc" "$scriptpath" "$PARAM1" "$PARAM2" "$@"
			exit
		fi
	done

	echo " == ERROR: no pkexec or sudo found. =="
	echo " == ERROR: please run this script as root manually. =="
fi
