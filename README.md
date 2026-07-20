# fedora-nvidia-upgrades

This is an auto-signing hook that keeps RPM Fusion's `akmod-nvidia` open kernel
modules loading under **Secure Boot** across every kernel and driver update on
Fedora. It also covers systems where the display is driven by the NVIDIA card
itself, where the LUKS passphrase prompt needs early KMS just to be visible.

It was developed and tested on an RTX 5080 (Blackwell) running Fedora 44 with
dnf5, Secure Boot on, and a LUKS root. The approach should generalize to other
RPM Fusion `akmod-nvidia` setups on Secure Boot Fedora. The exact kernel and
driver versions shown below are just examples from that machine, so yours
will differ.

## The problem

`akmod-nvidia` rebuilds the NVIDIA kernel modules on every kernel update, but
three separate problems stand between a rebuilt module and one that actually
loads.

- It does **not** sign the modules for you.
- Secure Boot's `.machine` MOK keyring rejects anything but a proper CA
  certificate, and the default `akmods` signing key template silently
  produces a certificate Secure Boot won't trust.
- If your monitor is plugged into the NVIDIA card, the kernel's bare firmware
  framebuffer is invisible on it. Without a real KMS driver present in the
  initramfs, your LUKS passphrase prompt is just a black screen.

Any one of these problems on its own breaks the boot, so all three have to be
solved together.

## The four stacked causes

(Secure Boot, LUKS, and a display running off the dGPU each contribute one
piece.)

1. **Strict machine keyring.** Recent kernels set
   `CONFIG_INTEGRITY_CA_MACHINE_KEYRING_MAX=y`, so the `.machine` keyring,
   the only MOK keyring trusted for module signatures, accepts only a
   `CA:TRUE` certificate with `keyUsage=keyCertSign` and not
   `digitalSignature`. The default `/etc/pki/akmods/cacert.config.in`
   template mints a `CA:FALSE` certificate with `digitalSignature` instead,
   which lands in `.platform` rather than `.machine` and gets rejected. Fix
   the template so it reads
   ```
   basicConstraints=critical,CA:TRUE
   keyUsage=critical,keyCertSign
   ```
   then regenerate it with `kmodgenca -a -f` and confirm it landed.
   `sudo keyctl list %:.machine` should list your key.
2. **akmods does not auto-sign built modules.** You, or a hook, have to sign
   each `.ko` by hand using
   `/usr/src/kernels/$(uname -r)/scripts/sign-file sha256 <priv> <cert> <mod>`.
3. **Never recompress signed modules with plain `xz -f`.** That produces
   CRC64 output, and the kernel's in-tree module XZ decompressor rejects it
   with `decompression failed with status 6` and modprobe reporting
   `Invalid argument`. Userspace tools like `modinfo` and `xz` read CRC64
   fine, so it passes every check and still silently fails to load, which
   makes it a very misleading failure. Leave signed modules uncompressed as
   `.ko`, or use `xz --check=crc32 --lzma2=dict=1MiB` if you need
   compression.
4. **Display needs NVIDIA early KMS.** If the monitor is on the NVIDIA card,
   force the modules into the initramfs through dracut, along with the
   matching GSP firmware for whichever driver version is currently
   installed.

