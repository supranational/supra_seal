// Copyright Supranational LLC

#ifndef __STREAMING_LAYER_READER_FILES_HPP__
#define __STREAMING_LAYER_READER_FILES_HPP__

#include <vector>
#include <string>
#include "../util/mmap_t.hpp"

// Encapsulate the SPDK portion of reading layers from files
// C is not used here but is retained to be consistent with
// multi-sector c1
template<class C>
class streaming_node_reader_t {
  std::vector<mmap_t<node_t>> layer_files;
  SectorParameters& params;
public:
  streaming_node_reader_t(SectorParameters& _params,
                          std::vector<std::string> layer_filenames, size_t sector_size)
    : params(_params)
  {
    layer_files.resize(layer_filenames.size());
    for (size_t i = 0; i < layer_filenames.size(); i++) {
      layer_files[i].mmap_read(layer_filenames[i], sector_size);
    }
  }
  
  ~streaming_node_reader_t() {}

  bool data_is_big_endian() {
    return true;
  }
  
  // Allocate resource to perform N reads, each of size slot_node_count. These
  // will be indexed by slot_id
  // packed - indicates whether allocation should assume packed or unpacked node reads
  void alloc_slots(size_t N, size_t slot_node_count, bool _packed)
  {}

  uint8_t* get_full_buffer(size_t &bytes) {
    return nullptr;
  }

  void free_slots()
  {}
  
  ////////////////////////////////////////
  // Used for PC2
  ////////////////////////////////////////

  uint8_t* load_layers(size_t slot, uint32_t layer, uint64_t node,
                       size_t node_count, size_t num_layers,
                       std::atomic<uint64_t>* valid, size_t* valid_count) {
    // Read the final layer for building tree-r
    assert (layer == params.GetNumLayers() - 1);
    assert (C::PARALLEL_SECTORS == 1);
    assert (layer_files.size() == 1);
    
    *valid = 1;
    *valid_count = 1;

    return (uint8_t*)&layer_files[0][node];
  }

  ////////////////////////////////////////
  // Used for C1
  ////////////////////////////////////////
  
  // Load a vector of node IDs into the local buffer
  // The nodes are a vector of layer, node_id pairs
  // Since the nodes may be non-consecutive each node will use
  // an entire page in the buffer.
  int load_nodes(size_t slot, std::vector<std::pair<size_t, size_t>>& nodes) {
    return 0;
  }

  // Retrieve a sector and node from the local buffer
  //   nodes       - the vector of nodes originally read into the local buffer
  //   idx         - the index of the node to retrieve
  //   sector_slot - the slot to retrive
  node_t& get_node(size_t slot, std::vector<std::pair<size_t, size_t>>& nodes,
                   size_t idx, size_t sector_slot) {
    size_t layer = nodes[idx].first;
    size_t node = nodes[idx].second;
    node_t& n = layer_files[layer][node];
    return n;
  }
};

#endif

