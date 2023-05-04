#!/bin/bash

# Copyright Supranational LLC

set -e
set -x

SECTOR_SIZE="-DSECTOR_SIZE_32GiB"
if [ "$1" == "512MiB" ]; then
    SECTOR_SIZE="-DSECTOR_SIZE_512MiB"
fi

CUDA="/usr/local/cuda"
NVCC="$CUDA/bin/nvcc"
SPDK="deps/spdk-v22.09"

INCLUDE="-I$SPDK/include -I$SPDK/isa-l/.. -I$SPDK/dpdk/build/include"
CFLAGS="$SECTOR_SIZE -g $INCLUDE"
CPPFLAGS="$CFLAGS \
          -fno-omit-frame-pointer -g -O2 -Wall -Wextra -Wno-unused-parameter \
          -Wno-missing-field-initializers -fno-strict-aliasing \
          -march=native -Wformat -Wformat-security \
          -D_GNU_SOURCE -fPIC -fstack-protector \
          -fno-common -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 \
          -DSPDK_GIT_COMMIT=4be6d3043 -pthread"

LDFLAGS="-fno-omit-frame-pointer -Wl,-z,relro,-z,now -Wl,-z,noexecstack -fuse-ld=bfd\
         -L$SPDK/build/lib \
         -Wl,--whole-archive -Wl,--no-as-needed \
         -lspdk_bdev_malloc \
         -lspdk_bdev_null \
         -lspdk_bdev_nvme \
         -lspdk_bdev_passthru \
         -lspdk_bdev_lvol \
         -lspdk_bdev_raid \
         -lspdk_bdev_error \
         -lspdk_bdev_gpt \
         -lspdk_bdev_split \
         -lspdk_bdev_delay \
         -lspdk_bdev_zone_block \
         -lspdk_blobfs_bdev \
         -lspdk_blobfs \
         -lspdk_blob_bdev \
         -lspdk_lvol \
         -lspdk_blob \
         -lspdk_nvme \
         -lspdk_bdev_ftl \
         -lspdk_ftl \
         -lspdk_bdev_aio \
         -lspdk_bdev_virtio \
         -lspdk_virtio \
         -lspdk_vfio_user \
         -lspdk_accel_ioat \
         -lspdk_ioat \
         -lspdk_scheduler_dynamic \
         -lspdk_env_dpdk \
         -lspdk_scheduler_dpdk_governor \
         -lspdk_scheduler_gscheduler \
         -lspdk_sock_posix \
         -lspdk_event \
         -lspdk_event_bdev \
         -lspdk_bdev \
         -lspdk_notify \
         -lspdk_dma \
         -lspdk_event_accel \
         -lspdk_accel \
         -lspdk_event_vmd \
         -lspdk_vmd \
         -lspdk_event_sock \
         -lspdk_init \
         -lspdk_thread \
         -lspdk_trace \
         -lspdk_sock \
         -lspdk_rpc \
         -lspdk_jsonrpc \
         -lspdk_json \
         -lspdk_util \
         -lspdk_log \
         -Wl,--no-whole-archive $SPDK/build/lib/libspdk_env_dpdk.a \
         -Wl,--whole-archive $SPDK/dpdk/build/lib/librte_bus_pci.a \
         $SPDK/dpdk/build/lib/librte_cryptodev.a \
         $SPDK/dpdk/build/lib/librte_dmadev.a \
         $SPDK/dpdk/build/lib/librte_eal.a \
         $SPDK/dpdk/build/lib/librte_ethdev.a \
         $SPDK/dpdk/build/lib/librte_hash.a \
         $SPDK/dpdk/build/lib/librte_kvargs.a \
         $SPDK/dpdk/build/lib/librte_mbuf.a \
         $SPDK/dpdk/build/lib/librte_mempool.a \
         $SPDK/dpdk/build/lib/librte_mempool_ring.a \
         $SPDK/dpdk/build/lib/librte_net.a \
         $SPDK/dpdk/build/lib/librte_pci.a \
         $SPDK/dpdk/build/lib/librte_power.a \
         $SPDK/dpdk/build/lib/librte_rcu.a \
         $SPDK/dpdk/build/lib/librte_ring.a \
         $SPDK/dpdk/build/lib/librte_telemetry.a \
         $SPDK/dpdk/build/lib/librte_vhost.a \
         -Wl,--no-whole-archive \
         -lnuma -ldl \
         -L$SPDK/isa-l/.libs -lisal \
         -pthread -lrt -luuid -lssl -lcrypto -lm -laio"

