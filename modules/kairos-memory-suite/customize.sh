#!/sbin/sh
SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=false
LATESTARTSERVICE=true

ui_print "**********************************************"
ui_print "*            Kairos RAM Management           *"
ui_print "**********************************************"

ui_print "- Installing module..."
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/service.sh 0 0 0755
ui_print "- Done!"
