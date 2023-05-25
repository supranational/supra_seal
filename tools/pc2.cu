// g++ -g -Wall -Wextra -Werror -Wno-subobject-linkage -march=native -O3 src/tools/tree_r.cpp -Isrc/poseidon -Ideps/sppark -Ideps/blst/src -L deps/blst -lblst

// Only supports constant arity 8 throughout the tree (2KB, 32G, etc);
//
// arguments
//  last_layer_filename
// optional arguments
//  data_filename - This indicates whether or not we have a CC sector

#include <cstdint>             // uint*
#include <sys/mman.h>          // mapping
#include <sys/stat.h>          // file stats
#include <cassert>             // assertions
#include <cmath>               // log2
#include <fcntl.h>             // file open
#include <unistd.h>            // file close
#include <iostream>            // printing
#include <iomanip>             // printing
#include <chrono>              // time

#include "../pc2/cuda/pc2.cu"

#ifndef __CUDA_ARCH__
#include "../pc1/tree_r.hpp"
#include "../util/debug_helpers.cpp"
#include "../sealing/sector_parameters.cpp"

void usage(char* argv[]) {
  std::cout << "If no staged data file, CC is assumed" << std::endl;
  std::cout << "Usage: " << argv[0] << " [OPTIONS]" << std::endl;
  std::cout << "-h        Print help message" << std::endl;
  std::cout << "-d <path> Staged data file" << std::endl;
  std::cout << "-i <path> Input cache directory" << std::endl;
  std::cout << "-o <path> Output directory" << std::endl;
  exit(0);
}

void gpu_single_pc2(std::string config_filename,
                    std::string cache_dir,
                    std::string data_filename,
                    std::string output_dir) {
  topology_t topology(config_filename.c_str());
  set_core_affinity(topology.pc2_hasher);

  // Get the sector size
  size_t sector_size = SECTOR_SIZE;
  SectorParameters params(sector_size);

  // Construct the layer filenames
  std::vector<std::string> layer_filenames;
  const size_t MAX = 256;
  char fname[MAX];
  const char* layer_filename_template = "%s/sc-02-data-layer-%d.dat";
  for (size_t i = 0; i < params.GetNumLayers(); i++) {
    snprintf(fname, MAX, layer_filename_template, cache_dir.c_str(), i + 1);
    layer_filenames.push_back(fname);
  }
  
  // Total number of streams across all GPUs
  size_t stream_count = 64;

  // Batch size in nodes. Each node includes all parallel sectors
  size_t batch_size = 64 * 64 * 8;
  
  // Nodes to read per partition
  size_t nodes_to_read = params.GetNumNodes() / params.GetNumTreeRCFiles();

  streaming_node_reader_t<sealing_config1_t> node_reader
    (params, layer_filenames, sector_size);
  
  // Allocate storage for 2x the streams to support tree-c and tree-r
  node_reader.alloc_slots(stream_count * 2, params.GetNumLayers() * batch_size, true);

  bool tree_r_only = false;
  const char* data_filenames[1];
  if (!data_filename.empty()) {
    data_filenames[0] = data_filename.c_str();
  } else {
    data_filenames[0] = nullptr;
  }
  pc2_hash<sealing_config1_t>(params, topology, tree_r_only, node_reader,
                              nodes_to_read, batch_size, stream_count,
                              data_filenames, output_dir.c_str());
}

int main(int argc, char* argv[]) {
  int  opt   = 0;
  std::string data_filename       = "";
  std::string cache_dir           = "";
  std::string out_dir             = ".";
  std::string config_filename     = "demos/rust/supra_seal.cfg";
  
  while ((opt = getopt(argc, argv, "c:i:d:o:h")) != -1) {
    switch(opt) {
      case 'c':
        std::cout << "config file               " << optarg << std::endl;
        config_filename = optarg;
        break;
      case 'i':
        std::cout << "input cache_dir           " << optarg << std::endl;
        cache_dir = optarg;
        break;
      case 'd':
        std::cout << "data_filename input       " << optarg << std::endl;
        data_filename = optarg;
        break;
      case 'o':
        std::cout << "out_dir                   " << optarg << std::endl;
        out_dir = optarg;
        break;
      case 'h':
      case ':':
      case '?':
        usage(argv);
        break;
    }
  }

  if (cache_dir.empty()) {
    printf("-c <cache_dir> must be specified\n");
    usage(argv);
  }

  gpu_single_pc2(config_filename, cache_dir, data_filename, out_dir);
  return 0;
}
#endif
