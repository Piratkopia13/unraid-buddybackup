#!/bin/bash

DST_DIR="/mnt/user/sonic/buddybackup_plugin"
SRC_DIR="${DST_DIR}/src"

TMP_DIR="/tmp/buddybackup_${RANDOM}"

cp -r "${SRC_DIR}" "${TMP_DIR}"
cd "${TMP_DIR}"
chown -R root:root ./
chmod -R 755 ./

rm "${DST_DIR}/buddybackup.txz"
makepkg -l y -c y "${DST_DIR}/buddybackup.txz"
ec=$?
cd "${SRC_DIR}"
echo "Removing ${TMP_DIR}"
rm -r "${TMP_DIR}"
if [[ "${ec}" -ne 0 ]]; then
    exit "Failed to makepkg, aborting."
fi

# Update md5 in plg file
md5=$(md5sum "${DST_DIR}/buddybackup.txz" | sed 's/\s.*$//')
sed -i "/<!ENTITY pkgMD5/c\  <!ENTITY pkgMD5        \"${md5}\">" "${DST_DIR}/buddybackup.plg"

if [[ "${1}" == "reinstall" ]]; then
    echo "reinstalling.."
    upgradepkg --install-new --reinstall "${DST_DIR}/buddybackup.txz"
    shift
fi
if [[ "${1}" == "update" ]]; then
    echo "calling rc.buddybackup.php update"
    /usr/local/emhttp/plugins/buddybackup/scripts/rc.buddybackup.php update
fi