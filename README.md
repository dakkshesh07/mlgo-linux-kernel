# MLGO for Linux Kernels

## Overview
This project leverages the [MLGO](https://github.com/google/ml-compiler-opt) (Machine Learning Guided Compiler Optimizations) infrastructure to train custom optimization models specifically tailored for compiling Linux kernel sources.

## What is MLGO?
[MLGO](https://github.com/google/ml-compiler-opt) is a framework developed by Google for integrating ML techniques systematically in [LLVM](https://github.com/llvm/llvm-project/). It replaces human-crafted optimization heuristics in LLVM with machine learned models.

### The MLGO framework currently supports two optimizations:
1. **Inlining-for-size ([LLVM RFC](https://lists.llvm.org/pipermail/llvm-dev/2020-April/140763.html))**
2. **Register-allocation-for-performance ([LLVM RFC](https://lists.llvm.org/pipermail/llvm-dev/2021-November/153639.html))**

## Training from Linux Kernel Sources
You can train your own model by using our scripts.

example:
```sh
bash train_model --arch=arm64 --model=regalloc
```

To know about all the supported arguments run the script with --help.

## Pretrained Models
We provide pretrained regalloc models trained off of Linux kernel sources using our scripts. We provide our models in X86_64 and ARM64 flavours, the training compilation is done using the default defconfig for the respective archtitecture.
Models are released as github releases, and are named as:
[task]-linux-[linux kernel version used for training]-[arch]-[release candidate].

When building LLVM, there is a flag `-DLLVM_RAEVICT_MODEL_PATH` which you may
set to the path to your downloaded model.

```sh
# Model is in /tmp/model, i.e. there is a file /tmp/model/saved_model.pb along
# with the rest of the tensorflow saved_model files produced from training.
-DLLVM_RAEVICT_MODEL_PATH=/tmp/model
```

## Documentation
- [MLGO Paper](https://arxiv.org/abs/2101.04808)
- [MLGO Repo README](https://github.com/google/ml-compiler-opt/blob/main/README.md)
