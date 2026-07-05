PKGNAME="sh.siava.pixelxpert"
PKGPATH="/system/priv-app/PixelXpert/PixelXpert.apk"
LSPDDBPATH="/data/adb/lspd/config/modules_config.db"
MAGISKDBPATH="/data/adb/magisk.db"
MODDIR=${0%/*}

prepareSQL(){
	chmod +x $MODDIR/sqlite3
	SQLITEPATH="$MODDIR/sqlite3"
}

# runSQL "database path" "command" - then you can use $SQLRESULT to read the outcome
runSQL(){
	SQLRESULT=$($SQLITEPATH $DBPATH "$CMD")
}

#grant silent root access to given UID
grantRootUID(){
	DBPATH=$MAGISKDBPATH

	#new record - older magisk compatibility
	CMD="insert into policies (uid, package_name, policy, until, logging, notification) values ($1, '$2', 2, 0, 1, 0);" && runSQL
	#new record
	CMD="insert into policies (uid, policy, until, logging, notification) values ($1, 2, 0, 1, 0);" && runSQL
	#previously present record
	CMD="update policies set policy = 2, until = 0, logging = 1, notification = 0 where uid = $1;" && runSQL
}


#grant root access to given package name
grantRootPkg(){
	echo "- 	Granting root access to $1..."
	UID=$(pm list packages -U $1 --user 0 | grep ":$1 " | awk -F 'uid:' '{ print $2 }' | cut -d ',' -f 1)

	grantRootUID $UID $1
}

#grant root access to required apps
grantRootApps(){
	grantRootPkg $PKGNAME
}

# Ensure the app itself is installed.
# The APK is shipped as a systemless /system/priv-app so PackageManager picks it
# up on boot. On setups where that mount is not scanned by PM (notably KernelSU /
# KernelSU-Next with overlayfs, or with "Umount modules by default" enabled), the
# app never appears. PixelXpert needs no privileged permissions, so as a fallback
# we install the bundled APK directly. This is a no-op when the app is already
# present (e.g. picked up from the priv-app mount on Magisk).
ensureAppInstalled(){
	# wait for PackageManager / boot to settle before checking or installing
	local waited=0
	while [ "$(getprop sys.boot_completed)" != "1" ] && [ $waited -lt 120 ]; do
		sleep 2
		waited=$((waited + 2))
	done
	sleep 5

	# already installed (priv-app mount worked, or a previous fallback ran)? -> done
	if pm path "$PKGNAME" >/dev/null 2>&1; then
		return
	fi

	echo "- 	$PKGNAME not registered by PackageManager; installing bundled APK..."
	# copy to a world-readable temp so pm/installd can read it regardless of the
	# module's SELinux context
	local tmpapk="/data/local/tmp/PixelXpert-install.apk"
	cat "$MODDIR$PKGPATH" > "$tmpapk" 2>/dev/null || cat "$MODDIR/system/priv-app/PixelXpert/PixelXpert.apk" > "$tmpapk"
	chmod 644 "$tmpapk"
	pm install -r -g --user 0 "$tmpapk" >/dev/null 2>&1
	rm -f "$tmpapk"
}

ensureAppInstalled

prepareSQL

grantRootApps
