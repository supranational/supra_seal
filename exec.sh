#!/bin/bash -e

set -x

SECTOR_SIZE="32GiB"
if [ "$1" == "512MiB" ]; then
    SECTOR_SIZE="512MiB"
fi

./build.sh $SECTOR_SIZE

SECTOR_SIZE_FEATURE=""
if [ "$SECTOR_SIZE" == "512MiB" ]; then
    SECTOR_SIZE_FEATURE="--no-default-features --features 512MiB"
fi


cd src/demos/rust
#touch build.rs
env RUSTFLAGS="-C target-cpu=native" \
    RUST_LOG=trace \
    BELLMAN_CUSTOM_GPU="NVIDIA GeForce RTX 3080:8704" \
    cargo build $SECTOR_SIZE_FEATURE
sudo ./target/debug/supra-seal-demo

cd ..
