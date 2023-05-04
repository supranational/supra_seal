// Copyright Supranational LLC

#include "../sealing/constants.hpp"
#include "../poseidon/poseidon.hpp"
#include <util/thread_pool_t.hpp>
#include "../util/debug_helpers.hpp"
#include "poseidon.cpp"
#include "../util/mmap_t.hpp"
#include <chrono>
typedef std::chrono::high_resolution_clock::time_point timestamp_t;

// Multi and single threaded tree builder class using Poseidon.
// Options
//   arity        - tree arity
//   discard rows - number of rows to discard (ie not write to the output buffer)
class TreeBuilder {
private:
  size_t   arity_;
  size_t   discard_rows_;
  Poseidon hasher_;

public:
  TreeBuilder(size_t arity, size_t discard_rows) :
    arity_(arity),
    discard_rows_(discard_rows),
    hasher_(arity)
  {}

  // Compute the size to store the tree
  size_t size(size_t count, bool no_discard = false) {
    assert (count % arity_ == 0);
    size_t cur_count = count;
    size_t total = 0;
    size_t discards_left = (no_discard || discard_rows_ == 0) ? 0 : discard_rows_;
    while (cur_count > 1) {
      if (discards_left > 0) {
        discards_left--;
      } else {
        total += cur_count / arity_;
      }
      cur_count /= arity_;
    }
    return total;
  }
  
  // out - hash result
  // in  - pointer to array of arity elements
  void HashNode(node_t* out, node_t* in) {
    hasher_.Hash((uint8_t*)out, (uint8_t*)in);
  }

  // Single threaded tree builder - uses the calling thread
  // out - storage for non-discarded tree levels
  // in  - tree leaves
  void BuildTree(size_t count, node_t* out, node_t* in,
                 bool no_discard = false) {
    assert (count % arity_ == 0);
    
    // Pointer to hash output location
    node_t* cur_hash_out = out;
    node_t* cur_hash_in = in;

    // Allocate temp storage for discarded rows. The leaves count
    // as the first discarded row. However it is left to the
    // caller to copy the leaves to 'out' if desired.
    node_t* local_store = nullptr;
    size_t discards_left = (no_discard || discard_rows_ == 0) ? 0 : discard_rows_ - 1;
    if (discards_left > 0) {
      local_store = new node_t[count / arity_];
      cur_hash_out = local_store;
    }
    
    size_t cur_count = count;
    bool final_discard = false;
    while (cur_count > 1) {
      node_t* tree_start = cur_hash_out;
      for (size_t i = 0; i < cur_count; i += arity_) {
        HashNode(cur_hash_out, cur_hash_in);
        cur_hash_in += arity_;
        cur_hash_out++;
      }
      cur_hash_in = tree_start;
      cur_count  /= arity_;

      // Logic to switch from temp storage to out after
      // the desired rows are discarded
      if (discards_left > 0) {
        cur_hash_out = local_store;
        discards_left--;
        final_discard = discards_left == 0;
      } else if(final_discard) {
        final_discard = false;
        cur_hash_out = out;
      }
    }
    cur_hash_out--;
    delete [] local_store;
    print_buffer((uint8_t*)cur_hash_out, sizeof(node_t));
  }

  // Multi-threaded tree builder
  // out - storage for non-discarded tree levels
  // in  - tree leaves
  void BuildTree(size_t count, node_t* out, node_t* in,
                 thread_pool_t& pool, bool no_discard = false) {
    assert (count % arity_ == 0);

    // Allocate temp storage for discarded rows. The leaves count
    // as the first discarded row. However it is left to the
    // caller to copy the leaves to 'out' if desired.
    node_t* local_store = nullptr;
    size_t discards = (no_discard || discard_rows_ == 0) ? 0 : discard_rows_ - 1;
    if (discards > 0) {
      local_store = new node_t[count / arity_];
    }

    // For efficient multithreading, divide the tree into
    // a number of chunks that is significantly larger than
    // cores then use an atomic work counter to process them.
    size_t num_chunks = arity_;
    // Create enough chunks to provide good load balancing
    size_t min_chunks = pool.size() * 4;
    while (num_chunks < min_chunks) {
      num_chunks *= arity_;
    }
    size_t chunk_size = count / num_chunks;
    size_t top_tree_size = size(num_chunks * arity_, true);

    pool.par_map(num_chunks, [this, in, out, local_store, count, discards,
                              chunk_size](size_t chunk) {
      // Pointer to hash output location
      node_t* layer_out_start = out;
      size_t layer_size = count;

      // If there are discard rows start by using the local storage
      size_t discards_left = discards;
      node_t* cur_hash_out = (discards_left > 0 ?
                              &local_store[chunk * chunk_size / arity_] :
                              &out[chunk * chunk_size / arity_]);
      node_t* cur_hash_in = &in[chunk * chunk_size];

      size_t cur_count = chunk_size;
      bool final_discard = false;
      while (cur_count > 1) {
        node_t* tree_start = cur_hash_out;
        for (size_t i = 0; i < cur_count; i += arity_) {
          HashNode(cur_hash_out, cur_hash_in);
          cur_hash_in += arity_;
          cur_hash_out++;
        }
        cur_hash_in = tree_start;
        cur_count  /= arity_;

        layer_size /= arity_;
        
        // Logic to switch from temp local storage to 'out' after
        // the desired rows are discarded
        if (discards_left > 0) {
          // Reuse the temp buffer
          cur_hash_out = tree_start;
          discards_left--;
          final_discard = discards_left == 0;
        } else if(final_discard) {
          // Switch to the output buffer
          final_discard = false;
          cur_hash_out = &out[chunk * cur_count / arity_];
        } else {
          layer_out_start += layer_size;
          cur_hash_out = &layer_out_start[chunk * cur_count / arity_];
        }
      }
    });
    delete [] local_store;

    // Merge the chunks
    size_t top_tree_start_idx = size(count) - top_tree_size;
    node_t* top_tree_start = &out[top_tree_start_idx];
    BuildTree(num_chunks, &top_tree_start[num_chunks], top_tree_start, true);
  }
};

