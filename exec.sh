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


cd demos/rust
#touch build.rs
env RUSTFLAGS="-C target-cpu=native" \
    cargo +nightly build --release $SECTOR_SIZE_FEATURE
sudo ./target/release/supra-seal-demo

cd ../..
