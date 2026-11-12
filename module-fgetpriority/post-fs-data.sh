#!/system/bin/sh
MODDIR=${0%/*}
PROP="$MODDIR/module.prop"

[ -f "$PROP" ] || exit 0
{
	grep -v '^description=' "$PROP"
	printf 'description=%s\n' "[Pending...] Waiting for boot service to load LKM (non-GKI 4.19 build for fog/cirno)"
} > "$PROP.tmp" && mv -f "$PROP.tmp" "$PROP" && chmod 0644 "$PROP"
