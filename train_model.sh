#!/usr/bin/env bash

# Copyright (C) 2023 Dakkshesh <dakkshesh5@gmail.com>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set -e

helpmenu() {
    echo -e "
 --arch=<arch>        : The training Linux kernel will be compiled for the given architecture.
                            Example: $0 --arch=X86
                            Example: $0 --arch=ARM64

 --linux-tag=<tag>    : Linux kernel version tag to be used for the compilation.
                        By default latest rolling release is used if no value is given.
                            Example: $0 --linux-tag=v6.6.8
                            Example: $0 --linux-tag=v5.10.205

 --working-dir=<dir>  : Working dir to be used for the training process.
                        Current dir will be used if no value is given.

 --edge-tools         : Use latest available version instead of recommended one for required pip packages"
}

KARCH=""
LINUX_TAG="v$(wget -q --output-document - "https://www.kernel.org" | grep -A 1 "latest_link" | tail -n +2 | sed 's|.*">||' | sed 's|</a>||')"
WORKING_DIR="$(pwd)"
PIP_PACKAGES=("absl-py==1.0.0"
    "gin-config==0.5.0"
    "psutil==5.9.0"
    "tf-agents==0.16.0"
    "tensorflow==2.12.0"
    "dm-reverb==0.11.0")

for arg in "$@"; do
    case "${arg}" in
        "--arch"*)
            KARCH="${arg#*=}"
            if [[ $KARCH == "arm64" ]]; then
                GLOBAL_CMDS='["-march=armv8.2-a", "--target=aarch64-linux-gnu", "-fshort-wchar", "-funsigned-char", "-fintegrated-as", "-fno-common", "-fno-PIE", "-O2", "-fno-strict-overflow", "-fno-stack-check", "-fstrict-flex-arrays=3", "-nostdinc", "fno-strict-aliasing", "-c"]'
            elif [[ $KARCH == "x86" ]] || [[ $KARCH == "x86_64" ]]; then
                GLOBAL_CMDS='["-fshort-wchar", "-funsigned-char", "-fintegrated-as", "-fno-common", "-fno-PIE", "-O2", "-fno-strict-overflow", "-fno-stack-check", "-fstrict-flex-arrays=3", "-nostdinc", "fno-strict-aliasing", "-c"]'
            else
                echo "$KARCH is invalid or not supported!"
            fi
            ;;
        "--linux-tag*")
            LINUX_TAG="${arg#*=}"
            if [[ ${LINUX_TAG} == "" ]]; then
                echo "--linux-tag requires a value."
                exit 1
            fi
            ;;
        "--working-dir"*)
            WORKING_DIR="${arg#*=}"
            if [[ ${WORKING_DIR} == "" ]]; then
                echo "--working-dir requires a value."
                exit 1
            fi
            ;;
        "--edge-tools")
            PIP_PACKAGES=("absl-py"
                "gin-config"
                "psutil"
                "tf-agents"
                "tensorflow"
                "dm-reverb")
            ;;
        "-H" | "--help")
            helpmenu
            exit 0
            ;;
        *)
            echo "Invalid argument passed: '${arg}' Run '$0 --help' to view available options."
            exit 1
            ;;
    esac
done

echo ""
echo "Arch: $KARCH"
echo "Linux: $LINUX_TAG"
echo "Working dir: $WORKING_DIR"
echo ""

mkdir -p "${WORKING_DIR}"

python -m venv "${WORKING_DIR}/venv"
VENV_BIN="${WORKING_DIR}/venv/bin"
VENV_LIB_PATH="${WORKING_DIR}/venv/lib/$("${VENV_BIN}"/python --version | tr 'A-Z' 'a-z' | rev | cut -d. -f2- | rev | tr -d ' ')/site-packages"

STOCK_PATH="$PATH"
export PATH="${VENV_BIN}:${PATH}"

"${VENV_BIN}"/pip install "${PIP_PACKAGES[@]}"

cd "${WORKING_DIR}"
if [[ $(wget -q --output-document - "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/?h=${LINUX_TAG}" | grep "Invalid branch") != "" ]]; then
    if [[ $(wget -q --output-document - "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/?h=${LINUX_TAG}" | grep "Invalid branch") != "" ]]; then
        echo "Invalid tag: ${LINUX_TAG}"
    else
        wget "https://git.kernel.org/torvalds/t/linux-${LINUX_TAG}.tar.gz"
        tar -xf "linux-${LINUX_TAG}.tar.gz"
    fi
    LINUX_DIR="${WORKING_DIR}/linux-${LINUX_TAG}"
