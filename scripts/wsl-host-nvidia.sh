#!/bin/bash
# wsl-host-nvidia.sh — Configure a WSL host for container-only NVIDIA GPU inference.
#
# In WSL, the Windows host driver exposes the GPU via /dev/dxg and /usr/lib/wsl/lib/.
# Containers only need nvidia-container-toolkit + a fresh /etc/cdi/nvidia.yaml.
# Installing host NVIDIA driver/DKMS packages (or Debian's nvidia-cuda-toolkit, which
# hard-depends on libcuda1 -> nvidia-kernel-dkms) breaks apt/dpkg on WSL kernels, and
# host CUDA toolkits are redundant when running HyperQwen in Docker.
#
# Usage:
#   bash scripts/wsl-host-nvidia.sh            # audit + apply Option A cleanup & CDI sync
#   bash scripts/wsl-host-nvidia.sh --check    # read-only check (exit 1 if changes needed)
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
elif [ $# -gt 0 ]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

if ! grep -qi microsoft /proc/version 2>/dev/null; then
  echo "Not running on WSL; skipping WSL container-only NVIDIA setup."
  exit 0
fi

PIN_FILE="/etc/apt/preferences.d/99-wsl-no-nvidia-kmod"
CUDA_REPO_GLOB="/etc/apt/sources.list.d/cuda-debian13-x86_64.list"

# Explicit purge patterns: remove host driver, DKMS, X11 NVIDIA, Debian nvidia-cuda-toolkit,
# and host cuda-toolkit-13* packages while keeping nvidia-container-toolkit + libnvidia-container*.
PURGE_PATTERNS=(
  "nvidia-driver"
  "nvidia-driver-*"
  "nvidia-kernel-*"
  "nvidia-open"
  "nvidia-open-*"
  "nvidia-dkms-*"
  "dkms"
  "cuda-drivers"
  "cuda-drivers-*"
  "xserver-xorg-video-nvidia"
  "xserver-xorg-video-nvidia-*"
  "firmware-nvidia-gsp"
  "nvidia-modprobe"
  "nvidia-persistenced"
  "nvidia-powerd"
  "nvidia-smi"
  "nvidia-settings"
  "nvidia-egl-icd"
  "nvidia-vulkan-icd"
  "nvidia-vdpau-driver"
  "nvidia-alternative"
  "nvidia-support"
  "nvidia-installer-cleanup"
  "nvidia-legacy-check"
  "nvidia-opencl-*"
  "nvidia-openjdk-8-jre"
  "libnvidia-ml1"
  "libnvidia-ml-dev"
  "libnvidia-cfg1"
  "libnvidia-glcore"
  "libnvidia-eglcore"
  "libnvidia-ptxjitcompiler1"
  "libnvidia-compute-*"
  "libnvidia-allocator1"
  "libnvidia-api1"
  "libnvidia-gpucomp"
  "libnvidia-glvkspirv"
  "libnvidia-ngx1"
  "libnvidia-pkcs11-openssl3"
  "libnvidia-rtcore"
  "libnvidia-vksc-core"
  "libnvidia-egl-*"
  "libegl-nvidia0"
  "libgles-nvidia1"
  "libgles-nvidia2"
  "libglx-nvidia0"
  "libnvcuvid1"
  "libxnvctrl0"
  "glx-alternative-nvidia"
  "libcuda1"
  "libcudart12"
  "nvidia-cuda-toolkit"
  "nvidia-cuda-toolkit-doc"
  "nvidia-cuda-dev"
  "nvidia-cuda-gdb"
  "nvidia-profiler"
  "nvidia-visual-profiler"
  "cuda-keyring"
  "cuda-toolkit-*"
  "cuda-command-line-tools-*"
  "cuda-compiler-*"
  "cuda-crt-*"
  "cuda-ctadvisor-*"
  "cuda-cudart-*"
  "cuda-culibos-*"
  "cuda-cuobjdump-*"
  "cuda-cupti-*"
  "cuda-cuxxfilt-*"
  "cuda-driver-dev-*"
  "cuda-gdb-*"
  "cuda-libraries-*"
  "cuda-nsight-*"
  "cuda-nvcc-*"
  "cuda-nvdisasm-*"
  "cuda-nvml-*"
  "cuda-nvprune-*"
  "cuda-nvrtc-*"
  "cuda-nvtx-*"
  "cuda-opencl-*"
  "cuda-profiler-*"
  "cuda-sandbox-*"
  "cuda-sanitizer-*"
  "cuda-tileiras-*"
  "cuda-tools-*"
  "cuda-visual-tools-*"
  "cccl-13-*"
  "gds-tools-13-*"
  "libcublas-13-*"
  "libcublas-dev-13-*"
  "libcufft-13-*"
  "libcufft-dev-13-*"
  "libcufile-13-*"
  "libcufile-dev-13-*"
  "libcuobjclient-13-*"
  "libcuobjclient-dev-13-*"
  "libcurand-13-*"
  "libcurand-dev-13-*"
  "libcusolver-13-*"
  "libcusolver-dev-13-*"
  "libcusparse-13-*"
  "libcusparse-dev-13-*"
  "libnpp-13-*"
  "libnpp-dev-13-*"
  "libnvfatbin-13-*"
  "libnvfatbin-dev-13-*"
  "libnvjitlink-13-*"
  "libnvjitlink-dev-13-*"
  "libnvjpeg-13-*"
  "libnvjpeg-dev-13-*"
  "libnvvm-13-*"
  "nsight-systems-*"
  "nsight-compute-*"
)

mapfile -t PURGE_LIST < <(
  dpkg-query -W -f='${db:Status-Abbrev}\t${Package}\n' "${PURGE_PATTERNS[@]}" 2>/dev/null |
    awk '$1 !~ /^(un|pn)$/ {print $2}' |
    sort -u
)

NEEDS_PIN_REMOVAL=0
[ -e "$PIN_FILE" ] && NEEDS_PIN_REMOVAL=1

NEEDS_REPO_REMOVAL=0
shopt -s nullglob
CUDA_REPO_FILES=(${CUDA_REPO_GLOB}*)
shopt -u nullglob
[ "${#CUDA_REPO_FILES[@]}" -gt 0 ] && NEEDS_REPO_REMOVAL=1

NEEDS_CDI_SYNC=0
if command -v nvidia-ctk >/dev/null 2>&1; then
  if [ ! -f /etc/cdi/nvidia.yaml ]; then
    NEEDS_CDI_SYNC=1
  else
    while IFS= read -r p; do
      if [ ! -e "$p" ]; then
        NEEDS_CDI_SYNC=1
        break
      fi
    done < <(grep -o '/usr/lib/wsl/drivers/[^: "]*' /etc/cdi/nvidia.yaml 2>/dev/null | sort -u)
    if [ "$NEEDS_CDI_SYNC" -eq 0 ]; then
      ACTIVE_DRIVER="$(ls -d /usr/lib/wsl/drivers/nv_dispi.inf_amd64_*/libcuda.so.1.1 2>/dev/null | head -n 1 | xargs -r dirname)"
      CURRENT_DRIVER="$(grep -o '/usr/lib/wsl/drivers/nv_dispi.inf_amd64_[^/]*' /etc/cdi/nvidia.yaml 2>/dev/null | head -n 1 || true)"
      if [ -n "$ACTIVE_DRIVER" ] && [ "$CURRENT_DRIVER" != "$ACTIVE_DRIVER" ]; then
        NEEDS_CDI_SYNC=1
      fi
    fi
  fi
fi

NEEDS_TOOLKIT=0
if ! dpkg-query -W -f='${Status}\n' nvidia-container-toolkit 2>/dev/null | grep -qx 'install ok installed'; then
  NEEDS_TOOLKIT=1
fi

if [ "${#PURGE_LIST[@]}" -eq 0 ] && [ "$NEEDS_PIN_REMOVAL" -eq 0 ] && [ "$NEEDS_REPO_REMOVAL" -eq 0 ] && [ "$NEEDS_CDI_SYNC" -eq 0 ] && [ "$NEEDS_TOOLKIT" -eq 0 ]; then
  echo "WSL NVIDIA host state is clean (container-only with nvidia-container-toolkit)."
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "WSL NVIDIA host drift detected:"
  [ "${#PURGE_LIST[@]}" -gt 0 ] && printf '  purge (%d packages): %s\n' "${#PURGE_LIST[@]}" "${PURGE_LIST[*]}"
  [ "$NEEDS_PIN_REMOVAL" -eq 1 ] && echo "  remove stale pin: $PIN_FILE"
  [ "$NEEDS_REPO_REMOVAL" -eq 1 ] && echo "  remove CUDA apt repo files: ${CUDA_REPO_FILES[*]}"
  [ "$NEEDS_TOOLKIT" -eq 1 ] && echo "  missing package: nvidia-container-toolkit"
  [ "$NEEDS_CDI_SYNC" -eq 1 ] && echo "  regenerate /etc/cdi/nvidia.yaml"
  exit 1
fi

sudo -v

if [ "$NEEDS_PIN_REMOVAL" -eq 1 ]; then
  sudo rm -f "$PIN_FILE"
fi

if [ "$NEEDS_REPO_REMOVAL" -eq 1 ]; then
  sudo rm -f "${CUDA_REPO_FILES[@]}"
fi

if [ "${#PURGE_LIST[@]}" -gt 0 ]; then
  printf 'Purging %d host NVIDIA/CUDA package(s)...\n' "${#PURGE_LIST[@]}"
  sudo apt-get purge -y "${PURGE_LIST[@]}"
  sudo apt-get autoremove --purge -y
fi

sudo dpkg --configure -a
sudo apt-get update

if [ "$NEEDS_TOOLKIT" -eq 1 ]; then
  sudo apt-get install -y nvidia-container-toolkit
  if command -v service >/dev/null 2>&1; then
    sudo service docker restart || true
  fi
fi

if [ "$NEEDS_CDI_SYNC" -eq 1 ] && command -v nvidia-ctk >/dev/null 2>&1; then
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
fi

echo "WSL container-only NVIDIA host setup complete."
