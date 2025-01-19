#!/bin/bash

cd src
makepkg -l y -c y ../buddybackup.txz
cd ..
if [ $? -ne 0 ]; then
    exit "Failed to makepkg, aborting."
fi

# Update md5 in plg file
md5=$(md5sum buddybackup.txz | sed 's/\s.*$//')
sed -i "/<!ENTITY pkgMD5/c\  <!ENTITY pkgMD5        \"${md5}\">" buddybackup.plg
