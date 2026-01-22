#!/bin/bash
# ROS2 Jazzy + Gazebo Harmonic + Ollama + PX4 + MAVROS + ROSA

set -e

# Configuration
CONTAINER_NAME="ros2_agent_sim"
IMAGE_NAME="ros2-agent-sim:latest"
DOCKERFILE_PATH="docker/Dockerfile.ros2-agent-sim"
WORKSPACE_DIR="$HOME/${CONTAINER_NAME}_shared_volume"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to setup WSL Docker configuration
setup_wsl_docker_config() {
    # Check for WSL environment
    if grep -qi microsoft /proc/version 2>/dev/null; then
        print_info "🪟 WSL environment detected, checking Docker config..."
        
        WSL_DOCKER_DIR="$HOME/.docker-wsl"
        WSL_DOCKER_CONFIG="$WSL_DOCKER_DIR/config.json"
        # Assuming script is run from repo root as enforced by build_image
        SOURCE_CONFIG="./scripts/.docker-wsl/config.json"
        
        if [ ! -f "$WSL_DOCKER_CONFIG" ]; then
             print_warning "WSL Docker config not found at $WSL_DOCKER_CONFIG"
             if [ -f "$SOURCE_CONFIG" ]; then
                 print_info "Copying default config from $SOURCE_CONFIG"
                 mkdir -p "$WSL_DOCKER_DIR"
                 cp "$SOURCE_CONFIG" "$WSL_DOCKER_CONFIG"
                 print_success "Created $WSL_DOCKER_CONFIG"
             else
                 print_error "Source config not found at $SOURCE_CONFIG"
                 # Don't exit, maybe user wants to proceed without it
             fi
        fi
        
        if [ -f "$WSL_DOCKER_CONFIG" ]; then
            export DOCKER_CONFIG="$WSL_DOCKER_DIR"
            print_success "Set DOCKER_CONFIG=$DOCKER_CONFIG"
        fi
    fi
}

# Function to check if Docker is installed and running
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Docker is not running. Please start Docker daemon."
        exit 1
    fi
}

# Function to check if image exists
check_image_exists() {
    if docker images --format "table {{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE_NAME}$"; then
        return 0
    else
        return 1
    fi
}

# Function to build Docker image
build_image() {
    print_info "Building Docker image: ${IMAGE_NAME}"
    print_info "Using Dockerfile: ${DOCKERFILE_PATH}"
    
    if [ ! -f "${DOCKERFILE_PATH}" ]; then
        print_error "Dockerfile not found: ${DOCKERFILE_PATH}"
        print_error "Please ensure you're running this script from the correct directory."
        exit 1
    fi

    echo
    print_info "Starting Docker build process..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    start_time=$(date +%s)
    
    if docker build -f "${DOCKERFILE_PATH}" -t "${IMAGE_NAME}" . 2>&1; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_success "Docker image built successfully!"
        print_success "Build completed in ${duration} seconds"
        print_success "Image: ${IMAGE_NAME}"
        echo
        return 0
    else
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        print_error "Docker build failed after ${duration} seconds"
        exit 1
    fi
}

