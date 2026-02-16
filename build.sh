#!/usr/bin/env bash

workdir=$(pwd)

set -e
exec > >(tee $workdir/build.log) 2>&1
trap 'error "Failed at line $LINENO [$BASH_COMMAND]"' ERR

source $workdir/config.sh
source $workdir/functions.sh

export TZ="$TIMEZONE"
ulimit -s unlimited

KSRC="$workdir/ksrc"
log "Cloning kernel source from $(simplify_gh_url "$KERNEL_REPO")"
git clone -q --depth=1 $KERNEL_REPO -b $KERNEL_BRANCH $KSRC

cd $KSRC
LINUX_VERSION=$(make kernelversion)

cd $workdir

log "Setting KernelSU variant..."
VARIANT="KSUN"
ZIP_NAME=${ZIP_NAME//KVER/$LINUX_VERSION}
ZIP_NAME=${ZIP_NAME//VARIANT/$VARIANT}

CLANG_DIR="$workdir/clang"
if [[ -z "$CLANG_BRANCH" ]]; then
  log "🔽 Downloading Clang..."
  aria2c -q -c -x16 -s32 -k8M --file-allocation=falloc --timeout=60 --retry-wait=5 -o tarball "$CLANG_URL"
  mkdir -p "$CLANG_DIR"
  tar -xf tarball -C "$CLANG_DIR"
  rm tarball
  if [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l) -eq 1 ]] \
    && [[ $(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type f | wc -l) -eq 0 ]]; then
    SINGLE_DIR=$(find "$CLANG_DIR" -mindepth 1 -maxdepth 1 -type d)
    mv $SINGLE_DIR/* $CLANG_DIR/
    rm -rf $SINGLE_DIR
  fi
else
  log "🔽 Cloning Clang..."
  git clone --depth=1 -q "$CLANG_URL" -b "$CLANG_BRANCH" "$CLANG_DIR"
fi
export PATH="$CLANG_DIR/bin:$PATH"

COMPILER_STRING=$(clang -v 2>&1 | head -n 1 | sed 's/(https..*//' | sed 's/ version//')

if ! ls $CLANG_DIR/bin | grep -q "aarch64-linux-gnu"; then
  log "🔽 Cloning GCC..."
  git clone --depth=1 -q https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-gnu-9.3 $workdir/gcc
  export PATH="$workdir/gcc/bin:$PATH"
  CROSS_COMPILE_PREFIX="aarch64-linux-"
else
  CROSS_COMPILE_PREFIX="aarch64-linux-gnu-"
fi

cd $KSRC

# KernelSU setup
for KSU_PATH in drivers/staging/kernelsu drivers/kernelsu KernelSU; do
  if [[ -d $KSU_PATH ]]; then
    log "KernelSU driver found in $KSU_PATH, Removing..."
    KSU_DIR=$(dirname "$KSU_PATH")
    [[ -f "$KSU_DIR/Kconfig" ]] && sed -i '/kernelsu/d' $KSU_DIR/Kconfig
    [[ -f "$KSU_DIR/Makefile" ]] && sed -i '/kernelsu/d' $KSU_DIR/Makefile
    rm -rf $KSU_PATH
  fi
done

install_ksu pershoot/KernelSU-Next "dev"

cd $workdir

# ────────────────────────────────────────────────
# Two-step config generation (this fixes the "not clean" error)
# ────────────────────────────────────────────────
log "Configuring GKI kernel (two-step to avoid dirty tree)..."

cd $KSRC
mkdir -p out

# Step 1: config in root (creates necessary root files)
BUILD_CONFIG=common/build.config.gki make gki_defconfig || {
  log "Root gki_defconfig failed! Trying fallback..."
  make defconfig || exit 1
}

# Clean root files immediately
make ARCH=arm64 mrproper

# Step 2: config in out/
BUILD_CONFIG=common/build.config.gki O=out make gki_defconfig || exit 1

cd $workdir

# ────────────────────────────────────────────────
# BRANDING & CONFIG (direct in out/)
# ────────────────────────────────────────────────
log "🧹 Finalizing build configuration with branding..."

