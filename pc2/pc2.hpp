// Copyright Supranational LLC
#ifndef __PC2_HPP__
#define __PC2_HPP__

#include "pc2_internal.hpp"
#include "../util/util.hpp"

template<class C>
int do_pc2(SectorParameters& params, topology_t& topology,
           nvme_controllers_t& controllers, size_t block_offset,
           const char** data_filenames, const char* output_dir) {
  set_core_affinity(topology.pc2_hasher);
  
  // Total number of streams across all GPUs
  size_t stream_count = 64;

  // Batch size in nodes. Each node includes all parallel sectors
  // TODO: try larger batch size for 32GB
  size_t batch_size = 64;
  assert (batch_size % params.GetNumTreeRCArity() == 0);
  
  // Nodes to read per partition
  size_t nodes_to_read = params.GetNumNodes() / params.GetNumTreeRCFiles();

  streaming_node_reader_t<C> node_reader(&controllers, topology.pc2_qpair,
                                         block_offset, topology.pc2_reader,
                                         (size_t)topology.pc2_sleep_time);

  // Allocate storage for 2x the streams to support tree-c and tree-r
  // PC2 assumes that nodes for subsequent layers are contiguous, so each
  // layer's nodes should fill some number of pages.
  assert (batch_size % C::NODES_PER_PAGE == 0);
  node_reader.alloc_slots(stream_count * 2, params.GetNumLayers() * batch_size, true);

  bool tree_r_only = false;
  pc2_hash<C>(params, topology, tree_r_only, node_reader,
              nodes_to_read, batch_size, stream_count,
              data_filenames, output_dir);
  return 0;
}

#endif
