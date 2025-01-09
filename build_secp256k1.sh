#!/bin/bash

BUILD_DIR="apps/arweave/lib/secp256k1/build"
CMAKE_OPTIONS="-DSECP256K1_DISABLE_SHARED=ON \
               -DSECP256K1_ENABLE_MODULE_RECOVERY=ON \
               -DBUILD_SHARED_LIBS=OFF \
               -DSECP256K1_BUILD_BENCHMARK=OFF \
               -DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF \
               -DSECP256K1_BUILD_TESTS=OFF \
               -DSECP256K1_ENABLE_MODULE_MUSIG=OFF \
               -DSECP256K1_ENABLE_MODULE_EXTRAKEYS=OFF \
               -DSECP256K1_ENABLE_MODULE_ELLSWIFT=OFF \
               -DSECP256K1_ENABLE_MODULE_SCHNORRSIG=OFF \
               -DSECP256K1_APPEND_CFLAGS=-fPIC"
mkdir -p $BUILD_DIR
cd $BUILD_DIR
cmake $CMAKE_OPTIONS ..
cmake --build .