# Enhanced GPU detection and support setup
setup_gpu_support() {
    print_info "🎮 Setting up comprehensive GPU support..."
    
    DOCKER_OPTS=""
    
    # Detect GPU type and configure accordingly
    if command -v nvidia-smi &> /dev/null; then
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits | head -1)
        print_info "NVIDIA GPU detected: $GPU_NAME"
        
        # Check Docker version for GPU support
        DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "20.10.0")
        DOCKER_MAJOR=$(echo $DOCKER_VERSION | cut -d. -f1)
        DOCKER_MINOR=$(echo $DOCKER_VERSION | cut -d. -f2)
        
        if [ "$DOCKER_MAJOR" -gt 19 ] || ([ "$DOCKER_MAJOR" -eq 19 ] && [ "$DOCKER_MINOR" -ge 3 ]); then
            DOCKER_OPTS="$DOCKER_OPTS --gpus all"
            print_success "Using native Docker GPU support (--gpus all)"
        else
            print_warning "Docker version < 19.03 detected"
            if command -v nvidia-docker &> /dev/null; then
                DOCKER_OPTS="$DOCKER_OPTS --runtime=nvidia"
                print_success "Using nvidia-docker runtime"
            else
                print_error "Please update Docker to version 19.03+ or install nvidia-docker2"
            fi
        fi
        
        # Additional NVIDIA environment variables
        DOCKER_OPTS="$DOCKER_OPTS -e NVIDIA_VISIBLE_DEVICES=all"
        DOCKER_OPTS="$DOCKER_OPTS -e NVIDIA_DRIVER_CAPABILITIES=all"
        
    elif lspci 2>/dev/null | grep -i vga | grep -i amd &> /dev/null; then
        print_info "AMD GPU detected"
        DOCKER_OPTS="$DOCKER_OPTS --device=/dev/dri"
        
    elif lspci 2>/dev/null | grep -i vga | grep -i intel &> /dev/null; then
        print_info "Intel GPU detected"
        DOCKER_OPTS="$DOCKER_OPTS --device=/dev/dri"
    else
        print_warning "No dedicated GPU detected, configuring for software rendering"
    fi
    
    export DOCKER_OPTS
}

