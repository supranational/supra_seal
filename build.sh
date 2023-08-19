#!/bin/bash

# Copyright Supranational LLC

set -e
set -x

SECTOR_SIZE="-DSECTOR_SIZE_32GiB"
if [ "$1" == "512MiB" ]; then
    SECTOR_SIZE="-DSECTOR_SIZE_512MiB"
fi

CC=${CC:-cc}
CXX=${CXX:-c++}
NVCC=${NVCC:-nvcc}

CUDA=$(dirname $(dirname $(which $NVCC)))
SPDK="deps/spdk-v22.09"
CUDA_ARCH="-arch=sm_80 -gencode arch=compute_70,code=sm_70 -t0"
CXXSTD=`$CXX -dM -E -x c++ /dev/null | \
        awk '{ if($2=="__cplusplus" && $3<"2017") print "-std=c++17"; }'`

INCLUDE="-I$SPDK/include -I$SPDK/isa-l/.. -I$SPDK/dpdk/build/include"
CFLAGS="$SECTOR_SIZE $INCLUDE -g -O2"
CXXFLAGS="$CFLAGS -march=native $CXXSTD \
          -fPIC -fno-omit-frame-pointer -fno-strict-aliasing \
          -fstack-protector -fno-common \
          -D_GNU_SOURCE -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 \
          -DSPDK_GIT_COMMIT=4be6d3043 -pthread \
          -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
          -Wformat -Wformat-security"

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

rm -fr bin
mkdir -p bin

mkdir -p deps
if [ ! -d $SPDK ]; then
    git clone --branch v22.09 https://github.com/spdk/spdk --recursive $SPDK
    (cd $SPDK
     sudo scripts/pkgdep.sh
     ./configure --with-virtio --with-vhost
     make -j 10)
fi
if [ ! -d "deps/sppark" ]; then
    git clone https://github.com/supranational/sppark.git deps/sppark
fi
if [ ! -d "deps/blst" ]; then
    git clone https://github.com/supranational/blst.git deps/blst
    (cd deps/blst
     ./build.sh -march=native)
fi
if [ ! -d "c2/bellperson" ]; then
    git clone https://github.com/filecoin-project/bellperson.git -b v0.25.0 c2/bellperson
    (cd c2/bellperson
     git apply ../bellperson-0.25.0.patch)
fi

$CC -c sha/sha_ext_mbx2.S -o obj/sha_ext_mbx2.o

# Generate .h files for the Poseidon constants
xxd -i poseidon/constants/constants_2  > obj/constants_2.h
xxd -i poseidon/constants/constants_4  > obj/constants_4.h
xxd -i poseidon/constants/constants_8  > obj/constants_8.h
xxd -i poseidon/constants/constants_11 > obj/constants_11.h
xxd -i poseidon/constants/constants_16 > obj/constants_16.h
xxd -i poseidon/constants/constants_24 > obj/constants_24.h
xxd -i poseidon/constants/constants_36 > obj/constants_36.h

# PC1
$CXX $CXXFLAGS -Ideps/sppark/util -o obj/pc1.o -c pc1/pc1.cpp &

# PC2
$CXX $CXXFLAGS -o obj/streaming_node_reader_nvme.o -c nvme/streaming_node_reader_nvme.cpp &
$CXX $CXXFLAGS -o obj/ring_t.o -c nvme/ring_t.cpp &
$NVCC $CFLAGS $CUDA_ARCH -std=c++17 -DNO_SPDK -Xcompiler -march=native \
      -Xcompiler -Wall,-Wextra,-Wno-subobject-linkage \
      -Ideps/sppark -Ideps/sppark/util -Ideps/blst/src -dc pc2/cuda/pc2.cu -o obj/pc2.o &
$NVCC $CFLAGS $CUDA_ARCH -std=c++17 -DNO_SPDK -Xcompiler -march=native \
      -Xcompiler -Wall,-Wextra,-Wno-subobject-linkage \
      -Ideps/sppark -Ideps/sppark/util -Ideps/blst/src -dlink pc2/cuda/pc2.cu -o obj/pc2_link.o &

$CXX -g -O2 -c sealing/sector_parameters.cpp -o obj/sector_parameters.o

$CXX $CXXFLAGS $INCLUDE -Ideps/sppark -Ideps/sppark/util -Ideps/blst/src \
    -c sealing/supra_seal.cpp -o obj/supra_seal.o -Wno-subobject-linkage &

wait

ar rvs obj/libsupraseal.a \
   obj/pc1.o \
   obj/pc2.o \
   obj/pc2_link.o \
   obj/ring_t.o \
   obj/streaming_node_reader_nvme.o \
   obj/supra_seal.o \
   obj/sector_parameters.o \
   obj/sha_ext_mbx2.o

$CXX $CXXFLAGS -Ideps/sppark -Ideps/sppark/util -Ideps/blst/src \
    -o bin/seal demos/main.cpp \
    -Lobj -lsupraseal \
    $LDFLAGS -Ldeps/blst -lblst -L$CUDA/lib64 -lcudart_static -lgmp -lconfig++ &

# tree-r CPU only
$CXX $CXXSTD -pthread -g -O3 -march=native \
    -Wall -Wextra -Werror -Wno-subobject-linkage \
    tools/tree_r.cpp \
    -o bin/tree_r_cpu -Iposeidon -Ideps/sppark -Ideps/blst/src -L deps/blst -lblst &

# tree-r CPU + GPU
$NVCC $SECTOR_SIZE -DNO_SPDK -DSTREAMING_NODE_READER_FILES \
     $CUDA_ARCH -std=c++17 -g -O3 -Xcompiler -march=native \
     -Xcompiler -Wall,-Wextra,-Werror \
     -Xcompiler -Wno-subobject-linkage,-Wno-unused-parameter \
     -x cu tools/tree_r.cpp -o bin/tree_r \
     -Iposeidon -Ideps/sppark -Ideps/sppark/util -Ideps/blst/src -L deps/blst -lblst -lconfig++ &

# Standalone GPU pc2
$NVCC $SECTOR_SIZE -DNO_SPDK -DSTREAMING_NODE_READER_FILES \
     $CUDA_ARCH -std=c++17 -g -O3 -Xcompiler -march=native \
     -Xcompiler -Wall,-Wextra,-Werror \
     -Xcompiler -Wno-subobject-linkage,-Wno-unused-parameter \
     -x cu tools/tree_r.cpp -o bin/tree_r \
     -Iposeidon -Ideps/sppark -Ideps/sppark/util -Ideps/blst/src -L deps/blst -lblst -lconfig++ &

# Standalone GPU pc2
$NVCC $SECTOR_SIZE -DNO_SPDK -DSTREAMING_NODE_READER_FILES \
     $CUDA_ARCH -std=c++17 -g -O3 -Xcompiler -march=native \
     -Xcompiler -Wall,-Wextra,-Werror \
     -Xcompiler -Wno-subobject-linkage,-Wno-unused-parameter \
     -x cu tools/pc2.cu -o bin/pc2 \
     -Iposeidon -Ideps/sppark -Ideps/sppark/util -Ideps/blst/src -L deps/blst -lblst -lconfig++ &

wait

