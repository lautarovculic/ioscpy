# Troubleshooting

## `ioscpy --list` reports no devices

The device is not visible to usbmux. Verify the cable, unlock the iPhone, accept the
trust prompt, and confirm that `idevice_id -l` lists the device. ioscpy deduplicates
the USB and network entries for a single device. If `idevice_id` is not present,
install the USB tools with `brew install libimobiledevice`.

## The device is connected but the daemon does not respond

The USB forward is established, but the daemon returned no reply. Confirm that ioscpy
is installed on the device through a Sileo or Zebra repository, then inspect the
device:

```bash
ioscpyctl status                        # daemon running, tweak loaded
tail /var/jb/var/log/ioscpy/ioscpyd.log
ioscpyctl restart-daemon                # reload the daemon if required
```

The log resides under the active jailbreak prefix; `/var/jb` is the rootless and
roothide location.

## "couldn't set up the USB link to the iPhone"

`iproxy` failed to establish the forward. Confirm that libimobiledevice is installed
(`brew install libimobiledevice`) and that no other process holds the port. ioscpy
selects a free local port automatically, so this condition usually indicates that the
device has disconnected from the USB bus. Reconnect it.

## The screen renders but input has no effect

The daemon and the video stream can operate while injection is unavailable; this path
is designed to degrade rather than fail. Respring the device (or reinstall ioscpy from
Sileo), confirm that the injection framework matches the installed package, and review
`ioscpyctl status`, which reports the tweak state. After a respring, a single physical
tap on the screen is required before injected touches are accepted.

## The host and device report different versions

A version mismatch is resolved by updating both sides: `brew upgrade ioscpy` on the
Mac, and an update of ioscpy from the Sileo or Zebra repository on the device.

## Reading the capability map

```bash
ioscpyctl capabilities    # on the device
ioscpy --debug            # from the Mac
```

Both report the layout, prefix, injection framework, and the backends that are live.
