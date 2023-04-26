// Copyright Supranational LLC
#ifndef __PC2_HPP__
#define __PC2_HPP__

#include "pc2_internal.hpp"
#include "streaming_node_reader.hpp"

template<class C>
int do_pc2(SectorParameters& params, nvme_controllers_t& controllers,
           size_t qpair, size_t block_offset,
           int node_reader_core, int hasher_core, int write_core,
           const char* output_dir) {
  set_core_affinity(hasher_core);
  
  // Total number of streams across all GPUs
  size_t stream_count = 64;

  // Batch size in nodes. Each node includes all parallel sectors
  size_t batch_size = 64;

  // Nodes to read per partition
  size_t nodes_to_read = params.GetNumNodes() / params.GetNumTreeRCFiles();

  streaming_node_reader_t<C> node_reader(&controllers, qpair,
                                          block_offset, node_reader_core);
  
  // Allocate storage for 2x the streams to support tree-c and tree-r
  column_reader_t<C> column_reader(params, &node_reader, batch_size, stream_count * 2);

  pc2_hash<C>(params, column_reader,
              nodes_to_read, batch_size, stream_count,
              write_core, output_dir);
  return 0;
}

#endif
