#!/bin/zsh
#
# Build MLX Metal kernels into default.metallib
# Mirrors the CMake build in mlx/backend/metal/kernels/CMakeLists.txt
#

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h}"
MLX_ROOT="${REPO_ROOT}/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
KERNELS_DIR="${MLX_ROOT}/mlx/backend/metal/kernels"
OUTPUT_PATH="${REPO_ROOT}/Sources/VoiceOverStudio/Resources/default.metallib"
AIR_DIR=$(mktemp -d)

trap 'rm -rf "${AIR_DIR}"' EXIT

if [[ ! -d "${KERNELS_DIR}" ]]; then
  echo "Missing MLX kernel sources at ${KERNELS_DIR}" >&2
  echo "Run 'swift package resolve' or 'swift build' first." >&2
  exit 1
fi

mkdir -p "${OUTPUT_PATH:h}"

METAL_FLAGS=(
  -x metal
  -std=metal3.2
  -Wall
  -Wextra
  -fno-fast-math
  -Wno-c++17-extensions
  -Wno-c++20-extensions
)

# ---------- kernel list (matches CMake's non-JIT build) ----------
# Always-built kernels
KERNELS=(
  arg_reduce
  conv
  gemv
  layer_norm
  random
  rms_norm
  rope
  scaled_dot_product_attention
  fence
)

# Non-JIT kernels (all the rest)
KERNELS+=(
  arange
  binary
  binary_two
  copy
  fft
  reduce
  quantized
  fp_quantized
  scan
  softmax
  logsumexp
  sort
  ternary
  unary
  gemv_masked
  steel/conv/kernels/steel_conv
  steel/conv/kernels/steel_conv_general
  steel/gemm/kernels/steel_gemm_fused
  steel/gemm/kernels/steel_gemm_gather
  steel/gemm/kernels/steel_gemm_masked
  steel/gemm/kernels/steel_gemm_splitk
  steel/gemm/kernels/steel_gemm_segmented
  steel/attn/kernels/steel_attention
)

# ---------- compile each .metal → .air ----------
AIR_FILES=()
FAIL=0

for kernel in "${KERNELS[@]}"; do
  src="${KERNELS_DIR}/${kernel}.metal"
  # Use just the stem as the .air name (flatten subdirectories)
  stem="${kernel##*/}"
  air="${AIR_DIR}/${stem}.air"

  if [[ ! -f "${src}" ]]; then
    echo "WARNING: ${src} not found, skipping" >&2
    continue
  fi

  echo "  Compiling ${kernel}.metal → ${stem}.air"
  if ! xcrun -sdk macosx metal "${METAL_FLAGS[@]}" \
       -c "${src}" \
       -I"${MLX_ROOT}" \
       -o "${air}"; then
    echo "ERROR: failed to compile ${kernel}.metal" >&2
    FAIL=1
    continue
  fi
  AIR_FILES+=("${air}")
done

if (( FAIL )); then
  echo "Some kernels failed to compile — see errors above." >&2
  exit 1
fi

if (( ${#AIR_FILES[@]} == 0 )); then
  echo "No .air files produced — nothing to link." >&2
  exit 1
fi

# ---------- link .air files → metallib ----------
echo "  Linking ${#AIR_FILES[@]} .air files → default.metallib"
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "${OUTPUT_PATH}"

echo "Built ${OUTPUT_PATH}  (${#AIR_FILES[@]} kernels)"