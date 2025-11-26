#!/bin/bash

set -e

DEVICES=("beyond0lte" "beyond1lte" "beyond2lte" "beyondx" "d1" "d1x" "d2s" "d2x" "f62")
KERNEL_DIR="$(pwd)"
OUT_BASE="$KERNEL_DIR/out"
AK3_DIR="$KERNEL_DIR/AnyKernel"
AK3_REPO="https://github.com/LeDrew2017/Anykernel.git"
TOOLCHAIN_DIR="/home/jay/toolchains/clang-21"
GITHUB_REPO="git@github.com:LeDrew2017/FreeRunnerKernel.git"
RELEASE_DIR="$KERNEL_DIR/releases"

export PATH="$TOOLCHAIN_DIR/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="Jay"
export KBUILD_BUILD_HOST="CachyOS"

if command -v ccache &> /dev/null; then
    export CC="ccache clang"
    export CXX="ccache clang++"
    echo "🚀 Using ccache to speed up compilation."
else
    export CC="clang"
    export CXX="clang++"
fi

CONFIG_FRAGMENTS=()
RELEASE_TAG_VERSION=""
KSU_VERSION=""
SUKISU_VERSION=""

perform_clean() {
    echo "🧹 Cleaning all output directories..."
    rm -rf "$OUT_BASE"
    echo "✅ Clean complete."
}

print_header() {
    echo -e "\n=========================================="
    echo "$1"
    echo "=========================================="
}

print_section() {
    echo -e "\n--- $1 ---"
}

# Detect KernelSU-Next version from GitHub Releases
detect_kernelsu_version() {
    echo "🔍 Detecting KernelSU-Next version from GitHub..."

    if ! command -v curl &> /dev/null; then
        echo "❌ ERROR: curl is required for version detection"
        exit 1
    fi

    local latest_release=$(curl -s "https://api.github.com/repos/KernelSU-Next/KernelSU-Next/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

    if [[ -n "$latest_release" ]]; then
        KSU_VERSION="$latest_release"
        echo "✅ KernelSU-Next version: $KSU_VERSION"
        return 0
    else
        echo "❌ ERROR: Could not detect KernelSU-Next version from GitHub releases"
        exit 1
    fi
}

# Detect Sukisu version from GitHub Releases
detect_sukisu_version() {
    echo "🔍 Detecting Sukisu version from GitHub..."

    if ! command -v curl &> /dev/null; then
        echo "❌ ERROR: curl is required for version detection"
        exit 1
    fi

    local latest_release=$(curl -s "https://api.github.com/repos/SukiSU-Ultra/SukiSU-Ultra/releases/latest" 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"tag_name": "([^"]+)".*/\1/')

    if [[ -n "$latest_release" ]]; then
        SUKISU_VERSION="$latest_release"
        echo "✅ Sukisu version: $SUKISU_VERSION"
        return 0
    else
        echo "❌ ERROR: Could not detect Sukisu version from GitHub releases"
        exit 1
    fi
}