# Enhanced X11 authentication and graphics setup
setup_x11_auth() {
    print_info "🖥️  Setting up display/auth..."

    # Detect WSLg
    if [ -d "/mnt/wslg" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        print_success "WSLg detected (Wayland: $WAYLAND_DISPLAY, DISPLAY: ${DISPLAY:-unset})"

        # WSLg provides these sockets and runtime dir
        export DISPLAY="${DISPLAY:-:0}"
        export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"

        # Disable xauth for WSLg (not needed)
        export XAUTH=""
        unset XAUTHORITY

        print_success "Using WSLg sockets: /mnt/wslg/.X11-unix and runtime-dir"
        return 0
    fi

    # ─────────────────────────────────────────────────────────────
    # Non-WSLg fallback (your original logic, but fix rm issue)
    # ─────────────────────────────────────────────────────────────
    print_warning "WSLg not detected; falling back to X11/xauth setup"

    XAUTH_DIR="/tmp/.docker-xauth"
    mkdir -p "$XAUTH_DIR"
    XAUTH="$XAUTH_DIR/xauth-$(whoami)"

    rm -rf "$XAUTH"     # important: handles directory or file
    touch "$XAUTH"
    chmod 600 "$XAUTH"

    export XAUTH
    export XAUTHORITY="$XAUTH"
}

# Function to setup workspace directory
setup_workspace() {
    print_info "📁 Setting up workspace directory: $WORKSPACE_DIR"
    
    # Create workspace directory if it doesn't exist
    if [ ! -d "$WORKSPACE_DIR" ]; then
        mkdir -p "$WORKSPACE_DIR"
        print_success "Created workspace directory: $WORKSPACE_DIR"
    else
        print_info "Workspace directory already exists: $WORKSPACE_DIR"
    fi
    
    # Set proper permissions
    HOST_UID=$(id -u)
    HOST_GID=$(id -g)
    
    if [ -d "$WORKSPACE_DIR" ]; then
        # ownership to current user
        chown -R "$HOST_UID:$HOST_GID" "$WORKSPACE_DIR" 2>/dev/null || {
            print_warning "Could not change ownership of workspace directory"
            print_info "This may cause permission issues inside the container"
        }
        
        # Make sure it's writable
        chmod 755 "$WORKSPACE_DIR" 2>/dev/null || {
            print_warning "Could not set permissions on workspace directory"
        }
        
        print_success "Workspace directory setup completed"
    else
        print_error "Failed to create workspace directory"
        exit 1
    fi
}

# Enhanced container startup with comprehensive graphics support (WSLg-aware + WSL GPU bridge)
start_persistent_container() {
    print_info "🚀 Starting container with enhanced graphics support: $CONTAINER_NAME"

    # Host user info
    HOST_UID="$(id -u)"
    HOST_GID="$(id -g)"
    HOST_USER="$(whoami)"

    # Detect WSLg
    IS_WSLG=0
    if [ -d "/mnt/wslg" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        IS_WSLG=1
        print_success "WSLg detected (WAYLAND_DISPLAY=${WAYLAND_DISPLAY}, DISPLAY=${DISPLAY})"
    fi

    # ─────────────────────────────────────────────────────────────
    # Build graphics flags
    # ─────────────────────────────────────────────────────────────
    GRAPHICS_ENV=""
    GRAPHICS_VOLUMES=""

    # Always pass DISPLAY (WSLg exposes Xwayland on :0)
    GRAPHICS_ENV="$GRAPHICS_ENV --env=DISPLAY=${DISPLAY:-:0}"

    if [ "$IS_WSLG" -eq 1 ]; then
        # WSLg path: Wayland + Xwayland sockets + runtime dir
        WSLG_RUNTIME="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"

        GRAPHICS_ENV="$GRAPHICS_ENV --env=WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=XDG_RUNTIME_DIR=${WSLG_RUNTIME}"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=XDG_SESSION_TYPE=wayland"

        # Prefer Wayland for Qt in WSLg
        GRAPHICS_ENV="$GRAPHICS_ENV --env=QT_QPA_PLATFORM=wayland"

        # Mount WSLg sockets and runtime
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/mnt/wslg:/mnt/wslg:rw"
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/mnt/wslg/.X11-unix:/tmp/.X11-unix:rw"
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=${WSLG_RUNTIME}:${WSLG_RUNTIME}:rw"

        # WSL GPU bridge (helps avoid llvmpipe for GUI in many setups)
        if [ -c "/dev/dxg" ]; then
            GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --device=/dev/dxg"
            print_info "WSL GPU device (/dev/dxg) mounted"
        fi
        if [ -d "/usr/lib/wsl" ]; then
            GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/usr/lib/wsl:/usr/lib/wsl:ro"
            GRAPHICS_ENV="$GRAPHICS_ENV --env=LD_LIBRARY_PATH=/usr/lib/wsl/lib:\${LD_LIBRARY_PATH}"
            print_info "WSL graphics libraries mounted (/usr/lib/wsl)"
        fi

        # Pass WSLg variables
        GRAPHICS_ENV="$GRAPHICS_ENV --env=WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0}"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=XDG_RUNTIME_DIR=${WSLG_RUNTIME}"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=XDG_SESSION_TYPE=wayland"

        # Force D3D12 path for Mesa in WSLg (fixes llvmpipe issues)
        GRAPHICS_ENV="$GRAPHICS_ENV --env=LD_LIBRARY_PATH=/usr/lib/wsl/lib:\${LD_LIBRARY_PATH}"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=MESA_LOADER_DRIVER_OVERRIDE=d3d12"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=GALLIUM_DRIVER=d3d12"

        # IMPORTANT: do NOT mount /dev/dri in WSLg mode (often forces Mesa/llvmpipe)
    else
        # Legacy Linux X11 path (xauth)
        GRAPHICS_ENV="$GRAPHICS_ENV --env=XAUTHORITY=${XAUTH}"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=XDG_RUNTIME_DIR=/tmp/runtime-user"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=XDG_SESSION_TYPE=x11"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=WAYLAND_DISPLAY="

        # X11 Qt backend
        GRAPHICS_ENV="$GRAPHICS_ENV --env=QT_QPA_PLATFORM=xcb"
        GRAPHICS_ENV="$GRAPHICS_ENV --env=QT_X11_NO_MITSHM=1"

        # X11 mounts
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/tmp/.X11-unix:/tmp/.X11-unix:rw"
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=${XAUTH}:${XAUTH}:rw"

        # Runtime dir for apps expecting XDG_RUNTIME_DIR
        mkdir -p /tmp/runtime-user
        chmod 700 /tmp/runtime-user
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/tmp/runtime-user:/tmp/runtime-user:rw"

        # DRI for native Linux hosts
        if [ -d "/dev/dri" ]; then
            GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/dev/dri:/dev/dri:rw"
            print_info "DRI graphics devices mounted"
        fi
    fi

    # Qt common
    GRAPHICS_ENV="$GRAPHICS_ENV --env=QT_AUTO_SCREEN_SCALE_FACTOR=0"
    GRAPHICS_ENV="$GRAPHICS_ENV --env=QT_SCALE_FACTOR=1"
    GRAPHICS_ENV="$GRAPHICS_ENV --env=QT_QPA_PLATFORM_PLUGIN_PATH=/usr/lib/x86_64-linux-gnu/qt6/plugins/platforms"

    # OpenGL common (do not force software; let stack pick best)
    GRAPHICS_ENV="$GRAPHICS_ENV --env=LIBGL_ALWAYS_INDIRECT=0"
    GRAPHICS_ENV="$GRAPHICS_ENV --env=LIBGL_ALWAYS_SOFTWARE=0"

    # Terminal / colors
    GRAPHICS_ENV="$GRAPHICS_ENV --env=TERM=xterm-256color"
    GRAPHICS_ENV="$GRAPHICS_ENV --env=COLORTERM=truecolor"
    GRAPHICS_ENV="$GRAPHICS_ENV --env=FORCE_COLOR=1"
    GRAPHICS_ENV="$GRAPHICS_ENV --env=CLICOLOR_FORCE=1"

    # NVIDIA device nodes (optional; --gpus all usually enough, but harmless)
    if [ -c "/dev/nvidia0" ]; then
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/dev/nvidia0:/dev/nvidia0:rw"
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/dev/nvidiactl:/dev/nvidiactl:rw"
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/dev/nvidia-modeset:/dev/nvidia-modeset:rw"
        print_info "NVIDIA devices mounted"
    fi

    # Optional shared libs (native Linux hosts; typically unnecessary on WSLg)
    if [ "$IS_WSLG" -eq 0 ] && [ -d "/usr/share/glvnd" ]; then
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/usr/share/glvnd:/usr/share/glvnd:ro"
    fi
    if [ "$IS_WSLG" -eq 0 ] && [ -d "/usr/lib/x86_64-linux-gnu/dri" ]; then
        GRAPHICS_VOLUMES="$GRAPHICS_VOLUMES --volume=/usr/lib/x86_64-linux-gnu/dri:/usr/lib/x86_64-linux-gnu/dri:ro"
    fi

    # ─────────────────────────────────────────────────────────────
    # Start container
    # ─────────────────────────────────────────────────────────────
    docker run -d \
        --name="${CONTAINER_NAME}" \
        --hostname=ros2-dev \
        --network host \
        --privileged \
        ${GRAPHICS_ENV} \
        --env="CONTAINER_NAME=${CONTAINER_NAME}" \
        -e LOCAL_USER_ID="${HOST_UID}" \
        -e LOCAL_GROUP_ID="${HOST_GID}" \
        -e HOST_USER="${HOST_USER}" \
        -e FASTRTPS_DEFAULT_PROFILES_FILE=/usr/local/share/middleware_profiles/rtps_udp_profile.xml \
        ${GRAPHICS_VOLUMES} \
        --volume="/etc/localtime:/etc/localtime:ro" \
        --mount="type=bind,source=${WORKSPACE_DIR},target=/home/user/shared_volume" \
        --volume="/dev:/dev:rw" \
        --workdir /home/user/shared_volume \
        --security-opt seccomp=unconfined \
        --security-opt apparmor=unconfined \
        --cap-add=SYS_PTRACE \
        --cap-add=SYS_ADMIN \
        --ipc=host \
        --shm-size=1g \
        --tmpfs /tmp:exec \
        ${DOCKER_OPTS} \
        "${IMAGE_NAME}" \
        tail -f /dev/null

    sleep 3

    if [ "$(docker ps -q -f name="${CONTAINER_NAME}")" ]; then
        print_success "Container started successfully in persistent mode"

        print_info "Testing graphics environment inside container..."

        # X11 test (works in WSLg too via Xwayland)
        if docker exec "${CONTAINER_NAME}" bash -lc "timeout 5 xset q" >/dev/null 2>&1; then
            print_success "✅ X11 connection working inside container!"
        else
            print_warning "⚠️ X11 connection test failed"
        fi

        # OpenGL test (may still show non-NVIDIA on WSLg; Vulkan is the better indicator)
        print_info "Testing OpenGL support..."
        if docker exec "${CONTAINER_NAME}" bash -lc "timeout 10 glxinfo -B" 2>/dev/null | grep -q "OpenGL"; then
            RENDERER="$(docker exec "${CONTAINER_NAME}" bash -lc "glxinfo -B 2>/dev/null | grep 'OpenGL renderer' | cut -d: -f2 | xargs")"
            print_success "✅ OpenGL working: ${RENDERER}"
        else
            print_warning "⚠️ OpenGL test inconclusive"
        fi

        # Vulkan test (more meaningful on WSLg)
        if docker exec "${CONTAINER_NAME}" bash -lc "command -v vulkaninfo >/dev/null && timeout 10 vulkaninfo --summary >/dev/null 2>&1"; then
            print_success "✅ Vulkan available (good sign for WSLg acceleration)"
        else
            print_warning "⚠️ Vulkan not available or not working"
        fi

        # Qt6 check
        print_info "Testing Qt6 environment..."
        if docker exec "${CONTAINER_NAME}" bash -lc "find /usr -path '*qt6*platforms*' -type d 2>/dev/null | head -1" | grep -q platforms; then
            print_success "✅ Qt6 platform plugins detected"
        else
            print_warning "⚠️ Qt6 platform plugins not found in expected location"
        fi

        print_success "🎉 Container fully initialized with graphics support"
        return 0
    else
        print_error "Failed to start container"
        docker logs "${CONTAINER_NAME}"
        return 1
    fi
}



# Function to connect to running container
connect_to_container() {
    print_info "🔗 Connecting to container: ${CONTAINER_NAME}"

    # Capture host display vars (WSLg)
    HOST_DISPLAY="${DISPLAY:-:0}"
    HOST_WAYLAND="${WAYLAND_DISPLAY:-wayland-0}"
    HOST_XDG_RUNTIME="${XDG_RUNTIME_DIR:-/mnt/wslg/runtime-dir}"

    BASE_CMD="export DEV_DIR=/home/user/shared_volume && \
        export PX4_DIR=\$DEV_DIR/PX4-Autopilot && \
        export ROS2_WS=\$DEV_DIR/ros2_ws && \
        export OSQP_SRC=\$DEV_DIR && \
        cd /home/user/shared_volume && \
        source /home/user/.bashrc"

    # IMPORTANT: do NOT use -l (login shell), it may reset WAYLAND_DISPLAY/XDG_RUNTIME_DIR
    docker exec --user user --workdir /home/user/shared_volume -it ${CONTAINER_NAME} \
        env \
          DISPLAY="${HOST_DISPLAY}" \
          WAYLAND_DISPLAY="${HOST_WAYLAND}" \
          XDG_RUNTIME_DIR="${HOST_XDG_RUNTIME}" \
          XDG_SESSION_TYPE="wayland" \
          TERM=xterm-256color COLORTERM=truecolor FORCE_COLOR=1 \
        bash -c "${BASE_CMD} && exec bash"
}

# Function to run or connect to container
run_container() {
    print_info "🐳 Managing container: $CONTAINER_NAME"
    
    # Check if container exists
    if [ "$(docker ps -aq -f name=${CONTAINER_NAME})" ]; then
        # Container exists, check if it's running
        if [ "$(docker ps -q -f name=${CONTAINER_NAME})" ]; then
            # Container is running, connect to it
            print_info "Container is already running"
            connect_to_container
        else
            # Container exists but stopped, start it
            print_info "Starting stopped container..."
            docker start ${CONTAINER_NAME}
            sleep 3
            connect_to_container
        fi
    else
        # Container doesn't exist, create and start it
        print_info "Creating new persistent container..."
        if start_persistent_container; then
            connect_to_container
        else
            print_error "Failed to create container"
            exit 1
        fi
    fi
}

# Cleanup function
cleanup() {
    print_info "🧹 Cleaning up X server permissions..."
    if command -v xhost &> /dev/null; then
        xhost -local:root 2>/dev/null || true
        xhost -local:docker 2>/dev/null || true
        xhost -local: 2>/dev/null || true
    fi
}

# Show system information
show_system_info() {
    print_info "💻 System Information:"
    echo "  - Docker version: $(docker --version 2>/dev/null | cut -d' ' -f3 | cut -d',' -f1 || echo 'Unknown')"
    echo "  - Host OS: $(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown Linux')"
    echo "  - Host User: $(whoami) (UID: $(id -u), GID: $(id -g))"
    
    # GPU information
    if command -v nvidia-smi &> /dev/null; then
        GPU_INFO=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader,nounits | head -1)
        echo "  - NVIDIA GPU: $GPU_INFO"
    elif lspci 2>/dev/null | grep -i vga | grep -i amd &> /dev/null; then
        AMD_GPU=$(lspci 2>/dev/null | grep -i vga | grep -i amd | cut -d: -f3 | xargs)
        echo "  - AMD GPU: $AMD_GPU"
    elif lspci 2>/dev/null | grep -i vga | grep -i intel &> /dev/null; then
        INTEL_GPU=$(lspci 2>/dev/null | grep -i vga | grep -i intel | cut -d: -f3 | xargs)
        echo "  - Intel GPU: $INTEL_GPU"
    else
        echo "  - GPU: No dedicated GPU detected (using software rendering)"
    fi
    
    echo "  - Display: ${DISPLAY:-'Not set'}"
    
    # X11 status
    if command -v xset &> /dev/null && timeout 3 xset q >/dev/null 2>&1; then
        echo "  - X11 Status: ✅ Working"
    else
        echo "  - X11 Status: ⚠️ Not working or not available"
    fi
    
    echo
}

# Show container status
show_container_status() {
    print_info "📊 Container Status:"
    
    if [ "$(docker ps -aq -f name=${CONTAINER_NAME})" ]; then
        if [ "$(docker ps -q -f name=${CONTAINER_NAME})" ]; then
            print_success "Container '${CONTAINER_NAME}' is RUNNING"
            echo "  - To connect: docker exec -it ${CONTAINER_NAME} bash"
            echo "  - To see logs: docker logs ${CONTAINER_NAME}"
            
            # Show container graphics status
            print_info "Graphics Status in Container:"
            if docker exec ${CONTAINER_NAME} timeout 3 xset q 2>/dev/null; then
                echo "  - X11: ✅ Working"
            else
                echo "  - X11: ⚠️ Not working"
            fi
            
            if docker exec ${CONTAINER_NAME} which glxinfo >/dev/null 2>&1; then
                RENDERER=$(docker exec ${CONTAINER_NAME} bash -c "glxinfo -B 2>/dev/null | grep 'OpenGL renderer' | cut -d: -f2" 2>/dev/null | xargs || echo "Unknown")
                echo "  - OpenGL Renderer: $RENDERER"
            fi
        else
            print_warning "Container '${CONTAINER_NAME}' is STOPPED"
            echo "  - To start: docker start ${CONTAINER_NAME}"
        fi
    else
        print_info "Container '${CONTAINER_NAME}' does not exist"
    fi
    echo
}

# Show help
show_help() {
    echo "Usage: $0 [COMMAND]"
    echo
    echo "🚀 ROS2 Jazzy + Gazebo Harmonic + Ollama + PX4 + MAVROS + ROSA"
    echo
    echo "Commands:"
    echo "  run       Start/connect to persistent container (default)"
    echo "  build     Build the Docker image"
    echo "  rebuild   Force rebuild the Docker image"
    echo "  clean     Remove container and image"
    echo "  shell     Open additional shell in running container"
    echo "  logs      Show container logs"
    echo "  stop      Stop the container (keeps it for later)"
    echo "  restart   Restart the container"
    echo "  status    Show container and graphics status"
    echo "  help      Show this help"
    echo
    echo "INCLUDED:"
    echo "  ✅ Ubuntu 24.04 package compatibility"
    echo "  ✅ Qt6 platform plugin"
    echo "  ✅ Mesa/OpenGL package corrections"
    echo "  ✅ Enhanced X11 authentication"
    echo "  ✅ Gazebo Harmonic compatibility"
    echo
    echo "The container runs persistently in the background."
    echo "You can exit and reconnect without losing your work."
    echo
    echo "Examples:"
    echo "  $0                # Start/connect to container"
    echo "  $0 status         # Check container and graphics status"
    echo "  $0 shell          # Open another terminal in container"
}

# Main execution
main() {
    echo
    print_info "🚀 ROS2 Agent Sim Docker Environment"
    print_info "🎯 ROS2 Jazzy + Gazebo Harmonic + Ollama + PX4 + MAVROS + ROSA"
    print_info "Container: $CONTAINER_NAME"
    print_info "Workspace: $WORKSPACE_DIR"
    echo
    
    show_system_info
    setup_wsl_docker_config
    check_docker
    
    if check_image_exists; then
        print_success "✅ Docker image exists: ${IMAGE_NAME}"
    else
        print_warning "⚠️  Docker image not found: ${IMAGE_NAME}"
        build_image
    fi
    
    setup_gpu_support
    setup_x11_auth
    setup_workspace
    
    echo
    print_info "🐳 Starting persistent container environment with graphics support..."
    run_container
    
    trap cleanup EXIT
}

# Handle commands
case "${1:-run}" in
    "run")
        main
        ;;
    "build")
        check_docker
        build_image
        ;;
    "rebuild")
        check_docker
        print_info "Force rebuilding image with Ubuntu 24.04 fixes..."
        docker rmi "${IMAGE_NAME}" 2>/dev/null || true
        build_image
        ;;
    "clean")
        print_info "Cleaning up container and image..."
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
        docker rmi "$IMAGE_NAME" 2>/dev/null || true
        rm -rf "$WORKSPACE_DIR" 2>/dev/null || true
        print_success "Cleanup complete"
        ;;
    "shell")
        if [ "$(docker ps -q -f name="$CONTAINER_NAME")" ]; then
            connect_to_container
        else
            print_error "Container $CONTAINER_NAME is not running"
            print_info "Use '$0 run' to start it first"
            exit 1
        fi
        ;;
    "logs")
        docker logs "$CONTAINER_NAME"
        ;;
    "stop")
        docker stop "$CONTAINER_NAME"
        print_success "Container stopped (but not removed)"
        print_info "Use '$0 run' to restart it"
        ;;
    "restart")
        docker restart "$CONTAINER_NAME"
        print_success "Container restarted"
        ;;
    "status")
        show_container_status
        ;;
    "help")
        show_help
        ;;
    *)
        print_error "Unknown command: $1"
        show_help
        exit 1
        ;;
esac