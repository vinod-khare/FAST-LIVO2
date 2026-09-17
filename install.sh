#!/usr/bin/env bash

set -euo pipefail

BOX_NAME="${FAST_LIVO2_BOX_NAME:-fast-livo2-noetic}"
BOX_IMAGE="${FAST_LIVO2_BOX_IMAGE:-docker.io/library/ros:noetic-ros-base}"
WORKSPACE="${FAST_LIVO2_WORKSPACE:-$HOME/.local/share/fast-livo2-noetic/catkin_ws}"
JOBS="${FAST_LIVO2_BUILD_JOBS:-2}"
SOPHUS_REVISION="a621ff"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

log() {
    printf '\n==> %s\n' "$*"
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ -r /etc/os-release ]] || fail "Cannot identify the host operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]] || \
    fail "This installer supports Ubuntu 26.04; detected ${PRETTY_NAME:-unknown}."
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "FAST_LIVO2_BUILD_JOBS must be a positive integer."

missing_host_tools=()
for tool in distrobox podman newuidmap slirp4netns fuse-overlayfs; do
    if ! command -v "$tool" >/dev/null; then
        missing_host_tools+=("$tool")
    fi
done

if ((${#missing_host_tools[@]})); then
    log "Installing host container prerequisites"
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        distrobox podman uidmap slirp4netns fuse-overlayfs
else
    log "Host container prerequisites are already installed"
fi

podman info >/dev/null || fail "Rootless Podman is unavailable. Log out and back in, then rerun this script."

if ! podman container exists "$BOX_NAME"; then
    log "Creating Distrobox $BOX_NAME"
    distrobox create --name "$BOX_NAME" --image "$BOX_IMAGE" --yes
else
    log "Reusing Distrobox $BOX_NAME"
fi

run_in_box() {
    distrobox enter --name "$BOX_NAME" -- bash -lc "$1"
}

log "Installing ROS Noetic build and runtime dependencies"
run_in_box '
    set -e
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential cmake git libboost-thread-dev libeigen3-dev libopencv-dev libpcl-dev ros-noetic-compressed-image-transport ros-noetic-cv-bridge ros-noetic-eigen-conversions ros-noetic-image-transport ros-noetic-message-generation ros-noetic-pcl-ros ros-noetic-rviz ros-noetic-tf
'

log "Building pinned Sophus dependency"
printf -v sophus_revision_q '%q' "$SOPHUS_REVISION"
run_in_box "
    set -e
    sophus_dir=\"\$HOME/.local/share/fast-livo2-noetic/dependencies/Sophus\"
    if [[ ! -f /usr/local/lib/libSophus.so ]]; then
        mkdir -p \"\$(dirname \"\$sophus_dir\")\"
        if [[ ! -d \"\$sophus_dir/.git\" ]]; then
            git clone https://github.com/strasdat/Sophus.git \"\$sophus_dir\"
        fi
        git -C \"\$sophus_dir\" checkout $sophus_revision_q
        sophus_source=\"\$sophus_dir/sophus/so2.cpp\"
        if grep -Fq 'unit_complex_.real() = 1.;' \"\$sophus_source\"; then
            sed -i \
                -e 's/unit_complex_\.real() = 1\.;/unit_complex_.real(1.);/' \
                -e 's/unit_complex_\.imag() = 0\.;/unit_complex_.imag(0.);/' \
                \"\$sophus_source\"
        elif ! grep -Fq 'unit_complex_.real(1.);' \"\$sophus_source\"; then
            echo 'Unexpected Sophus source; refusing to apply compatibility patch.' >&2
            exit 1
        fi
        cmake -S \"\$sophus_dir\" -B \"\$sophus_dir/build\" -DCMAKE_BUILD_TYPE=Release
        cmake --build \"\$sophus_dir/build\" --parallel $JOBS
        sudo cmake --install \"\$sophus_dir/build\"
        sudo ldconfig
    fi
    test -f /usr/local/lib/libSophus.so
"

printf -v repo_q '%q' "$SCRIPT_DIR"
printf -v workspace_q '%q' "$WORKSPACE"

log "Preparing catkin workspace"
run_in_box "
    set -e
    workspace=$workspace_q
    repository=$repo_q
    mkdir -p \"\$workspace/src\"
    if [[ ! -d \"\$workspace/src/rpg_vikit/.git\" ]]; then
        git clone https://github.com/xuankuzcr/rpg_vikit.git \"\$workspace/src/rpg_vikit\"
    fi
    fast_livo_link=\"\$workspace/src/FAST-LIVO2\"
    if [[ -e \"\$fast_livo_link\" && ! -L \"\$fast_livo_link\" ]]; then
        echo \"\$fast_livo_link exists and is not a symbolic link.\" >&2
        exit 1
    fi
    ln -sfn \"\$repository\" \"\$fast_livo_link\"
"

log "Resolving catkin dependencies"
run_in_box "
    set -e
    if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
        sudo rosdep init
    fi
    rosdep update --rosdistro noetic
    source /opt/ros/noetic/setup.bash
    cd $workspace_q
    rosdep install --from-paths src --ignore-src --rosdistro noetic -r -y
"

log "Building FAST-LIVO2"
run_in_box "
    set -e
    source /opt/ros/noetic/setup.bash
    cd $workspace_q
    catkin_make -DCMAKE_BUILD_TYPE=Release -j$JOBS
    source devel/setup.bash
    executable=\"\$PWD/devel/lib/fast_livo/fastlivo_mapping\"
    test -x \"\$executable\"
    rospack find fast_livo >/dev/null
    if ldd \"\$executable\" | grep -q 'not found'; then
        ldd \"\$executable\" | grep 'not found' >&2
        exit 1
    fi
    test -x /opt/ros/noetic/lib/rviz/rviz
    test -f /opt/ros/noetic/lib/libcompressed_image_transport.so
"

cat <<EOF

FAST-LIVO2 installed successfully.

Run:
  distrobox enter $BOX_NAME
  source /opt/ros/noetic/setup.bash
  source $WORKSPACE/devel/setup.bash
  roslaunch fast_livo mapping_avia.launch

For headless use, append: rviz:=false
EOF