This repo's hook automates causes two through four on every kernel and
driver update. Cause one, the CA cert template, is a one-time manual fix
described under [Prerequisites](#prerequisites).

## What's in this repo

- **`nvidia-akmods-sign`** is the workhorse script. It builds the module if
  it's missing, signs it, rewrites the early-KMS dracut config for whichever
  driver is currently installed, and rebuilds the initramfs if anything
  changed. It's idempotent and fail-soft, meaning it never returns a nonzero
  exit code to its caller, so it can't break a kernel install or a boot. It
  logs to the journal under the tag `nvidia-akmods-sign`.
- **`96-nvidia-sign.install`** is a `kernel-install` plugin that runs
  `nvidia-akmods-sign` whenever a kernel is added. It covers both `dnf` and
  GNOME Software/PackageKit offline updates, unlike the akmods plugin, which
  bails under `system-update.target`.
- **`nvidia-akmods-sign.service`** runs once per boot after `akmods.service`,
  to catch driver-only updates and act as a safety net.
- **`nvidia-akmods-history`** summarizes the persistent log described below
  into a one-screen report of how many updates this method has handled.
- **`install.sh`** installs the four files above, enables the boot service,
  and runs a test pass against the running kernel.

## Prerequisites

- Fedora with Secure Boot enabled and RPM Fusion's `akmod-nvidia` open
  kernel modules already installed and working once. That means you've
  already enrolled a MOK key and can currently boot into NVIDIA.
- The CA cert template fix from cause one above, applied once. Edit
  `/etc/pki/akmods/cacert.config.in`, run `sudo kmodgenca -a -f`, enroll the
  resulting cert with `mokutil --import`, and reboot to complete MOK
  enrollment.
- `kernel-devel` installed for your running kernel, since `sign-file` needs
  it.

## Install

```bash
git clone https://github.com/<you>/fedora-nvidia-upgrades.git
cd fedora-nvidia-upgrades
sudo bash install.sh
```

This installs `nvidia-akmods-sign` to `/usr/local/sbin`,
`96-nvidia-sign.install` to `/etc/kernel/install.d`, and
`nvidia-akmods-sign.service` to `/etc/systemd/system`. It enables the
service and runs one test pass against your current kernel. Check the
result with

```bash
journalctl -t nvidia-akmods-sign -n 20
```

If your monitor is on the NVIDIA card, also add a modeset drop-in. The hook
writes this automatically after its first run, but for reference it's
`/etc/modprobe.d/nvidia-modeset.conf` containing
`options nvidia-drm modeset=1 fbdev=1`.

## dnf upgrade can deadlock when a kernel and akmod-nvidia update together

If a single `sudo dnf upgrade -y` includes both a new kernel and a new
`akmod-nvidia`, calling the sign hook synchronously from `kernel-core`'s
`%posttrans` scriptlet can deadlock forever. Once the module is built,
`akmods` internally runs its own nested `dnf install` to install the package
it just built, and that nested `dnf` can never acquire the rpm transaction
lock the still-open outer `dnf upgrade` is holding.

The symptom is that both the outer `dnf upgrade` and an inner `dnf install`
sit idle at 0% CPU with no compiler running for minutes, while `rpm -q`
fails with `can't create transaction lock`. Killing only the inner process
doesn't help, because akmods just retries and spawns another one.

This repo's fix is that `96-nvidia-sign.install` dispatches
`nvidia-akmods-sign` through `systemd-run --no-block --collect` instead of
calling it inline, so it runs after the parent dnf transaction releases the
rpm lock. That eliminates the deadlock.

The trade-off is that the hook's original point was to have signed modules
ready before the very first boot of a new kernel, and detaching the job
loses that hard guarantee. The async job normally finishes in fifteen to
forty five seconds, but if you reboot inside that window you can hit one
black screen, which self-heals on the next boot through
`nvidia-akmods-sign.service`. In practice, wait about thirty seconds after a
kernel-carrying upgrade, or check `journalctl -t nvidia-akmods-sign -n 5`
for a `done` line, before rebooting.

If you ever hit the deadlock on a setup that doesn't have this fix, recovery
is straightforward. By the time it hangs, every package's files are already
installed and only the last post-install script is stuck, so it's safe to
kill the outer `dnf upgrade`/`sudo` process tree and finish the interrupted
step by hand.

```bash
ps aux | grep "dnf upgrade"                 # find the real dnf pid
sudo kill -TERM <sudo-pid> <dnf-pid>
sudo /usr/local/sbin/nvidia-akmods-sign <new-kernel-version>
```

Then confirm before rebooting.

```bash
sudo lsinitrd /boot/initramfs-<kver>.img | grep -i nvidia
sudo ls /boot/loader/entries/               # BLS entry for <kver> exists
```

## A benign scriptlet warning during upgrade

On a combined kernel and `akmod-nvidia` upgrade, you'll likely see this in
the `dnf` transaction output, and it looks alarming even though it's
harmless.

```
>>> Running %posttrans scriptlet: kernel-core-0:<new-kver>
>>> Scriptlet output:
>>> dracut-install: Failed to find module 'nvidia'
>>> dracut[E]: FAILED: ... -m nvidia nvidia_modeset nvidia_drm nvidia_uvm
>>> dracut-install: ERROR: installing '/lib/firmware/nvidia/<old-driver-ver>/gsp_*.bin'
```

This is stock Fedora's own `kernel-core` `%posttrans` scriptlet doing its
normal initramfs regeneration, and it has nothing to do with this hook. It
runs very early in the transaction, since kernel-core installs well before
`akmod-nvidia` and long before the async sign job starts. At that point the
new kernel's nvidia module doesn't exist yet and the dracut config still
points at the old driver's firmware path, so both the module lookup and the
firmware install fail and get logged. It does not fail the transaction, and
it's fully superseded moments later by the real `nvidia-akmods-sign` job.
Confirm this with `journalctl -t nvidia-akmods-sign -n 10` and look for
`signed *.ko` lines followed by `OK: signed nvidia module is in the
initramfs` and `done`. That's the real signal to reboot on, not the
scriptlet output.

## Manual fallback if the hook isn't installed or something breaks

A new kernel means akmods rebuilds unsigned, compressed modules that won't
load. Boot the new kernel using the recovery line below first, then run
this.

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
sudo restorecon -RF .
sudo depmod -a "$KVER"
sudo dracut --force /boot/initramfs-$KVER.img "$KVER"
# verify: lsinitrd /boot/initramfs-$KVER.img | grep -E '/nvidia[^/]*\.ko$'
sudo reboot
```

## Recovery boot if a kernel update leaves you at a black screen before LUKS

At GRUB, highlight the Fedora entry, press `e`, go to the end of the
`linux ...` line, and append these parameters, then press `Ctrl-X` or `F10`
to boot.

```
rd.driver.blacklist=nvidia modprobe.blacklist=nvidia nouveau.modeset=1 nvidia.modeset=0
```

This blacklists nvidia and forces `nouveau` KMS instead, so the dGPU still
lights up the LUKS prompt and you get a console, with display working but
no CUDA. You can also append ` 3` to boot to a text console instead of the
desktop. Fix the underlying issue, for example by rerunning the hook
manually, then reboot normally.

## Alternative if you have a second GPU

If you have an integrated or secondary GPU available, routing the display
through it and leaving the NVIDIA card headless for compute sidesteps the
early-KMS and display complexity entirely. Points one through three above,
the signing steps, are still needed for CUDA to work under Secure Boot, but
point four, the display KMS work, becomes unnecessary.

## License

This project is licensed under the MIT license. See [LICENSE](LICENSE).
