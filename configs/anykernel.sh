### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## Custom Kairos Kernel for Redmi 10C (fog / wind / rain / sm6225)

### AnyKernel setup
# global properties
properties() { '
kernel.string=Kairos Kernel for Redmi 10C (fog)
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=fog
device.name2=wind
device.name3=rain
device.name4=sm6225
device.name5=Redmi 10C
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=boot;
IS_SLOT_DEVICE=auto;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# Injeksi script runtime Potato Suite untuk Android 16
if [ -d "/data/adb/service.d" ]; then
  ui_print " "
  ui_print "-> Injecting Potato Runtime Optimizer..."
  cp -f "$home/99-potato-fog.sh" /data/adb/service.d/99-potato-fog.sh
  chmod 755 /data/adb/service.d/99-potato-fog.sh
fi

# boot install
dump_boot;

# write new kernel image and dtb
write_boot;
## end boot install
