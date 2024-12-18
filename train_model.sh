#!/usr/bin/env bash

# Copyright (C) 2024 Dakkshesh <dakkshesh5@gmail.com>
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
 --arch=<arch>        : Compiles the Linux kernel for the specified architecture for training purpose.
                            Example: $0 --arch=x86
                            Example: $0 --arch=arm64

 --model=<tag>        : Specifies the flavour of the mlgo optimization model to train (regalloc or inlining).
                            Example: $0 --model=regalloc
                            Example: $0 --model=inlining

 --linux-tag=<tag>    : Sets the Linux kernel version tag for compilation.
                        The latest rolling release is used by default if no value is given.
                            Example: $0 --linux-tag=v6.6.8
                            Example: $0 --linux-tag=v5.10.205

 --working-dir=<dir>  : Sets the working directory for the training process.
                        The current directory is used if no value is given.

 --edge-tools         : Uses the latest available version instead of the recommended one for required pip packages"
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
LLVM_BIN_DIR=$(readlink -f "$(which clang)" | rev | cut -d'/' -f2- | rev)

for arg in "$@"; do
    case "${arg}" in
        "--arch"*)
            KARCH="${arg#*=}"
            COMMON_CMDS=( "-fshort-wchar" "-funsigned-char" "-fintegrated-as" "-fno-common" "-fno-PIE" "-fno-strict-overflow" "-fno-stack-check" "-fstrict-flex-arrays=3" "-nostdinc" "-fno-strict-aliasing" )
            if [[ $KARCH == "arm64" ]]; then
                COMMON_CMDS+=( "-march=armv8.2-a" "--target=aarch64-linux-gnu" )
            elif [[ $KARCH == "x86" ]] || [[ $KARCH == "x86_64" ]]; then
                COMMON_CMDS+=( "-march=x86-64" )
            elif [[ $KARCH == "" ]]; then
                echo "--arch requires a value and cannot be empty."
                exit 1
            else
                echo "$KARCH is not a supported architecture."
            fi
            ;;
        "--linux-tag"*)
            LINUX_TAG="${arg#*=}"
            if [[ ${LINUX_TAG} == "" ]]; then
                echo "--linux-tag requires a value and cannot be empty."
                exit 1
            fi
            ;;
        "--model"*)
            MLGO_MODEL="${arg#*=}"
            if [[ ${MLGO_MODEL} == "inlining" ]]; then
                CMD_FILTER="^-O2|-Os|-Oz$"
                COMMON_CMDS+=( "-Os" )
            elif [[ ${MLGO_MODEL} == "regalloc" ]]; then
                CMD_FILTER="^-O2|-O3"
                COMMON_CMDS+=( "-O2" )
            elif [[ ${MLGO_MODEL} == "" ]]; then
                echo "--model requires a value and cannot be empty."
                exit 1
            else
                echo "${MLGO_MODEL} is not a supported model type."
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
        "--clang-bin"*)
            CLANG_BIN="${arg#*=}"
            if [[ ${CLANG_BIN} == "" ]]; then
                echo "--clang-bin requires a value and cannot be empty."
                exit 1
            fi
            LLVM_BIN_DIR=$(readlink -f "$(which ${CLANG_BIN})" | rev | cut -d'/' -f2- | rev)
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

if [[ -z "${KARCH}" ]]; then
 echo "Please specify the architecture to compile the Linux kernel for using the --arch flag."
 exit 1
fi

if [[ -z "${MLGO_MODEL}" ]]; then
 echo "Please specify the model type to train using the --model flag."
fi

COMMON_CMDS+=( "-c" )

echo ""
echo "Architecture: ${KARCH}"
echo "Linux Version: ${LINUX_TAG}"
echo "Model Type: ${MLGO_MODEL}"
echo "Working Directory: ${WORKING_DIR}"
echo ""

mkdir -p "${WORKING_DIR}"

python -m venv "${WORKING_DIR}/venv"
VENV_BIN="${WORKING_DIR}/venv/bin"
VENV_LIB_PATH="${WORKING_DIR}/venv/lib/$("${VENV_BIN}"/python --version | tr 'A-Z' 'a-z' | rev | cut -d. -f2- | rev | tr -d ' ')/site-packages"

STOCK_PATH="$PATH"
export PATH="${VENV_BIN}:${PATH}"

"${VENV_BIN}"/pip install "${PIP_PACKAGES[@]}"

#TODO: Remove unsafe flags when package gets updated
"${VENV_BIN}"/pip install --pre --ignore-requires-python mlgo-utils

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

KMAKEFLAGS=("LLVM=1"
    "LLVM_IAS=1"
    "CC=${LLVM_BIN_DIR}/clang"
    "LD=${LLVM_BIN_DIR}/ld.lld"
    "AR=${LLVM_BIN_DIR}/llvm-ar"
    "NM=${LLVM_BIN_DIR}/llvm-nm"
    "STRIP=${LLVM_BIN_DIR}/llvm-strip"
    "OBJCOPY=${LLVM_BIN_DIR}/llvm-objcopy"
    "OBJDUMP=${LLVM_BIN_DIR}/llvm-objdump"
    "READELF=${LLVM_BIN_DIR}/llvm-readelf"
    "HOSTCC=${LLVM_BIN_DIR}/clang"
    "HOSTCXX=${LLVM_BIN_DIR}/clang++"
    "HOSTAR=${LLVM_BIN_DIR}/llvm-ar"
    "HOSTLD=${LLVM_BIN_DIR}/ld.lld")