apply_kpm_patch() {
    local image_to_patch="$1"

    if [[ "${CONFIG_FRAGMENTS[*]}" != *"sukisu.config"* ]]; then
        echo "INFO: Skipping KPM patch (sukisu not selected)"
        return 0
    fi

    echo -e "\n🔧 Applying KPM patch..."

    local KPM_URL="https://raw.githubusercontent.com/ShirkNeko/SukiSU_patch/refs/heads/main/kpm/patch_linux"
    local MAGISKBOOT="$KERNEL_DIR/magiskboot/magiskboot"
    local WORK_DIR="$KERNEL_DIR/kpm_work"

    if [[ ! -f "$MAGISKBOOT" ]] || [[ ! -x "$MAGISKBOOT" ]]; then
        echo "❌ ERROR: magiskboot not found or not executable at $MAGISKBOOT"
        return 1
    fi

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    if ! curl -LSs "$KPM_URL" -o patch; then
        echo "❌ ERROR: Failed to download KPM patch script"
        cd "$KERNEL_DIR"
        rm -rf "$WORK_DIR"
        return 1
    fi
    chmod +x patch

    if [[ ! -f "$image_to_patch" ]]; then
        echo "❌ ERROR: Kernel image not found at $image_to_patch"
        cd "$KERNEL_DIR"
        rm -rf "$WORK_DIR"
        return 1
    fi

    cp "$image_to_patch" .
    local img_file=$(basename "$image_to_patch")

    if [[ "$img_file" == *"Image.gz-dtb" ]]; then
        echo "INFO: Extracting kernel from Image.gz-dtb..."
        if ! "$MAGISKBOOT" split "$img_file" || [[ ! -f kernel ]]; then
            echo "❌ ERROR: Failed to split $img_file"
            cd "$KERNEL_DIR" && rm -rf "$WORK_DIR"
            return 1
        fi
        cp kernel Image
    elif [[ "$img_file" == *"Image.gz" ]]; then
        echo "INFO: Decompressing Image.gz..."
        if ! "$MAGISKBOOT" decompress "$img_file" Image 2>/dev/null && ! gunzip -c "$img_file" > Image 2>/dev/null; then
            echo "❌ ERROR: Failed to decompress $img_file"
            cd "$KERNEL_DIR" && rm -rf "$WORK_DIR"
            return 1
        fi
    elif [[ "$img_file" == *"Image" ]]; then
        cp "$img_file" Image
    else
        echo "❌ ERROR: Unsupported kernel image format: $img_file"
        cd "$KERNEL_DIR" && rm -rf "$WORK_DIR"
        return 1
    fi

    if [[ ! -f Image ]]; then
        echo "❌ ERROR: Image file not found after extraction"
        cd "$KERNEL_DIR" && rm -rf "$WORK_DIR"
        return 1
    fi

    echo "INFO: Patching kernel..."
    if ./patch 2>&1; then
        [[ -f oImage ]] && mv oImage Image
    else
        echo "❌ ERROR: KPM patch script failed"
        cd "$KERNEL_DIR" && rm -rf "$WORK_DIR"
        return 1
    fi

    echo "INFO: Repacking kernel image..."
    if [[ "$img_file" == *"Image.gz-dtb" ]]; then
        if ! "$MAGISKBOOT" compress=gzip Image kernel_new && ! gzip -c Image > kernel_new; then
            echo "❌ ERROR: Failed to compress patched Image"
            cd "$KERNEL_DIR" && rm -rf "$WORK_DIR"
            return 1
        fi
        if [[ ! -f kernel_dtb ]]; then
            echo "❌ ERROR: kernel_dtb not found, cannot recreate Image.gz-dtb"
            cd "$KERNEL_DIR" && rm -rf "$WORK_DIR"
            return 1
        fi
        cat kernel_new kernel_dtb > Image.gz-dtb
        cp Image.gz-dtb "$image_to_patch"
    elif [[ "$img_file" == *"Image.gz" ]]; then
        if ! gzip -c Image > Image.gz; then
            echo "❌ ERROR: Failed to compress patched Image"
            cd "$KERNEL_DIR" && rm -rf "$WORK_DIR"
            return 1
        fi
        cp Image.gz "$image_to_patch"
    else
        cp Image "$image_to_patch"
    fi

    echo "✅ INFO: KPM patching completed successfully"
    cd "$KERNEL_DIR"
    rm -rf "$WORK_DIR"
    return 0
}

