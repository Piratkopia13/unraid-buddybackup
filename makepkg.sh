#!/bin/bash

SRC_DIR="/mnt/user/sonic/buddybackup_plugin/src"
TMP_DIR="/tmp/buddybackup_${RANDOM}"

cp -r "${SRC_DIR}" "${TMP_DIR}"
cd "${TMP_DIR}"
chown -R root:root ./
chmod -R 755 ./

rm "${SRC_DIR}/../buddybackup.txz"
makepkg -l y -c y "${SRC_DIR}/../buddybackup.txz"
ec=$?
cd "${SRC_DIR}"
echo "Removing ${TMP_DIR}"
rm -r "${TMP_DIR}"
if [[ "${ec}" -ne 0 ]]; then
    exit "Failed to makepkg, aborting."
fi

# Update md5 in plg file
md5=$(md5sum "${SRC_DIR}/../buddybackup.txz" | sed 's/\s.*$//')
sed -i "/<!ENTITY pkgMD5/c\  <!ENTITY pkgMD5        \"${md5}\">" "${SRC_DIR}/../buddybackup.plg"

if [[ "${1}" == "reinstall" ]]; then
    echo "reinstalling.."
    upgradepkg --install-new --reinstall "${SRC_DIR}/../buddybackup.txz"
    shift
fi
if [[ "${1}" == "update" ]]; then
    echo "calling rc.buddybackup.php update"
    /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update
fi