#!/usr/bin/env bash
#
# Installs the NVIDIA auto-sign hook (4 pieces), enables the boot service, and
# runs a one-shot test against the current kernel.
#
#   sudo bash install.sh

set -euo pipefail
[[ ${EUID} -eq 0 ]] || { echo "Run as root: sudo bash $0" >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "== Installing files =="
install -D -m 0755 "${SRC}/nvidia-akmods-sign"        /usr/local/sbin/nvidia-akmods-sign
install -D -m 0755 "${SRC}/nvidia-akmods-history"     /usr/local/sbin/nvidia-akmods-history
install -D -m 0755 "${SRC}/96-nvidia-sign.install"    /etc/kernel/install.d/96-nvidia-sign.install
install -D -m 0644 "${SRC}/nvidia-akmods-sign.service" /etc/systemd/system/nvidia-akmods-sign.service
restorecon -F /usr/local/sbin/nvidia-akmods-sign \
              /usr/local/sbin/nvidia-akmods-history \
              /etc/kernel/install.d/96-nvidia-sign.install \
              /etc/systemd/system/nvidia-akmods-sign.service 2>/dev/null || true
echo "  /usr/local/sbin/nvidia-akmods-sign"
echo "  /usr/local/sbin/nvidia-akmods-history"
echo "  /etc/kernel/install.d/96-nvidia-sign.install"
echo "  /etc/systemd/system/nvidia-akmods-sign.service"
echo

echo "== Enabling boot service =="
systemctl daemon-reload
systemctl enable nvidia-akmods-sign.service
echo

echo "== Test run against current kernel ($(uname -r)) =="
/usr/local/sbin/nvidia-akmods-sign "$(uname -r)"
echo
echo "== Recent log =="
journalctl -t nvidia-akmods-sign -n 20 --no-pager 2>/dev/null || true
echo
echo "== Running history =="
/usr/local/sbin/nvidia-akmods-history
echo
echo "Install complete."
