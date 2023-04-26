// Copyright Supranational LLC
#include <stdio.h>
#include <unistd.h>
#include <string>
#include <set>
#include <mutex>
#include <thread>
#include <spdk/stdinc.h>
#include "spdk/nvme.h"
#include "pc2_internal.hpp"
#include "streaming_node_reader.hpp"
#include "../nvme/nvme.hpp"
#include "../util/util.hpp"

std::mutex print_mtx;

#include "../util/debug_helpers.hpp"

int g_spdk_error = 0;

template<class C>
column_reader_t<C>::column_reader_t(SectorParameters& _params,
                                    streaming_node_reader_t<C>* _node_reader,
                                    size_t _batch_size, size_t _num_batches)
  : params(_params), batch_size(_batch_size),
    num_batches(_num_batches), node_reader(_node_reader)
{
  
  assert (batch_size % C::NODES_PER_PAGE == 0);
  // Pages in a single batch
  size_t num_pages = batch_size / C::NODES_PER_PAGE * params.GetNumLayers();

  page_data = (uint8_t*)spdk_dma_zmalloc(sizeof(page_t<C>) * num_pages * num_batches,
                                         PAGE_SIZE, NULL);
  assert (page_data != nullptr);
}

template<class C>
column_reader_t<C>::~column_reader_t() {
  spdk_free(page_data);
}

template<class C>
uint8_t* column_reader_t<C>::get_buffer(size_t& bytes) {
  // Pages in a single batch
  size_t num_pages = batch_size / C::NODES_PER_PAGE * params.GetNumLayers();
  bytes = sizeof(page_t<C>) * num_pages * num_batches;
  return page_data;
}

template<class C>
uint8_t* column_reader_t<C>::get_buffer_id(size_t id) {
  assert (id <  num_batches);
  size_t num_pages = batch_size / C::NODES_PER_PAGE * params.GetNumLayers();
  return &page_data[sizeof(page_t<C>) * num_pages * id];
}

template<class C>
void* column_reader_t<C>::alloc_node_ios() {
  size_t total_pages = params.GetNumLayers() * batch_size / C::NODES_PER_PAGE;
  return malloc(sizeof(node_io_batch_t) * total_pages);
}

template<class C>
void column_reader_t<C>::free_node_ios(void* node_ios) {
  free(node_ios);
}

// Starting at 'node', read all columns of 'num_nodes' nodes
template<class C>
uint8_t* column_reader_t<C>::read_columns(uint64_t node, size_t buffer_id,
                                       atomic<uint64_t>* valid, size_t* valid_count,
                                       void* node_ios) {
  assert (node % C::NODES_PER_PAGE == 0);
  uint8_t* buf = get_buffer_id(buffer_id);
  node_reader->load_layers((page_t<C>*)buf, node, batch_size, params.GetNumLayers(),
                           valid, valid_count, (node_io_batch_t*)node_ios);
  return buf;
}

template class column_reader_t<sealing_config128_t>;
template class column_reader_t<sealing_config64_t>;
template class column_reader_t<sealing_config32_t>;
template class column_reader_t<sealing_config16_t>;
template class column_reader_t<sealing_config8_t>;
template class column_reader_t<sealing_config4_t>;
template class column_reader_t<sealing_config2_t>;
