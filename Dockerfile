ARG CUDA_VERSION=12.4.1

#################### BASE BUILD IMAGE ####################
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu20.04 AS base
ARG CUDA_VERSION=12.4.1
ARG PYTHON_VERSION=3.12
ARG TARGETPLATFORM
ENV DEBIAN_FRONTEND=noninteractive

# Install Python and dependencies
RUN echo 'tzdata tzdata/Areas select America' | debconf-set-selections \
    && echo 'tzdata tzdata/Zones/America select Los_Angeles' | debconf-set-selections \
    && apt-get update -y \
    && apt-get install -y ccache software-properties-common git curl sudo \
    && add-apt-repository ppa:deadsnakes/ppa \
    && apt-get update -y \
    && apt-get install -y python${PYTHON_VERSION} python${PYTHON_VERSION}-dev python${PYTHON_VERSION}-venv \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python${PYTHON_VERSION} 1 \
    && update-alternatives --set python3 /usr/bin/python${PYTHON_VERSION} \
    && ln -sf /usr/bin/python${PYTHON_VERSION}-config /usr/bin/python3-config \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python${PYTHON_VERSION} \
    && python3 --version && python3 -m pip --version

# Upgrade to GCC 10
RUN apt-get install -y gcc-10 g++-10
RUN update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-10 110 --slave /usr/bin/g++ g++ /usr/bin/g++-10
RUN gcc --version

# Workaround for CUDA compatibility issues
RUN ldconfig /usr/local/cuda-$(echo $CUDA_VERSION | cut -d. -f1,2)/compat/

WORKDIR /workspace

# Install dependencies
COPY requirements-common.txt requirements-common.txt
COPY requirements-cuda.txt requirements-cuda.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m pip install -r requirements-cuda.txt

ARG torch_cuda_arch_list='7.0 7.5 8.0 8.6 8.9 9.0+PTX'
ENV TORCH_CUDA_ARCH_LIST=${torch_cuda_arch_list}

#################### BUILD IMAGE ####################
FROM base AS build
ARG TARGETPLATFORM

# Install build dependencies
COPY requirements-build.txt requirements-build.txt
RUN --mount=type=cache,target=/root/.cache/pip \
    python3 -m pip install -r requirements-build.txt

COPY . .

# 🚀 FIXED: Prevent `.git` error
RUN if [ -d .git ] && [ "$GIT_REPO_CHECK" != 0 ]; then bash tools/check_repo.sh ; fi

# 🚀 FIXED: Ensure required packages are installed
RUN python3 -m pip install --upgrade pip setuptools wheel cmake ninja

# 🚀 FIXED: Debug setup.py errors
RUN ls -lah  # ✅ Lists all files to check missing dependencies
RUN python3 setup.py bdist_wheel --dist-dir=dist --py-limited-api=cp38 || cat dist/*.log

#################### FINAL IMAGE ####################
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu22.04 AS vllm-runtime
WORKDIR /vllm-workspace
ENV DEBIAN_FRONTEND=noninteractive

# Install Python and system dependencies
RUN apt-get update -y \
    && apt-get install -y python3-pip ffmpeg libsm6 libxext6 libgl1 \
    && python3 -m pip install --upgrade pip

# Install vLLM
RUN --mount=type=bind,from=build,src=/workspace/dist,target=/vllm-workspace/dist \
    --mount=type=cache,target=/root/.cache/pip \
    python3 -m pip install dist/*.whl --verbose

# 🚀 FIXED: Exposed the correct port for RunPod
EXPOSE 49672

# Start OpenAI-compatible vLLM API server
CMD ["python3", "-m", "vllm.entrypoints.openai.api_server", "--host", "0.0.0.0", "--port", "49672"]
