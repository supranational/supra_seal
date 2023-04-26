// Copyright Supranational LLC

#ifndef __STREAMING_LAYER_READER_HPP__
#define __STREAMING_LAYER_READER_HPP__

#include <thread>
#include "../nvme/nvme.hpp"
#include "../util/stats.hpp"
#include "../util/util.hpp"
#include "../pc1/node_rw_t.hpp"

typedef batch_t<node_io_t, 1> node_io_batch_t;

// Encapsulate the SPDK portion of reading layers from NVMe
template<class C>
class streaming_node_reader_t {
  nvme_controllers_t* controllers;
  // Fixed size FIFOs for requests to the parent reader
  mt_fifo_t<node_io_batch_t> node_read_fifo;
  node_rw_t<C, node_io_batch_t>* node_reader;
  atomic<bool> terminator;
  std::thread reader_thread;
  
public:
  streaming_node_reader_t(nvme_controllers_t* _controllers, size_t qpair,
                           size_t block_offset, int core_num)
    : controllers(_controllers), terminator(false)
  {
    // Streaming reads
    SPDK_ASSERT(node_read_fifo.create("node_read_fifo", nvme_controller_t::queue_size));
    node_reader = new node_rw_t<C, node_io_batch_t>(terminator, *controllers, node_read_fifo,
                                                    qpair, block_offset);
    reader_thread = std::thread([&, core_num]() {
      set_core_affinity(core_num);
      assert(node_reader->process() == 0);
    });    
  }
  
  ~streaming_node_reader_t() {
    terminator = true;
    reader_thread.join();
    delete node_reader;
  }
  
  int load_layers(page_t<C>* pages,
                  node_id_t start_node, size_t node_count, size_t num_layers,
                  atomic<uint64_t>* valid, size_t* valid_count,
                  node_io_batch_t* node_ios) {
    size_t total_pages = num_layers * node_count / C::NODES_PER_PAGE;
    size_t node_read_fifo_free;
    while (true) {
      node_read_fifo_free = node_read_fifo.free_count();
      if (node_read_fifo_free >= total_pages) {
        break;
      }
    }

    // Valid counter
    valid->store(0);

    node_id_t node_to_read = start_node;
    assert (node_to_read.layer() == 0);

    size_t idx = 0;
    uint32_t cur_layer = start_node.layer();
    for (size_t i = 0; i < num_layers; i++) {
      for (size_t j = 0; j < node_count; j += C::NODES_PER_PAGE) {
        node_io_t& io = node_ios[idx].batch[0];
        io.type = node_io_t::type_e::READ;
        io.node = node_to_read;
        io.valid = valid;
        io.tracker.buf = (uint8_t*)&pages[idx];
          
        SPDK_ERROR(node_read_fifo.enqueue(&node_ios[idx]));

        node_to_read += C::NODES_PER_PAGE;
        idx++;
      }
      // Increment the layer
      cur_layer++;
      node_to_read = node_id_t(cur_layer, start_node.node());
    }
    *valid_count = total_pages;
    return 0;
  }
  
  int load_nodes(page_t<C>* pages, vector<node_id_t>& nodes) {
    node_io_batch_t* node_ios = new node_io_batch_t[nodes.size()];
    atomic<uint64_t> valid(0);
    for (size_t i = 0; i < nodes.size(); i++) {
      if (!node_read_fifo.is_full()) {
        node_io_t& io = node_ios[i].batch[0];
        io.type = node_io_t::type_e::READ;
        io.node = nodes[i];
        io.valid = &valid;
        io.tracker.buf = (uint8_t*)&pages[i];
        
        SPDK_ERROR(node_read_fifo.enqueue(&node_ios[i]));
      }      
    }
    while (valid < nodes.size()) {}
    delete [] node_ios;
    return 0;
  }
};

#endif