else
    LINUX_TAG_V="$(echo "${LINUX_TAG}" | cut -d. -f1)"
    LINUX_TAG_URL="${LINUX_TAG#*v}"
    wget "https://cdn.kernel.org/pub/linux/kernel/${LINUX_TAG_V}.x/linux-${LINUX_TAG_URL}.tar.xz"
    tar -xf "linux-${LINUX_TAG_URL}.tar.xz"
    LINUX_DIR="${WORKING_DIR}/linux-${LINUX_TAG_URL}"
fi

cd "${WORKING_DIR}"
MLGO_REPO_DIR="${WORKING_DIR}/ml-compiler-opt"
LLVM_REPO_DIR="${WORKING_DIR}/llvm-project"
git clone "https://github.com/google/ml-compiler-opt.git" --depth=1 "${MLGO_REPO_DIR}"
git clone "https://github.com/llvm/llvm-project.git" --depth=1 "${LLVM_REPO_DIR}"

cd "${LINUX_DIR}"
if grep -q -n "flto=thin" Makefile; then
    sed -i "$(grep -n "flto=thin" Makefile | cut -d: -f1)a KBUILD_LDFLAGS  += --thinlto-emit-index-files --save-temps=import" Makefile
else
    echo "Error: Could not patch the Linux kernel source. Is thinLTO supported?"
    exit 1
fi

cd "${LINUX_DIR}"
make ARCH="${KARCH}" LLVM=1 LLVM_IAS=1 O=out distclean defconfig -j"$(nproc --all)"
./scripts/config --file out/.config -e LTO_CLANG -d LTO_NONE -e LTO_CLANG_THIN -d LTO_CLANG_FULL -e THINLTO
bear -- make ARCH="${KARCH}" LLVM=1 LLVM_IAS=1 O=out -j"$(nproc --all)"
cp compile_commands.json out/

cd "${WORKING_DIR}"
mkdir tflite
cd tflite
"${WORKING_DIR}"/ml-compiler-opt/buildbot/build_tflite.sh

mkdir "${WORKING_DIR}"/llvm-build
cd "${WORKING_DIR}"/llvm-build
cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_PARALLEL_COMPILE_JOBS="$(nproc --all)" \
    -DLLVM_PARALLEL_LINK_JOBS="$(nproc --all)" \
    -C "${WORKING_DIR}"/tflite/tflite.cmake \
    "${WORKING_DIR}"/llvm-project/llvm
ninja -j"$(nproc --all)" || exit 1

cd "${WORKING_DIR}"/ml-compiler-opt
PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/python3 compiler_opt/tools/extract_ir.py \
    --cmd_filter="^-O2|-O3" \
    --llvm_objcopy_path="${WORKING_DIR}"/llvm-build/bin/llvm-objcopy \
    --output_dir="${WORKING_DIR}"/corpus \
    --thinlto_build=local \
    --obj_base_dir="${LINUX_DIR}"/out

jq '.global_command_override = '"${GLOBAL_CMDS}" "${WORKING_DIR}/corpus/corpus_description.json" >"${WORKING_DIR}/corpus/corpus_description.tmp" && mv "${WORKING_DIR}/corpus/corpus_description.tmp" "${WORKING_DIR}/corpus/corpus_description.json"

PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/python3 compiler_opt/tools/generate_default_trace.py \
    --data_path="${WORKING_DIR}"/corpus \
    --output_path="${WORKING_DIR}"/default_trace \
    --gin_files=compiler_opt/rl/regalloc/gin_configs/common.gin \
    --gin_bindings=clang_path="'${WORKING_DIR}/llvm-build/bin/clang'" \
    --sampling_rate=0.2

rm -rf ./compiler_opt/rl/regalloc/vocab
PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/python3 compiler_opt/tools/generate_vocab.py \
    --input="${WORKING_DIR}"/default_trace \
    --output_dir=./compiler_opt/rl/regalloc/vocab \
    --gin_files=compiler_opt/rl/regalloc/gin_configs/common.gin

PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/python3 compiler_opt/rl/train_bc.py \
    --root_dir="${WORKING_DIR}"/warmstart \
    --data_path="${WORKING_DIR}"/default_trace \
    --gin_files=compiler_opt/rl/regalloc/gin_configs/behavioral_cloning_nn_agent.gin

PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/python3 compiler_opt/rl/train_locally.py \
    --root_dir="${WORKING_DIR}"/output_model \
    --data_path="${WORKING_DIR}"/corpus \
    --gin_bindings=clang_path="'${WORKING_DIR}/llvm-build/bin/clang'" \
    --gin_files=compiler_opt/rl/regalloc/gin_configs/ppo_nn_agent.gin \
    --gin_bindings=train_eval.warmstart_policy_dir=\""${WORKING_DIR}"/warmstart/saved_policy\"

export PATH="${STOCK_PATH}"
