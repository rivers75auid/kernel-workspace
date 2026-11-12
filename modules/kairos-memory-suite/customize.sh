#!/system/bin/sh
SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=false
LATESTARTSERVICE=true

ui_print "**********************************************"
ui_print " Kairos Engine v2.3 (Memory & Scene Suite)"
ui_print " ZRAM + Swapfile + Power Profile + WebUI"
ui_print "**********************************************"

ui_print "- Installing module..."
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/service.sh 0 0 0755
set_perm $MODPATH/kairos_zram.sh 0 0 0755
set_perm $MODPATH/kairos_power.sh 0 0 0755
ui_print "- Done!"