cd "${LINUX_DIR}"
make ARCH="${KARCH}" "${KMAKEFLAGS[@]}" O=out distclean defconfig -j"$(nproc --all)"
./scripts/config --file out/.config -e LTO_CLANG -d LTO_NONE -e LTO_CLANG_THIN -d LTO_CLANG_FULL -e THINLTO
if [[ ${MLGO_MODEL} == "inlining" ]]; then
    ./scripts/config --file out/.config -e CC_OPTIMIZE_FOR_SIZE -d CC_OPTIMIZE_FOR_PERFORMANCE
fi
bear -- make ARCH="${KARCH}" "${KMAKEFLAGS[@]}" O=out -j"$(nproc --all)"
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
    -DCMAKE_C_COMPILER="${LLVM_BIN_DIR}"/clang \
    -DCMAKE_CXX_COMPILER="${LLVM_BIN_DIR}"/clang++ \
    -DCMAKE_AR="${LLVM_BIN_DIR}"/llvm-ar \
    -DCMAKE_NM="${LLVM_BIN_DIR}"/llvm-nm \
    -DCMAKE_STRIP="${LLVM_BIN_DIR}"/llvm-strip \
    -DLLVM_USE_LINKER="${LLVM_BIN_DIR}"/ld.lld \
    -DCMAKE_LINKER="${LLVM_BIN_DIR}"/ld.lld \
    -DCMAKE_OBJCOPY="${LLVM_BIN_DIR}"/llvm-objcopy \
    -DCMAKE_OBJDUMP="${LLVM_BIN_DIR}"/llvm-objdump \
    -DCMAKE_RANLIB="${LLVM_BIN_DIR}"/llvm-ranlib \
    -DCMAKE_READELF="${LLVM_BIN_DIR}"/llvm-readelf \
    -DCMAKE_ADDR2LINE="${LLVM_BIN_DIR}"/llvm-addr2line \
    -DLLVM_PARALLEL_COMPILE_JOBS="$(nproc --all)" \
    -DLLVM_PARALLEL_LINK_JOBS="$(nproc --all)" \
    -C "${WORKING_DIR}"/tflite/tflite.cmake \
    "${WORKING_DIR}"/llvm-project/llvm
ninja -j"$(nproc --all)" || exit 1

cd "${WORKING_DIR}"/ml-compiler-opt
rm -rf "${OUTPUT_DIR}/corpus"
PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/extract_ir \
    --cmd_filter="${CMD_FILTER}" \
    --llvm_objcopy_path="${WORKING_DIR}"/llvm-build/bin/llvm-objcopy \
    --output_dir="${WORKING_DIR}"/corpus \
    --thinlto_build=local \
    --obj_base_dir="${LINUX_DIR}"/out

GLOBAL_CMDS=$(printf '%s\n' "${COMMON_CMDS[@]}" | jq -R . | jq -s .)
jq '.global_command_override = '"${GLOBAL_CMDS}" "${WORKING_DIR}/corpus/corpus_description.json" >"${WORKING_DIR}/corpus/corpus_description.tmp" && mv "${WORKING_DIR}/corpus/corpus_description.tmp" "${WORKING_DIR}/corpus/corpus_description.json"

TRACE_GEN_ARGS=(
    "--data_path=${WORKING_DIR}/corpus"
    "--output_path=${WORKING_DIR}/default_trace"
    "--gin_files=compiler_opt/rl/${MLGO_MODEL}/gin_configs/common.gin"
    "--gin_bindings=clang_path='${WORKING_DIR}/llvm-build/bin/clang'"
    "--sampling_rate=1"
)

if [[ ${MLGO_MODEL} == "inlining" ]]; then
    TRACE_GEN_ARGS+=("--gin_bindings=config_registry.get_configuration.implementation=@configs.InliningConfig"
                        "--gin_bindings=llvm_size_path='${WORKING_DIR}/llvm-build/bin/llvm-size'")
fi

rm -rf "${WORKING_DIR}/default_trace"
PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/python3 compiler_opt/tools/generate_default_trace.py \
    "${TRACE_GEN_ARGS[*]}"

rm -rf "${MLGO_REPO_DIR}/compiler_opt/rl/${MLGO_MODEL}/vocab"
PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/python3 compiler_opt/tools/generate_vocab.py \
    --input="${WORKING_DIR}"/default_trace \
    --output_dir="${MLGO_REPO_DIR}"/compiler_opt/rl/"${MLGO_MODEL}"/vocab \
    --gin_files="${MLGO_REPO_DIR}"/compiler_opt/rl/"${MLGO_MODEL}"/gin_configs/common.gin

rm -rf "${WORKING_DIR}/warmstart"
PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/python3 compiler_opt/rl/train_bc.py \
    --root_dir="${WORKING_DIR}"/warmstart \
    --data_path="${WORKING_DIR}"/default_trace \
    --gin_files="${MLGO_REPO_DIR}"/compiler_opt/rl/"${MLGO_MODEL}"/gin_configs/behavioral_cloning_nn_agent.gin

rm -rf "${WORKING_DIR}/output_model_${MLGO_MODEL}"
PYTHONPATH="${VENV_LIB_PATH}:$PYTHONPATH:${WORKING_DIR}/ml-compiler-opt" \
    "${VENV_BIN}"/python3 compiler_opt/rl/train_locally.py \
    --root_dir="${WORKING_DIR}/output_model_${MLGO_MODEL}" \
    --data_path="${WORKING_DIR}"/corpus \
    --gin_bindings=clang_path="'${WORKING_DIR}/llvm-build/bin/clang'" \
    --gin_files="${MLGO_REPO_DIR}"/compiler_opt/rl/"${MLGO_MODEL}"/gin_configs/ppo_nn_agent.gin \
    --gin_bindings=train_eval.warmstart_policy_dir=\""${WORKING_DIR}"/warmstart/saved_policy\"

echo "The model is saved in: ${WORKING_DIR}/output_model_${MLGO_MODEL}"

export PATH="${STOCK_PATH}"