# Check for the default result directory
if [ ! -d "/var/tmp/supra_seal" ]; then
    mkdir -p /var/tmp/supra_seal
fi

rm -fr obj
mkdir -p obj

mkdir -p deps
if [ ! -d "deps/spdk-v22.09" ]; then
    cd deps
    git clone --branch v22.09 https://github.com/spdk/spdk --recursive spdk-v22.09
    cd spdk-v22.09/
    sudo scripts/pkgdep.sh
    ./configure --with-virtio --with-vhost
    make -j 10
    cd ../..
fi
if [ ! -d "deps/sppark" ]; then
    cd deps
    git clone https://github.com/supranational/sppark.git
    cd sppark
    git checkout aeca55d
    cd ../..
fi
if [ ! -d "deps/blst" ]; then
    cd deps
    git clone https://github.com/supranational/blst.git
    cd blst
    git checkout d3f9bd3
    ./build.sh
    cd ../..
fi

gcc -c src/sha/sha_ext_mbx2.S -o obj/sha_ext_mbx2.o

# Generate .h files for the Poseidon constants
xxd -i src/poseidon/constants/constants_2  > obj/constants_2.h
xxd -i src/poseidon/constants/constants_4  > obj/constants_4.h
xxd -i src/poseidon/constants/constants_8  > obj/constants_8.h
xxd -i src/poseidon/constants/constants_11 > obj/constants_11.h
xxd -i src/poseidon/constants/constants_16 > obj/constants_16.h
xxd -i src/poseidon/constants/constants_24 > obj/constants_24.h
xxd -i src/poseidon/constants/constants_36 > obj/constants_36.h

# PC1
c++ $CPPFLAGS -o obj/pc1.o -c src/pc1/pc1.cpp &

# PC2
c++ $CPPFLAGS -o obj/column_reader.o -c src/pc2/column_reader.cpp &
$NVCC $CFLAGS -std=c++17 -DNO_SPDK -D__ADX__ -Xcompiler -Wno-subobject-linkage -Xcompiler -O2 \
      -Ideps/sppark -Ideps/blst/src -arch=sm_75 -dc src/pc2/cuda/pc2.cu -o obj/pc2.o &
$NVCC $CFLAGS -std=c++17 -DNO_SPDK -D__ADX__ -Xcompiler -Wno-subobject-linkage -Xcompiler -O2 \
      -Ideps/sppark -Ideps/blst/src -arch=sm_75 -dlink src/pc2/cuda/pc2.cu -o obj/pc2_link.o &

c++ $CPPFLAGS -c src/c1/c1.cpp -o obj/c1.o -Wno-subobject-linkage \
    -Ideps/sppark -Ideps/blst/src &

c++ -c src/sealing/sector_parameters.cpp -o obj/sector_parameters.o

c++ $CPPFLAGS $INCLUDE -c src/sealing/supra_seal.cpp -o obj/supra_seal.o -Wno-subobject-linkage &

wait

ar rvs obj/libsupraseal.a \
   obj/pc1.o \
   obj/pc2.o \
   obj/pc2_link.o \
   obj/c1.o \
   obj/supra_seal.o \
   obj/column_reader.o \
   obj/sector_parameters.o \
   obj/sha_ext_mbx2.o

c++ $CPPFLAGS -Ideps/sppark -Ideps/blst/src \
    -g -o seal src/demos/main.cpp \
    -Lobj -lsupraseal \
    $LDFLAGS -Ldeps/blst -lblst -L$CUDA/lib64 -lcudart -lgmp -lconfig++ &


wait

