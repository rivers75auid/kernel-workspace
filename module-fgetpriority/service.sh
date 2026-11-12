#!/system/bin/sh
PATH=/data/adb/ksu/bin:$PATH
MODDIR=${0%/*}
PROP="$MODDIR/module.prop"
KO="$MODDIR/ko/fgetpriority.ko"
BASE_DESC="Hide syscall results (non-GKI 4.19 build for fog/cirno)"

set_desc() {
	[ -f "$PROP" ] || return 0
	{
		grep -v '^description=' "$PROP"
		printf 'description=%s\n' "$1"
	} > "$PROP.tmp" && mv -f "$PROP.tmp" "$PROP" && chmod 0644 "$PROP"
}

is_loaded() {
	[ -d /sys/module/fgetpriority ] || grep -q '^fgetpriority ' /proc/modules 2>/dev/null
}

if [ ! -f "$KO" ]; then
	set_desc "[Inactive ❌] fgetpriority.ko not found — $BASE_DESC"
	exit 1
fi

kptr_set=$(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)
echo 1 > /proc/sys/kernel/kptr_restrict 2>/dev/null
addr=$(grep " kallsyms_lookup_name$" /proc/kallsyms 2>/dev/null | head -n 1 | awk '{print "0x"$1}')
[ -n "$kptr_set" ] && echo "$kptr_set" > /proc/sys/kernel/kptr_restrict 2>/dev/null

if [ -z "$addr" ] || [ "$addr" = "0x" ]; then
	set_desc "[Inactive ❌] kallsyms_lookup_name unavailable — $BASE_DESC"
	exit 1
fi

if is_loaded; then
	rmmod fgetpriority 2>/dev/null || rmmod "$KO" 2>/dev/null
fi

if ! insmod "$KO" kallsyms_lookup_name_fn="$addr" 2>/dev/null; then
	ksud insmod "$KO" kallsyms_lookup_name_fn="$addr" 2>/dev/null
fi

kver=$(uname -r 2>/dev/null)
if is_loaded; then
	set_desc "[Active ✅] Loaded in kernel ($kver) — $BASE_DESC"
else
	set_desc "[Inactive ❌] Failed to insmod on $kver — $BASE_DESC"
fi
