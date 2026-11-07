#!/system/bin/sh
# For android 13+ decrypt
# vivo wangcong add for decrypt (ported from PD2183 TWRP tree)
mount -t ext4 /dev/block/by-name/persist /mnt/vendor/persist
sleep 0.5
# vivo yuanjianchun add for vgc begin
setprop crypto.ready 1
