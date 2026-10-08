#!/sbin/sh
##########################################################################################
#
# Magisk / KernelSU Module Installer Script
# Kairos RAM & Memory Management Suite
#
##########################################################################################

SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=false
LATESTARTSERVICE=true

ui_print "**********************************************"
ui_print "*   Kairos RAM & Memory Management Suite     *"
ui_print "*      Extreme App Retention & 60Hz Fix      *"
ui_print "**********************************************"

ui_print "- Installing module files..."
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm $MODPATH/service.sh 0 0 0755

ui_print "- Applying permissions..."
ui_print "- Complete! Reboot to activate full protection."
