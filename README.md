# fedora-nvidia-upgrades

Auto-signing hook that keeps RPM Fusion's `akmod-nvidia` (open kernel modules)
loading under **Secure Boot**, across kernel and driver updates, on Fedora —
including systems where the display is driven by the NVIDIA card itself (so
the LUKS passphrase prompt needs early KMS to even be visible).

Developed and tested on an RTX 5080 (Blackwell), Fedora 44, dnf5, Secure Boot
ON, LUKS root. The approach generalizes to other RPM Fusion `akmod-nvidia`
setups on Secure Boot Fedora; the exact kernel/driver versions in this README
are just examples from that machine — yours will differ.

## The problem

`akmod-nvidia` rebuilds the NVIDIA kernel modules on every kernel update, but:

- It does **not** sign them for you.
- Secure Boot's `.machine` MOK keyring will reject anything but a proper CA
  cert, so the default `akmods` signing key template silently produces a
  cert Secure Boot won't trust.
- If your monitor is plugged into the NVIDIA card, the kernel's bare
  firmware framebuffer is invisible on it, so without a real KMS driver
  present in the initramfs, your LUKS passphrase prompt is a black screen.

Any one of these breaks the boot. All three have to be solved together.

## The four stacked causes (Secure Boot + LUKS + display-on-dGPU)

1. **Strict machine keyring.** Recent kernels set
   `CONFIG_INTEGRITY_CA_MACHINE_KEYRING_MAX=y`, so the `.machine` keyring
   (the only MOK keyring trusted for *module* signatures) accepts only a
   `CA:TRUE` + `keyUsage=keyCertSign` certificate — **not**
   `digitalSignature`. The default `/etc/pki/akmods/cacert.config.in`
   template mints a `CA:FALSE` + `digitalSignature` cert, which lands in
   `.platform` instead of `.machine` and gets rejected. Fix the template:
   ```
   basicConstraints=critical,CA:TRUE
   keyUsage=critical,keyCertSign
   ```
   then regenerate with `kmodgenca -a -f`, and confirm it landed:
   `sudo keyctl list %:.machine` should list your key.
2. **akmods does not auto-sign** built modules — you (or a hook) must sign
   each `.ko` by hand with
   `/usr/src/kernels/$(uname -r)/scripts/sign-file sha256 <priv> <cert> <mod>`.
3. **Never recompress signed modules with plain `xz -f`** (CRC64) — the
   kernel's in-tree module XZ decompressor rejects it
   (`decompression failed with status 6`, modprobe `Invalid argument`).
   Userspace tools (`modinfo`, `xz`) read CRC64 fine, so it passes every
   check yet silently fails to load — very misleading. Leave signed modules
   **uncompressed** (`.ko`), or use `xz --check=crc32 --lzma2=dict=1MiB`.
4. **Display needs NVIDIA early KMS.** If the monitor is on the NVIDIA card,
   force the modules into the initramfs via dracut, plus the matching GSP
   firmware for the currently-installed driver version.

