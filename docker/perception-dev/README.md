# perception-dev

ROS 2 Humble perception / visual-odometry dev container (CUDA 12.6, TensorRT, PyTorch, ONNX Runtime, OpenCV, Eigen, PCL, RViz2, Gazebo Fortress via `ros-gz`).
One `Dockerfile.build` builds for Jetson Orin Nano (arm64) and x86 (native Ubuntu or WSL2).

## Files

| File | Purpose |
|---|---|
| `Dockerfile.build` | Dev/build image for all targets |
| `docker-compose.yml` | Shared `build` service |
| `docker-compose.jetson.yml` / `.x86.yml` / `.wsl.yml` | Per-target GPU and display settings |
| `jetson.env` / `x86.env` | Base image, CUDA architectures, image tag per target |
| `Dockerfile.deploy` | Optional, Jetson-only runtime image; not needed for experiments |
| `ws/` | Your colcon workspace (mounted at `/workspace`) |
| `datasets/` | Mounted at `/datasets` (override with `DATASETS_DIR`) |

## Host prerequisites

The host must provide the GPU driver and container runtime. The container provides everything else (CUDA toolkit, cuDNN, TensorRT, ROS).

### Jetson Orin Nano

| Item | Requirement |
|---|---|
| JetPack | 6.x (6.1 = L4T 36.4.0, 6.2 = L4T 36.4.3). Check with `cat /etc/nv_tegra_release` (expect `R36`). |
| Base OS | Ubuntu 22.04 (aarch64), from the JetPack flash |
| Kernel | NVIDIA Tegra 5.15 (`uname -r` shows `5.15.x-tegra`) |
| GPU driver | Integrated Tegra driver shipped with L4T. Nothing to install separately. |
| Host SDK | `sudo apt install nvidia-jetpack` (CUDA 12.6, cuDNN 9, TensorRT 10.3, VPI). The container has its own copy, but the NVIDIA container runtime reads the host's driver stack. |
| Container runtime | Docker Engine 24+ with Compose v2 and `nvidia-container-toolkit` (included with JetPack 6; verify below) |
| Storage | NVMe SSD recommended, 60 GB+ free for the image and cache |
| Memory | 8 GB; add swap if a colcon build gets killed (use `colcon build --parallel-workers 2`) |

Set Docker's default runtime and, optionally, move its data to the SSD in `/etc/docker/daemon.json`:
```json
{ "default-runtime": "nvidia", "runtimes": { "nvidia": { "path": "nvidia-container-runtime", "runtimeArgs": [] } }, "data-root": "/mnt/ssd/docker" }
```
Then `sudo systemctl restart docker`.

Verify:
```bash
docker run --rm --runtime nvidia nvcr.io/nvidia/l4t-jetpack:r36.4.0 ls /usr/local/cuda
```

### x86, native Ubuntu

| Item | Requirement |
|---|---|
| Base OS | Ubuntu 22.04 or 24.04 (the container itself is Ubuntu 22.04) |
| Kernel | Any supported by your NVIDIA driver (5.15+ recommended) |
| GPU | NVIDIA, compute capability 7.5+ (Turing or newer) |
| GPU driver | NVIDIA proprietary driver 560 or newer recommended for CUDA 12.6 (525+ works through CUDA minor-version compatibility) |
| Host CUDA toolkit | Not needed; the image has CUDA 12.6 |
| Container runtime | Docker Engine 24+, Compose v2, `nvidia-container-toolkit` (`sudo nvidia-ctk runtime configure --runtime=docker`) |
| Storage | 50 GB+ free |

Verify:
```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu22.04 nvidia-smi
```

### x86, Windows with WSL2

| Item | Requirement |
|---|---|
| Windows | Windows 11 (or Windows 10 21H2+) with WSL2 and an Ubuntu 22.04 distro |
| Kernel | Microsoft WSL2 kernel (5.15+), updated via `wsl --update` |
| GPU driver | NVIDIA Windows driver with WSL support (560+ recommended). Do **not** install a Linux NVIDIA driver inside WSL. |
| Container runtime | Either Docker Desktop (WSL2 backend, GPU support on) or Docker Engine inside WSL with `nvidia-container-toolkit` |
| GUI | WSLg (included in current WSL) for RViz2 and Gazebo windows |
| Storage | 50 GB+ free in the WSL virtual disk |

With Docker Desktop, `network_mode: host` needs host networking enabled (Settings > Resources > Network). Docker Engine inside WSL avoids this. Multi-machine ROS 2 discovery from WSL also needs mirrored networking (`networkingMode=mirrored` in `.wslconfig`).

Verify in the WSL shell:
```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.6.3-base-ubuntu22.04 nvidia-smi
```

## Build and run

Run from this directory. Edit `CUDA_ARCHS` in `x86.env` to match your GPU (75 Turing, 86 Ampere, 89 Ada; separate several with `;`).

```bash
mkdir -p ws/src datasets
xhost +local:docker          # allow GUI windows (native Linux, Jetson with a display)

# Jetson Orin Nano
docker compose --env-file jetson.env -f docker-compose.yml -f docker-compose.jetson.yml run --rm --build build

# x86, native Ubuntu
docker compose --env-file x86.env -f docker-compose.yml -f docker-compose.x86.yml run --rm --build build

# x86, WSL2
docker compose --env-file x86.env -f docker-compose.yml -f docker-compose.x86.yml -f docker-compose.wsl.yml run --rm --build build
```

Build the workspace inside the container:
```bash
cd /workspace && colcon build --merge-install --cmake-args -DCMAKE_BUILD_TYPE=Release
```

The environment variable `CUDAARCHS` is set from `CUDA_ARCHS` so CMake picks the right GPU architecture.

Check the stack inside the container:
```bash
python3 -c "import torch, onnxruntime as o; print(torch.cuda.is_available(), o.get_available_providers())"
trtexec --help | head -n 1
ros2 pkg list | head -n 3
```

## Building the Jetson image on x86 (optional)

Needs QEMU emulation because every Dockerfile `RUN` step executes arm64 programs. With nothing compiled in the image, the steps are mostly apt and pip installs.

```bash
docker run --privileged --rm tonistiigi/binfmt --install arm64   # not needed on Docker Desktop
docker buildx build --platform linux/arm64 -f Dockerfile.build \
  --build-arg BASE_IMAGE=nvcr.io/nvidia/l4t-jetpack:r36.4.0 --build-arg CUDA_ARCHS=87 \
  -t perception-build:humble-jp6 --output type=docker,dest=perception-build-jp6.tar .
gzip perception-build-jp6.tar && scp perception-build-jp6.tar.gz jetson:~/
# on the Jetson
gunzip -c perception-build-jp6.tar.gz | docker load
```

## Notes

- Keep `build/`, `install/` and `log/` separate per target (or delete them when switching). Objects from one architecture must not be reused on the other.
- Match the JetPack base tag to the L4T version on the device. If it differs from `r36.4.0`, change `BASE_IMAGE` in `jetson.env`.
- On x86, TensorRT comes from apt, pinned by the `TRT_VERSION` build argument. If the build fails to find that version, run `apt-cache madison libnvinfer10` in the base image and set a listed version.
- The Jetson PyTorch wheel index URL (`JETSON_PIP_INDEX`) has moved in the past; update it if the install step fails.
- TensorRT engines are device-specific. Build them on the machine that runs them.
- Image size is roughly 18-25 GB; peak build disk use is 35-50 GB.