// Tree-r builder for Filecoin sealing with optional data encoding
class TreeR {
public:
  void ElementAdd(uint8_t* out, uint8_t* a, uint8_t* b) {
    fr_t a_mont;
    a_mont.to(a, 32, true);

    fr_t* out_ptr = (fr_t*)out;
    out_ptr->to(b, 32, true);

    *out_ptr += a_mont;

    out_ptr->to_scalar(*((fr_t::pow_t*)out));
  }

  // // TODO: This is no faster - presumably disk IO limited
  // void ElementAdd(node_t* out, node_t a, node_t b) {
  //   a.reverse_l();
  //   b.reverse_l();
  //   fr_t* fra = (fr_t*)&a;
  //   fr_t* frb = (fr_t*)&b;
  //   fr_t* frout = (fr_t*)out;
  //   *frout = *fra + *frb;
  //   out->reverse_l();
  // }

  void BuildTreeR(std::string last_layer_filename,
                  std::string data_filename,
                  std::string output_path,
                  int num_threads = 0) {
    thread_pool_t pool(num_threads);
    
    mmap_t<node_t> last_layer;
    last_layer.mmap_read(last_layer_filename, (size_t)-1);
    size_t last_layer_size = last_layer.get_size();
    SectorParameters params(last_layer_size);

    printf("Building tree-r for sector size %ld\n", params.GetSectorSize());
    
    size_t cur_nodes = last_layer_size / sizeof(node_t);

    node_t* leaves = &last_layer[0];

    // Encode the data, if provided
    mmap_t<node_t> sealed_file;
    node_t* encoded_leaves = nullptr;
    if (!data_filename.empty()) {
      size_t num_chunks = pool.size() * 4;
      size_t chunk_size = (cur_nodes + num_chunks - 1) / num_chunks;

      std::string sealed_filename = output_path + "/sealed-file";
      sealed_file.mmap_write(sealed_filename, last_layer_size, true);
      encoded_leaves = &sealed_file[0];
      
      mmap_t<node_t> data_file;
      data_file.mmap_read(data_filename, last_layer_size);

      printf("Encoding data...\n");
      timestamp_t start = std::chrono::high_resolution_clock::now();
      pool.par_map(num_chunks, [&](size_t chunk) {
        size_t start = chunk * chunk_size;
        size_t stop = std::min(start + chunk_size, cur_nodes);
        for (size_t i = start; i < stop; ++i) {
          ElementAdd((uint8_t*)&(encoded_leaves[i]),
                     (uint8_t*)&(data_file[i]),
                     (uint8_t*)&(last_layer[i]));
        }
      });
      timestamp_t stop = std::chrono::high_resolution_clock::now();
      uint64_t secs = std::chrono::duration_cast<
        std::chrono::seconds>(stop - start).count();
      printf("Encoding took %ld seconds\n", secs);
    }

    TreeBuilder tree_r(params.GetNumTreeRCArity(), params.GetNumTreeRDiscardRows());
    size_t elmts = tree_r.size(cur_nodes);

    printf("Building tree-r...\n");
    timestamp_t start = std::chrono::high_resolution_clock::now();
    if (!output_path.empty()) {
      const size_t MAX = 256;
      char fname[MAX];
      if (params.GetNumTreeRCFiles() > 1) {
        const char *tree_r_filename_template = "%s/sc-02-data-tree-r-last-%ld.dat";
        size_t sub_tree_size = cur_nodes / params.GetNumTreeRCFiles();
        for (size_t i = 0; i < params.GetNumTreeRCFiles(); i++) {
          snprintf(fname, MAX, tree_r_filename_template, output_path.c_str(), i);
          mmap_t<node_t> out_file;
          out_file.mmap_write(fname, elmts * sizeof(node_t), true);
          tree_r.BuildTree(sub_tree_size, &out_file[0], &leaves[i * sub_tree_size], pool);
        }
      } else {
        const char *tree_r_filename_template = "%s/sc-02-data-tree-r-last.dat";
        snprintf(fname, MAX, tree_r_filename_template, output_path.c_str());
        mmap_t<node_t> out_file;
        out_file.mmap_write(fname, elmts * sizeof(node_t), true);
        tree_r.BuildTree(cur_nodes, &out_file[0], leaves, pool);
      }
    } else {
      node_t* store = new node_t[elmts];
      tree_r.BuildTree(cur_nodes, store, leaves, pool);
      delete [] store;
    }
    timestamp_t stop = std::chrono::high_resolution_clock::now();
    uint64_t secs = std::chrono::duration_cast<
      std::chrono::seconds>(stop - start).count();
    printf("Tree-r took %ld seconds\n", secs);
  }
};