This repo's hook automates causes 2–4 on every kernel/driver update. Cause 1
(the CA cert template) is a one-time manual fix — see [Prerequisites](#prerequisites).

## What's in this repo

- **`nvidia-akmods-sign`** — the workhorse script: builds the module if
  missing, signs it, (re)writes the early-KMS dracut config for whichever
  driver is currently installed, and rebuilds the initramfs if anything
  changed. Idempotent and fail-soft (never returns non-zero to its caller,
  so it can't break a kernel install or boot). Logs to journal tag
  `nvidia-akmods-sign`.
- **`96-nvidia-sign.install`** — a `kernel-install` plugin that runs
  `nvidia-akmods-sign` whenever a kernel is added — covers both `dnf` and
  GNOME Software/PackageKit *offline* updates (unlike the akmods plugin,
  it doesn't bail under `system-update.target`).
- **`nvidia-akmods-sign.service`** — runs once per boot after
  `akmods.service`, to catch driver-only updates and act as a safety net.
- **`install.sh`** — installs the three files above, enables the boot
  service, and does a test run against the running kernel.

## Prerequisites

- Fedora with Secure Boot enabled and RPM Fusion's `akmod-nvidia`
  (open kernel modules) already installed and working *once* (i.e. you've
  enrolled a MOK key and can currently boot into NVIDIA).
- The CA-cert template fix from cause 1 above, applied once:
  edit `/etc/pki/akmods/cacert.config.in`, then
  `sudo kmodgenca -a -f`, enroll the resulting cert via `mokutil --import`,
  reboot to complete MOK enrollment.
- `kernel-devel` installed for your running kernel (needed for `sign-file`).

## Install

```bash
git clone https://github.com/<you>/fedora-nvidia-upgrades.git
cd fedora-nvidia-upgrades
sudo bash install.sh
```

This installs to `/usr/local/sbin/nvidia-akmods-sign`,
`/etc/kernel/install.d/96-nvidia-sign.install`, and
`/etc/systemd/system/nvidia-akmods-sign.service`, enables the service, and
runs one test pass against your current kernel. Check the result:

```bash
journalctl -t nvidia-akmods-sign -n 20
```

If your monitor is on the NVIDIA card, also add a modeset drop-in (the hook
does this automatically after its first run, but for reference):
`/etc/modprobe.d/nvidia-modeset.conf`: `options nvidia-drm modeset=1 fbdev=1`.

## Known issue: `dnf upgrade` can deadlock (kernel + akmod-nvidia together)

If a single `sudo dnf upgrade -y` includes **both** a new kernel and a new
`akmod-nvidia`, calling the sign hook *synchronously* from `kernel-core`'s
`%posttrans` scriptlet can deadlock forever: once the module is built,
`akmods` internally runs its own nested `dnf install` to install the
package it just built — and that nested `dnf` can never acquire the rpm
transaction lock the still-open outer `dnf upgrade` is holding.

**Symptom:** both the outer `dnf upgrade` and an inner `dnf install` sit
idle (0% CPU, no compiler running) for minutes; `rpm -q` fails with
`can't create transaction lock`. Killing only the inner process doesn't
help — akmods just retries and spawns another one.

**Fix included in this repo:** `96-nvidia-sign.install` dispatches
`nvidia-akmods-sign` via `systemd-run --no-block --collect` instead of
calling it inline, so it runs *after* the parent dnf transaction releases
the rpm lock. This eliminates the deadlock.

**Trade-off:** the hook's original point was to have signed modules ready
before the very first boot of a new kernel. Detaching loses that hard
guarantee — the async job normally finishes in 15–45 seconds, but if you
reboot inside that window you can hit one black screen, which self-heals
on the next boot via `nvidia-akmods-sign.service`. In practice: after a
kernel-carrying upgrade, wait ~30s or check
`journalctl -t nvidia-akmods-sign -n 5` for a `done` line before rebooting.

**Manual recovery if you ever hit the deadlock on an unpatched setup:** by
the time it hangs, every package's files are already installed — only the
last post-install script is stuck — so it's safe to kill the *outer*
`dnf upgrade`/`sudo` process tree, then finish the interrupted step by hand:

```bash
ps aux | grep "dnf upgrade"                 # find the real dnf pid
sudo kill -TERM <sudo-pid> <dnf-pid>
sudo /usr/local/sbin/nvidia-akmods-sign <new-kernel-version>
```

Then confirm before rebooting:

```bash
sudo lsinitrd /boot/initramfs-<kver>.img | grep -i nvidia
sudo ls /boot/loader/entries/               # BLS entry for <kver> exists
```

## Benign scriptlet warning during upgrade

On a combined kernel + `akmod-nvidia` upgrade, you'll likely see this in the
`dnf` transaction output — it looks alarming but is harmless:

```
>>> Running %posttrans scriptlet: kernel-core-0:<new-kver>
>>> Scriptlet output:
>>> dracut-install: Failed to find module 'nvidia'
>>> dracut[E]: FAILED: ... -m nvidia nvidia_modeset nvidia_drm nvidia_uvm
>>> dracut-install: ERROR: installing '/lib/firmware/nvidia/<old-driver-ver>/gsp_*.bin'
```

This is stock Fedora's own `kernel-core` `%posttrans` scriptlet doing its
normal initramfs regen — nothing to do with this hook. It runs very early
in the transaction (kernel-core installs well before `akmod-nvidia` and
long before the async sign job starts), so at that point the new kernel's
nvidia module doesn't exist yet and the dracut config still points at the
old driver's firmware path. It does not fail the transaction, and is fully
superseded moments later by the real `nvidia-akmods-sign` job. Confirm with
`journalctl -t nvidia-akmods-sign -n 10` — look for `signed *.ko` lines
followed by `OK: signed nvidia module is in the initramfs` and `done`.
That's the real signal to reboot on, not the scriptlet output.

## Manual fallback (if the hook isn't installed / something breaks)

A new kernel means akmods rebuilds **unsigned, compressed** modules, which
won't load. Boot the new kernel via the recovery line below first, then:

```bash
KVER=<new-kernel-version>                       # e.g. uname -r of the new kernel
sudo akmods --force --kernels "$KVER"            # ensure modules are built
cd /lib/modules/$KVER/extra/nvidia
SF=/usr/src/kernels/$KVER/scripts/sign-file
for x in *.ko.xz; do sudo xz -d -f "$x"; done    # -> plain .ko (skip if already .ko)
for k in *.ko; do
  sudo "$SF" sha256 /etc/pki/akmods/private/private_key.priv \
                    /etc/pki/akmods/certs/public_key.der "$k"
done
sudo restorecon -RF . ; sudo depmod -a "$KVER"
sudo dracut --force /boot/initramfs-$KVER.img "$KVER"
# verify: lsinitrd /boot/initramfs-$KVER.img | grep -E '/nvidia[^/]*\.ko$'
sudo reboot
```

## Recovery boot (if a kernel update leaves you at a black screen before LUKS)

At GRUB, highlight the Fedora entry, press `e`, go to the end of the
`linux ...` line and **append** these params, then `Ctrl-X` (or `F10`) to
boot:

```
rd.driver.blacklist=nvidia modprobe.blacklist=nvidia nouveau.modeset=1 nvidia.modeset=0
```

This blacklists nvidia and forces `nouveau` KMS instead, so the dGPU still
lights up the LUKS prompt and you get a console (display works, no CUDA).
Optionally also append ` 3` to boot to a text console instead of the
desktop. Fix the underlying issue (e.g. rerun the hook manually), then
reboot normally.

## Alternative if you have a second GPU

If you have an integrated/secondary GPU available, routing the display
through it and leaving the NVIDIA card headless (compute-only) sidesteps
the early-KMS/display complexity entirely — points 1–3 above (signing) are
still needed for CUDA to work under Secure Boot, but point 4 (display KMS)
becomes unnecessary.

## License

MIT — see [LICENSE](LICENSE).