build_device() {
    local device="$1"
    local kernel_version="$2"
    local release_subdir="$3"
    local defconfig="exynos9820-${device}_defconfig"
    local out_dir="${OUT_BASE}/${device}"
    local image_path="$out_dir/arch/arm64/boot/Image"

    echo -e "\n🔧 Starting build for: $device"

    make -C "$KERNEL_DIR" O="$out_dir" "$defconfig" LLVM=1

    if [ ${#CONFIG_FRAGMENTS[@]} -gt 0 ]; then
        echo "🔀 Merging config fragments: ${CONFIG_FRAGMENTS[*]}"
        "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -O "$out_dir" \
            "$out_dir/.config" "${CONFIG_FRAGMENTS[@]}"
        make -C "$KERNEL_DIR" O="$out_dir" olddefconfig LLVM=1
    fi

    local build_start=$(date +%s)
    make -C "$KERNEL_DIR" O="$out_dir" -j"$(nproc)" LLVM=1
    local build_end=$(date +%s)
    local duration=$((build_end - build_start))

    if [ ! -f "$image_path" ]; then
        echo "❌ Build FAILED for $device after $(printf "%02d:%02d" $((duration/60)) $((duration%60)))"
        return 1
    fi
    echo "✅ Build completed for $device in $(printf "%02d:%02d" $((duration/60)) $((duration%60)))"

    apply_kpm_patch "$image_path" || {
        echo "❌ ERROR: KPM patching failed for $device"
        return 1
    }

    package_kernel "$device" "$kernel_version" "$image_path" "$release_subdir"
}

package_kernel() {
    local device="$1"
    local kernel_version="$2"
    local image_path="$3"
    local release_subdir="$4"

    echo "🧹 Cleaning up old kernel image from AnyKernel directory..."
    rm -f "${AK3_DIR}/Image"

    echo "📦 Copying new kernel Image to AnyKernel directory..."
    cp "$image_path" "$AK3_DIR/Image"

    pushd "$AK3_DIR" > /dev/null

    local version_suffix=""

    if [ ${#CONFIG_FRAGMENTS[@]} -gt 0 ]; then
        for fragment in "${CONFIG_FRAGMENTS[@]}"; do
            local frag_name=$(basename "$fragment" .config)

            # Add version info to suffix
            if [[ "$frag_name" == "ksu" ]] && [[ -n "$KSU_VERSION" ]]; then
                version_suffix="${version_suffix}-KernelSU-Next-${KSU_VERSION}"
            elif [[ "$frag_name" == "sukisu" ]] && [[ -n "$SUKISU_VERSION" ]]; then
                version_suffix="${version_suffix}-SukiSU-Ultra-${SUKISU_VERSION}"
            fi
        done
    fi

    local zip_name="FrEeRuNnErKeRnEl-${device}-${kernel_version}${version_suffix}-Anykernel3.zip"
    echo "📦 Creating AnyKernel zip: $zip_name..."
    zip -r9 "$zip_name" * -x .git\* README.md\* > /dev/null

    if [ -f "$zip_name" ]; then
        mkdir -p "$release_subdir"
        mv "$zip_name" "$release_subdir/"
        echo "✅ Packaged $zip_name successfully."
        rm -f Image
    else
        echo "❌ Failed to create AnyKernel zip for $device."
    fi

    popd > /dev/null
}

build_selected_devices() {
    local selected_devices=("$@")

    print_header "🚀 Building selected devices: ${selected_devices[*]}"

    local release_subdir="$RELEASE_DIR"
    if [ ${#CONFIG_FRAGMENTS[@]} -gt 0 ]; then
        local config_suffix=""
        for fragment in "${CONFIG_FRAGMENTS[@]}"; do
            local frag_name=$(basename "$fragment" .config)
            config_suffix="${config_suffix}${frag_name}"
        done
        release_subdir="$RELEASE_DIR/$config_suffix"
    fi
    mkdir -p "$release_subdir"

    local first_device=true
    for device in "${selected_devices[@]}"; do
        echo "=================================================="
        echo "Processing: $device"

        local defconfig_path="arch/arm64/configs/exynos9820-${device}_defconfig"
        if [ ! -f "$defconfig_path" ]; then
            echo "⚠️ Defconfig for $device not found. Skipping."
            continue
        fi

        local raw_version=$(grep 'CONFIG_LOCALVERSION=' "$defconfig_path" | cut -d'"' -f2)
        local kernel_version=$(echo "$raw_version" | grep -oP 'v[0-9]+(\.[0-9]+)*')

        if [ -z "$kernel_version" ]; then
            echo "⚠️ Could not extract kernel version for $device. Skipping."
            continue
        fi
        echo "📖 Detected kernel version for $device: $kernel_version"

        if [ "$first_device" = true ]; then
            RELEASE_TAG_VERSION="$kernel_version"
            first_device=false
        fi

        build_device "$device" "$kernel_version" "$release_subdir"
    done

    echo -e "\n✅ All selected device builds complete."
}

create_github_release() {
    if [ -z "$RELEASE_TAG_VERSION" ]; then
        echo "⚠️ Kernel version for release tag not set. Skipping release."
        return
    fi

    print_section "GitHub Release"
    echo "Select which builds to release:"
    echo "  1) All builds in releases folder"
    echo "  2) Only KernelSU-Next builds (releases/kernelsu)"
    echo "  3) Only Sukisu builds (releases/sukisu)"
    echo "  4) Both KernelSU-Next and Sukisu builds"
    read -p "Select option (1-4) [default: 1]: " release_choice

    local zip_files=()
    case "$release_choice" in
        2)
            if [ -d "$RELEASE_DIR/kernelsu" ]; then
                while IFS= read -r -d '' file; do
                    zip_files+=("$file")
                done < <(find "$RELEASE_DIR/kernelsu" -name "*.zip" -print0)
                echo "✔ Selected: KernelSU-Next builds only"
            else
                echo "⚠️ KernelSU-Next folder not found."
            fi
            ;;
        3)
            if [ -d "$RELEASE_DIR/sukisu" ]; then
                while IFS= read -r -d '' file; do
                    zip_files+=("$file")
                done < <(find "$RELEASE_DIR/sukisu" -name "*.zip" -print0)
                echo "✔ Selected: Sukisu builds only"
            else
                echo "⚠️ Sukisu folder not found."
            fi
            ;;
        4)
            if [ -d "$RELEASE_DIR/kernelsu" ]; then
                while IFS= read -r -d '' file; do
                    zip_files+=("$file")
                done < <(find "$RELEASE_DIR/kernelsu" -name "*.zip" -print0)
            fi
            if [ -d "$RELEASE_DIR/sukisu" ]; then
                while IFS= read -r -d '' file; do
                    zip_files+=("$file")
                done < <(find "$RELEASE_DIR/sukisu" -name "*.zip" -print0)
            fi
            echo "✔ Selected: Both KernelSU-Next and Sukisu builds"
            ;;
        1|"")
            while IFS= read -r -d '' file; do
                zip_files+=("$file")
            done < <(find "$RELEASE_DIR" -name "*.zip" -print0)
            echo "✔ Selected: All builds"
            ;;
        *)
            echo "❌ Invalid selection. Using all builds."
            while IFS= read -r -d '' file; do
                zip_files+=("$file")
            done < <(find "$RELEASE_DIR" -name "*.zip" -print0)
            ;;
    esac

    if [ ${#zip_files[@]} -eq 0 ]; then
        echo "⚠️ No .zip files found. Skipping release."
        return
    fi

    read -p "Do you want to create a GitHub release with tag '$RELEASE_TAG_VERSION'? (y/N): " choice
    if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
        echo "Skipping GitHub release."
        return
    fi

    read -p "Enter Release Title: " release_title

    local temp_notes_file=$(mktemp)
    echo "Press Enter to open your default editor (${EDITOR:-nano}) to write the release notes."
    read -r
    ${EDITOR:-nano} "$temp_notes_file"

    if [ ! -s "$temp_notes_file" ]; then
        echo "❌ Release notes are empty. Aborting release."
        rm "$temp_notes_file"
        exit 1
    fi

    echo "🚀 Creating release and uploading artifacts..."
    gh release create "$RELEASE_TAG_VERSION" "${zip_files[@]}" \
        -R "$GITHUB_REPO" \
        --title "$release_title" \
        --notes-file "$temp_notes_file"

    echo "✅ GitHub release created successfully."
    rm "$temp_notes_file"
}

CONFIG_CHOICE=""

get_config_selection() {
    print_section "Config Fragment Selection"
    echo "Available config fragments:"
    echo "  1) None (default build)"
    echo "  2) KernelSU-Next (ksu.config)"
    echo "  3) Sukisu (sukisu.config)"
    echo "  4) Both KernelSU-Next + Sukisu (separate builds)"
    read -p "Select config option (1-4) [default: 1]: " config_choice

    # Default to 1 if empty
    config_choice=${config_choice:-1}

    case "$config_choice" in
        2)
            echo "✔ Selected: KernelSU-Next"
            CONFIG_CHOICE="2"
            ;;
        3)
            echo "✔ Selected: Sukisu"
            CONFIG_CHOICE="3"
            ;;
        4)
            echo "✔ Selected: Both KernelSU-Next + Sukisu (will build separately)"
            CONFIG_CHOICE="4"
            ;;
        1)
            echo "✔ Selected: Default build (no fragments)"
            CONFIG_CHOICE="1"
            ;;
        *)
            echo "❌ Invalid selection. Using default build."
            CONFIG_CHOICE="1"
            ;;
    esac
}