RELEASE_TAG="${GITHUB_REF_NAME:-HSKY4}"
INTERNAL_BRAND="-${KERNEL_NAME}-${RELEASE_TAG}-${VARIANT}"
export KERNEL_RELEASE_NAME="${KERNEL_NAME}-${RELEASE_TAG}-${LINUX_VERSION}-${VARIANT}"

if [ -f "$KSRC/common/build.config.gki" ]; then
    log "Patching build.config.gki..."
    sed -i 's/check_defconfig//' "$KSRC/common/build.config.gki"
fi

cd "$KSRC/out"

log "Applying config changes..."

../scripts/config --set-str CONFIG_LOCALVERSION "$INTERNAL_BRAND"
../scripts/config --disable CONFIG_LOCALVERSION_AUTO

../scripts/config --enable CONFIG_KSU
../scripts/config --disable CONFIG_KSU_MANUAL_SU

../scripts/config --enable CONFIG_MODULES

cd "$workdir"

log "✅ Internal kernel version set to: ${LINUX_VERSION}${INTERNAL_BRAND}"
log "✅ User-facing release name set to: $KERNEL_RELEASE_NAME"

export KBUILD_BUILD_USER="$USER"
export KBUILD_BUILD_HOST="$HOST"
export KBUILD_BUILD_TIMESTAMP=$(date)

if [[ -n "$GITHUB_ACTIONS" ]]; then
    JOBS=4
    log "GitHub Actions detected → using low parallelism (-j$JOBS)"
else
    JOBS=$(nproc --all)
fi

BUILD_FLAGS="-j$JOBS ARCH=arm64 LLVM=1 LLVM_IAS=1 O=out CROSS_COMPILE=$CROSS_COMPILE_PREFIX"

# Final clean before build
cd $KSRC
log "Final clean before compilation..."
make ARCH=arm64 mrproper
cd "$workdir"

# Build
log "Building kernel..."
cd $KSRC
BUILD_CONFIG=common/build.config.gki O=out make $BUILD_FLAGS Image modules || exit 1
cd $workdir

$KMI_CHECK "$KSRC/android/abi_gki_aarch64.xml" "$KSRC/out/Module.symvers"

# Post-compiling
cd $workdir

log "Cloning anykernel..."
git clone -q --depth=1 $ANYKERNEL_REPO -b $ANYKERNEL_BRANCH anykernel

if [[ $STATUS == "BETA" ]]; then
  BUILD_DATE=$(date -d "$KBUILD_BUILD_TIMESTAMP" +"%Y%m%d-%H%M")
  ZIP_NAME=${ZIP_NAME//BUILD_DATE/$BUILD_DATE}
  sed -i "s/kernel.string=.*/kernel.string=${KERNEL_RELEASE_NAME} (${BUILD_DATE})/g" anykernel/anykernel.sh
else
  ZIP_NAME=${ZIP_NAME//-BUILD_DATE/}
  sed -i "s/kernel.string=.*/kernel.string=${KERNEL_RELEASE_NAME}/g" anykernel/anykernel.sh
fi

cd anykernel
log "Zipping anykernel..."
cp "$KSRC/out/arch/arm64/boot/Image" .
zip -r9 "$workdir/$ZIP_NAME" ./*
cd -

if [[ $STATUS != "BETA" ]]; then
  echo "BASE_NAME=$KERNEL_NAME-$VARIANT" >> $GITHUB_ENV
  mkdir -p $workdir/artifacts
  mv $workdir/*.zip $workdir/artifacts 2>/dev/null || true
fi

if [[ $LAST_BUILD == "true" && $STATUS != "BETA" ]]; then
  (
    echo "LINUX_VERSION=$LINUX_VERSION"
    echo "KSU_NEXT_VERSION=$(gh api repos/KernelSU-Next/KernelSU-Next/tags --jq '.[0].name')"
    echo "KERNEL_NAME=$KERNEL_NAME"
    echo "RELEASE_REPO=$(simplify_gh_url "$GKI_RELEASES_REPO")"
  ) >> $workdir/artifacts/info.txt
fi

if [[ $STATUS == "BETA" ]]; then
  reply_file "$MESSAGE_ID" "$workdir/$ZIP_NAME"
  reply_file "$MESSAGE_ID" "$workdir/build.log"
else
  log "✅ Build Succeeded. Artifact link will be sent by GitHub Action."
fi

exit 0
