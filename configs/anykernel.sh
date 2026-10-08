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
BLOCK=/dev/block/by-name/boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# boot install
dump_boot;

# write new kernel image and dtb
write_boot;

# Install Built-in Kairos RAM Management module automatically
if [ -d "$AKHOME/kairos-module" ]; then
  ui_print " ";
  ui_print "- Installing Built-in Kairos RAM Management module...";

  # Check active root manager directories
  installed=0;
  for mod_dir in /data/adb/modules /data/adb/ksu/modules /data/adb/ap/modules; do
    if [ -d "$mod_dir" ]; then
      target="$mod_dir/kairos_memory_suite";
      mkdir -p "$target";
      cp -af "$AKHOME/kairos-module"/* "$target/";
      set_perm_recursive 0 0 755 644 "$target";
      set_perm 0 0 755 "$target/service.sh";
      ui_print "  Installed to $target";
      installed=1;
    fi;
  done;

  # If clean flash / unrooted without /data/adb, prepare standalone service.d for future root or init
  if [ $installed -eq 0 ]; then
    mkdir -p /data/adb/service.d;
    cp -f "$AKHOME/kairos-module/service.sh" /data/adb/service.d/kairos_ram.sh 2>/dev/null;
    chmod 755 /data/adb/service.d/kairos_ram.sh 2>/dev/null;
    ui_print "  Prepared standalone fallback in /data/adb/service.d";
  fi;
fi;

## end boot install