get_device_selection() {
    echo -e "\nPlease select device(s) to build:" >&2
    for i in "${!DEVICES[@]}"; do
        printf "  %2d) %s\n" "$((i+1))" "${DEVICES[i]}" >&2
    done
    local all_option_num=$(( ${#DEVICES[@]} + 1 ))
    printf "  %2d) %s\n" "$all_option_num" "Build All Devices" >&2

    echo -e "\nYou can select:" >&2
    echo "  - A single device (e.g., 1)" >&2
    echo "  - Multiple devices separated by spaces (e.g., 1 3 5)" >&2
    echo "  - $all_option_num for all devices" >&2
    read -p "Enter selection: " selection

    IFS=' ' read -ra SELECTIONS <<< "$selection"

    local selected_devices=()
    local build_all=false

    for sel in "${SELECTIONS[@]}"; do
        if ! [[ "$sel" =~ ^[0-9]+$ ]]; then
            echo "❌ Invalid selection: $sel. Please enter numbers only."
            exit 1
        fi

        if [ "$sel" -eq "$all_option_num" ]; then
            build_all=true
            break
        fi

        if [ "$sel" -lt 1 ] || [ "$sel" -gt "${#DEVICES[@]}" ]; then
            echo "❌ Invalid selection: $sel. Please enter a number between 1 and $all_option_num."
            exit 1
        fi

        selected_devices+=("${DEVICES[((sel-1))]}")
    done

    if [ "$build_all" = true ]; then
        echo "all"
    else
        if [ ${#selected_devices[@]} -eq 0 ]; then
            echo "❌ No valid devices selected."
            exit 1
        fi
        echo "${selected_devices[@]}"
    fi
}

main() {
    if [[ "$1" == "--clean" ]]; then
        perform_clean
        exit 0
    fi

    for cmd in git zip gh; do
        if ! command -v "$cmd" &> /dev/null; then
            echo "❌ $cmd is not installed. Please install it to continue."
            exit 1
        fi
    done

    if [ ! -d "$AK3_DIR" ]; then
        echo "AnyKernel directory not found. Cloning from repository..."
        git clone "$AK3_REPO" "$AK3_DIR"
    fi

    mkdir -p "$RELEASE_DIR"

    get_config_selection

    # Handle config setup based on selection
    case "$CONFIG_CHOICE" in
        2)
            CONFIG_FRAGMENTS+=("$KERNEL_DIR/arch/arm64/configs/ksu.config")
            detect_kernelsu_version
            echo "📌 KernelSU-Next Version: $KSU_VERSION"
            ;;
        3)
            CONFIG_FRAGMENTS+=("$KERNEL_DIR/arch/arm64/configs/sukisu.config")
            detect_sukisu_version
            echo "📌 Sukisu Version: $SUKISU_VERSION"
            ;;
        4)
            # Will be handled specially below
            ;;
        *)
            # Default build, no fragments
            ;;
    esac

    # Validate config fragments exist (skip for option 4)
    if [[ "$CONFIG_CHOICE" != "4" ]]; then
        for fragment in "${CONFIG_FRAGMENTS[@]}"; do
            if [ ! -f "$fragment" ]; then
                echo "❌ Config fragment not found: $fragment"
                exit 1
            fi
        done
    fi

    local device_selection=$(get_device_selection)
    local selected_devices=()

    if [ "$device_selection" == "all" ]; then
        selected_devices=("${DEVICES[@]}")
        echo -e "\n👍 You selected: Build All Devices"
    else
        read -ra selected_devices <<< "$device_selection"
        echo -e "\n👍 You selected: ${selected_devices[*]}"
    fi

    # Handle option 4: Build both configs separately
    if [[ "$CONFIG_CHOICE" == "4" ]]; then
        print_header "🔧 Building KernelSU-Next + Sukisu (Separate Builds)"

        # First build: KernelSU-Next
        echo -e "\n=========================================="
        echo "PHASE 1: Building KernelSU-Next"
        echo "=========================================="
        CONFIG_FRAGMENTS=("$KERNEL_DIR/arch/arm64/configs/ksu.config")
        KSU_VERSION=""
        SUKISU_VERSION=""
        detect_kernelsu_version
        echo "📌 KernelSU-Next Version: $KSU_VERSION"

        build_selected_devices "${selected_devices[@]}"

        # Clean between builds
        echo -e "\n🧹 Cleaning build outputs before next config..."
        rm -rf "$OUT_BASE"
        echo "✅ Clean complete."

        # Second build: Sukisu
        echo -e "\n=========================================="
        echo "PHASE 2: Building Sukisu"
        echo "=========================================="
        CONFIG_FRAGMENTS=("$KERNEL_DIR/arch/arm64/configs/sukisu.config")
        KSU_VERSION=""
        SUKISU_VERSION=""
        detect_sukisu_version
        echo "📌 Sukisu Version: $SUKISU_VERSION"

        build_selected_devices "${selected_devices[@]}"

        echo -e "\n🎉 Both builds complete!"

        if [ "$device_selection" == "all" ]; then
            create_github_release
        fi
    else
        # Normal single config build
        build_selected_devices "${selected_devices[@]}"

        if [ "$device_selection" == "all" ]; then
            create_github_release
        else
            echo -e "\n🎉 Build complete for selected devices."
        fi
    fi
}

main "$@"
