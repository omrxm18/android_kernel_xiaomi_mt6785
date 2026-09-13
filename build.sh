#!/usr/bin/env bash
set -euo pipefail

# ─── Variables ────────────────────────────────────────────────────────────────
OUT=out
LOG=build.log
TIMESTAMP_LOG="build-$(date +%Y%m%d-%H%M%S).log"
ERRORLOG=errors.log
ARCH=arm64
SUBARCH=arm64
JOBS=$(nproc --all)
DEFCONFIG=rosemary_defconfig
KERNEL_IMAGE=out/arch/arm64/boot/Image.gz
ANYKERNEL_DIR=builds/AnyKernel3
ZIP_OUT="$(pwd)/$(dirname "$ANYKERNEL_DIR")"
LOGDIR="$(pwd)/logs"
TOOLCHAIN="$HOME/toolchains/clang-r563880/bin"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolchain)
      TOOLCHAIN="$2"
      shift 2
      ;;
    --clean)
      make mrproper O="$OUT" > /dev/null 2>&1 || true
      make mrproper > /dev/null 2>&1 || true
      rm -rf "$OUT" "$LOG" "$ERRORLOG"
      echo "Cleaned build artifacts."
      exit 0
      ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo "Options:"
      echo "  --toolchain <path>   Path to Clang toolchain (default: $TOOLCHAIN)"
      echo "  --clean              Clean previous build artifacts"
      echo "  -j, --jobs           Number of build jobs"
      echo "  -d, --defconfig      Specify your own defconfig"
      echo "  -h, --help           Show this help message and exit"
      exit 0
      ;;
    --jobs|-j)
      JOBS="$2"
      shift 2
      ;;
    --defconfig|-d)
    DEFCONFIG="$2"
    shift 2
    ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# ─── Toolchain ────────────────────────────────────────────────────────────────
export ARCH SUBARCH
export CC=clang
export LD=ld.lld
export LLVM=1
export LLVM_IAS=1
export PATH="$TOOLCHAIN:$PATH"

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${CYAN}[BUILD]${NC} $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ WARN ]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ─── Banner ───────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}====================\n By omrxdev\nTelegram: @omrxm\n====================${NC}\n"

# ─── Sanity checks ────────────────────────────────────────────────────────────
[[ ! -f "$TOOLCHAIN/clang" ]] && { error "Toolchain not found at $TOOLCHAIN/clang Please run with --toolchain to configure it, or set it manually in the build script."; exit 1; }

if [[ ! -d "$ANYKERNEL_DIR"   ]]; then
  warn "AnyKernel3 not found at $ANYKERNEL_DIR. creating..."
  mkdir -p "$ANYKERNEL_DIR"
  git clone -q https://github.com/osm0sis/AnyKernel3 $ANYKERNEL_DIR

# First-time setup: correct device identifiers in AnyKernel3 metadata
  sed -i \
    -e 's/^\(device\.name[345]\)=.*/\1=/' \
    -e 's/^device\.name1=.*/device.name1=rosemary/' \
    -e 's/^device\.name2=.*/device.name2=secret/' \
    "$ANYKERNEL_DIR/anykernel.sh"
fi

log "Toolchain: $("$TOOLCHAIN/clang" --version | head -1)"
sleep 0.5

# ─── archive logs ────────────────────────────────────────────────────────────────────
[[ ! -d $LOGDIR ]] && { log "Creating log dir"; mkdir "$LOGDIR"; }

if [[ -f $LOG ]]; then
  cp "$LOG" "$LOGDIR"/"$TIMESTAMP_LOG"
fi
# ─── Clean ────────────────────────────────────────────────────────────────────
log "Cleaning previous build artifacts..."
rm -f "$LOG" "$ERRORLOG"
sleep 0.5

# ─── Configure ────────────────────────────────────────────────────────────────
log "Configuring with $DEFCONFIG..."
make O="$OUT" "$DEFCONFIG"

# ─── Build ────────────────────────────────────────────────────────────────────
KVER=$(make O="$OUT" -s kernelversion 2>/dev/null || echo "unknown")
KVER="${KVER:-unknown}"
ZIP_NAME="kernel-${KVER}-$(date +%Y%m%d-%H%M).zip"

log "Kernel Version: ${KVER}"
START_TIME=$(date +%s)

set +e
make O="$OUT" -j"$JOBS" 2>&1 | tee "$LOG"
BUILD_STATUS=${PIPESTATUS[0]}
set -e

ELAPSED=$(( $(date +%s) - START_TIME ))

# ─── Result ───────────────────────────────────────────────────────────────────
if [[ "$BUILD_STATUS" -ne 0 ]]; then
    error "Build FAILED in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

    grep -A 2 -E \
        '(^[^:]+\.[chS]:[0-9]+:[0-9]+: error:|^clang.*: error:)' \
        "$LOG" > "$ERRORLOG" || true
    grep -A 5 -E \
          '(^ld\.lld: error:|undefined symbol|undefined reference)' \
          "$LOG" >> "$ERRORLOG" || true

    [[ -s "$ERRORLOG" ]] && warn "Errors written to $ERRORLOG" \
                        || warn "No errors extracted — check $LOG manually."

    exit "$BUILD_STATUS"
fi

ok "Build completed in $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"

# ─── Package ──────────────────────────────────────────────────────────────────
[[ ! -f "$KERNEL_IMAGE" ]] && { error "Kernel image not found at $KERNEL_IMAGE"; exit 1; }

log "Packaging AnyKernel3 zip..."
rm -f "$ANYKERNEL_DIR"/Image.gz "$ANYKERNEL_DIR"/Image
cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/"

pushd "$ANYKERNEL_DIR" > /dev/null
zip -r9 "$ZIP_OUT/$ZIP_NAME" -- * -x '*.zip'
popd > /dev/null

rm -f "$ANYKERNEL_DIR"/Image.gz "$ANYKERNEL_DIR"/Image

ENTRY_COUNT=$(unzip -l "$ZIP_OUT/$ZIP_NAME" | tail -1 | awk '{print $2}')
if [[ "$ENTRY_COUNT" -lt 5 ]]; then
  error "Zip looks suspiciously small ($ENTRY_COUNT entries) — check $ANYKERNEL_DIR contents."
  exit 1
fi

ok "Done! Output: $ZIP_OUT/$ZIP_NAME"

echo
log "──────── Build Summary ────────"
log "Kernel:   $KVER"
log "Jobs:     $JOBS"
log "Time:     $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s"
log "Output:   $ZIP_OUT/$ZIP_NAME"
log "────────────────────────────────"
