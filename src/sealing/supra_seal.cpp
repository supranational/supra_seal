// Copyright Supranational LLC

#include <vector>
#include <deque>
#include <fstream>       // file read
#include <iostream>      // printing
#include <cstring>
#include <arpa/inet.h> // htonl

// Enable profiling
//#define PROFILE

// Enable data collection in the orchestrator using the timestamp counter
//#define TSC

// Enable data collection in the hasher using the timestamp counter
//#define HASHER_TSC

// Enable more general statistics collection
//#define STATS

// Disable reading parents from disk (will not produce the correct result)
//#define NO_DISK_READS

// Print a message if the orchestrator is stalled for too long
//#define PRINT_STALLS

// Verify that hashed result matches a known good sealing
//#define VERIFY_HASH_RESULT   

#include "../pc1/pc1.hpp"
#include "../pc2/pc2.hpp"
#include "../c1/c1.hpp"
#include "../util/util.hpp"

#include "../util/debug_helpers.cpp"

class sealing_ctx_t {
public:
  nvme_controllers_t* controllers;
  topology_t* topology;
  
  sealing_ctx_t(const char* filename) {
    init(filename);
  }
  
  void init(const char* filename) {
    printf("Initializing spdk using config %s\n", filename);

    topology = new topology_t(filename);
    
    // Initialize SPDK
    struct spdk_env_opts opts;
    spdk_env_opts_init(&opts);
    opts.name = "nvme";
    int rc = spdk_env_init(&opts);
    if (rc < 0) {
      fprintf(stderr, "Unable to initialize SPDK env\n");
      exit(1);
    }

    controllers = new nvme_controllers_t(topology->get_allowed_nvme());
    controllers->init(4); // qpairs
    controllers->sort();
  
    print_parameters();
  }
};

static sealing_ctx_t* sealing_ctx = nullptr;

// TODO: cleanup / deallocate
static mutex ctx_mtx;
static void init_ctx() {
  unique_lock<mutex> lck(ctx_mtx);
  if (sealing_ctx == nullptr) {
    sealing_ctx = new sealing_ctx_t("supra_seal.cfg");
  }
}

extern "C"
void supra_seal_init(const char* config_file) {
  printf("INIT called %s\n", config_file);
  unique_lock<mutex> lck(ctx_mtx);
  if (sealing_ctx == nullptr) {
    sealing_ctx = new sealing_ctx_t(config_file);
  }
}

extern "C"
int pc1(uint64_t block_offset, size_t num_sectors,
        const uint8_t* replica_ids, const char* parents_filename) {
  init_ctx();

  switch (num_sectors) {
  case 128:
    do_pc1<sealing_config128_t>(sealing_ctx->controllers,
                                *sealing_ctx->topology,
                                block_offset,
                                (const uint32_t*)replica_ids,
                                parents_filename);
    break;
  case 64:
    do_pc1<sealing_config64_t>(sealing_ctx->controllers,
                               *sealing_ctx->topology,
                               block_offset,
                               (const uint32_t*)replica_ids,
                               parents_filename);
    break;
  case 32:
    do_pc1<sealing_config32_t>(sealing_ctx->controllers,
                               *sealing_ctx->topology,
                               block_offset,
                               (const uint32_t*)replica_ids,
                               parents_filename);
    break;
  case 16:
    do_pc1<sealing_config16_t>(sealing_ctx->controllers,
                               *sealing_ctx->topology,
                               block_offset,
                               (const uint32_t*)replica_ids,
                               parents_filename);
    break;
  case 8:
    do_pc1<sealing_config8_t>(sealing_ctx->controllers,
                              *sealing_ctx->topology,
                              block_offset,
                              (const uint32_t*)replica_ids,
                              parents_filename);
    break;
  case 4:
    do_pc1<sealing_config4_t>(sealing_ctx->controllers,
                              *sealing_ctx->topology,
                              block_offset,
                              (const uint32_t*)replica_ids,
                              parents_filename);
    break;
  case 2:
    do_pc1<sealing_config2_t>(sealing_ctx->controllers,
                              *sealing_ctx->topology,
                              block_offset,
                              (const uint32_t*)replica_ids,
                              parents_filename);
    break;
  default:
    printf("Unsupported number of sectors %ld\n", num_sectors);
    exit(1);
  }
  return 0;
}

extern "C"
int pc2(size_t block_offset, size_t num_sectors, const char* output_dir) {
  size_t qpair = 2;
  
  init_ctx();

  SectorParameters params(SECTOR_SIZE);
  int node_reader_core = sealing_ctx->topology->pc2_reader;
  int hasher_core = sealing_ctx->topology->pc2_hasher;
  int write_core = sealing_ctx->topology->pc2_writer;
  
  switch (num_sectors) {
  case 128:
    do_pc2<sealing_config128_t>(params, *sealing_ctx->controllers,
                                qpair, block_offset,
                                node_reader_core, hasher_core, write_core,
                                output_dir);
    break;
  case 64:
    do_pc2<sealing_config64_t>(params, *sealing_ctx->controllers,
                               qpair, block_offset,
                               node_reader_core, hasher_core, write_core,
                               output_dir);
    break;
  case 32:
    do_pc2<sealing_config32_t>(params, *sealing_ctx->controllers,
                               qpair, block_offset,
                               node_reader_core, hasher_core, write_core,
                               output_dir);
    break;
  case 16:
    do_pc2<sealing_config16_t>(params, *sealing_ctx->controllers,
                               qpair, block_offset,
                               node_reader_core, hasher_core, write_core,
                               output_dir);
    break;
  case 8:
    do_pc2<sealing_config8_t>(params, *sealing_ctx->controllers,
                              qpair, block_offset,
                              node_reader_core, hasher_core, write_core,
                              output_dir);
    break;
  case 4:
    do_pc2<sealing_config4_t>(params, *sealing_ctx->controllers,
                              qpair, block_offset,
                              node_reader_core, hasher_core, write_core,
                              output_dir);
    break;
  case 2:
    do_pc2<sealing_config2_t>(params, *sealing_ctx->controllers,
                              qpair, block_offset,
                              node_reader_core, hasher_core, write_core,
                              output_dir);
    break;
  default:
    printf("Unsupported number of sectors %ld\n", num_sectors);
    exit(1);
  }
  return 0;
}

extern "C"
int c1(size_t block_offset, size_t num_sectors, size_t sector_slot,
       const uint8_t* replica_id, const uint8_t* seed,
       const uint8_t* ticket, const char* cache_path,
       const char* parents_filename) {
  size_t qpair = 3;
  int node_reader_core = sealing_ctx->topology->c1_reader;
  SectorParameters params(SECTOR_SIZE);
  const char* output_dir = cache_path;
  
  init_ctx();

  switch (num_sectors) {
  case 128:
    return do_c1<sealing_config128_t>(params, sealing_ctx->controllers,
                                      qpair, node_reader_core,
                                      block_offset, num_sectors, sector_slot,
                                      replica_id, seed,
                                      ticket, cache_path,
                                      parents_filename, output_dir);
    break;
  case 64:
    return do_c1<sealing_config64_t>(params, sealing_ctx->controllers,
                                     qpair, node_reader_core,
                                     block_offset, num_sectors, sector_slot,
                                     replica_id, seed,
                                     ticket, cache_path,
                                     parents_filename, output_dir);
    break;
  case 32:
    return do_c1<sealing_config32_t>(params, sealing_ctx->controllers,
                                     qpair, node_reader_core,
                                     block_offset, num_sectors, sector_slot,
                                     replica_id, seed,
                                     ticket, cache_path,
                                     parents_filename, output_dir);
    break;
  case 16:
    return do_c1<sealing_config16_t>(params, sealing_ctx->controllers,
                                     qpair, node_reader_core,
                                     block_offset, num_sectors, sector_slot,
                                     replica_id, seed,
                                     ticket, cache_path,
                                     parents_filename, output_dir);
    break;
  case 8:
    return do_c1<sealing_config8_t>(params, sealing_ctx->controllers,
                                    qpair, node_reader_core,
                                    block_offset, num_sectors, sector_slot,
                                    replica_id, seed,
                                    ticket, cache_path,
                                    parents_filename, output_dir);
    break;
  case 4:
    return do_c1<sealing_config4_t>(params, sealing_ctx->controllers,
                                    qpair, node_reader_core,
                                    block_offset, num_sectors, sector_slot,
                                    replica_id, seed,
                                    ticket, cache_path,
                                    parents_filename, output_dir);
    break;
  case 2:
    return do_c1<sealing_config2_t>(params, sealing_ctx->controllers,
                                    qpair, node_reader_core,
                                    block_offset, num_sectors, sector_slot,
                                    replica_id, seed,
                                    ticket, cache_path,
                                    parents_filename, output_dir);
    break;
  }
  
  return 0;
}

template<class C>
int do_node_read(uint64_t node_to_read) {
  // Read and print a hashed node
  size_t pages_to_read = 1;

  init_ctx();
  
  page_t<C> *pages = (page_t<C> *)
    spdk_dma_zmalloc(sizeof(page_t<C>) * pages_to_read, PAGE_SIZE, NULL);
  assert (pages != nullptr);

  size_t ctrl_id;
  size_t block_on_controller;
  nvme_node_indexes<C>(sealing_ctx->controllers->size(),
                       node_to_read, ctrl_id, block_on_controller);

  printf("Reading block %ld on controller %ld\n", block_on_controller, ctrl_id);
    
  sequential_io_t sio((*sealing_ctx->controllers)[ctrl_id]);
  SPDK_ERROR(sio.rw(true, pages_to_read, (uint8_t *)&pages[0], block_on_controller));

  size_t node_in_page = node_to_read % C::NODES_PER_PAGE;
  printf("Node %8lx, ctrl %ld, block %ld, node_in_page %ld\n",
         node_to_read, ctrl_id, block_on_controller, node_in_page);
    
  char prefix[32];
  snprintf(prefix, 32, "Node %8lx: ", node_to_read);
  print_node<C>(&pages[0].parallel_nodes[node_in_page], 0, prefix, true);
  return 0;
}

int node_read(size_t num_sectors, uint64_t node_to_read) {
  switch (num_sectors) {
  case 128:
    do_node_read<sealing_config128_t>(node_to_read);
    break;
  case 64:
    do_node_read<sealing_config64_t>(node_to_read);
    break;
  case 32:
    do_node_read<sealing_config32_t>(node_to_read);
    break;
  case 16:
    do_node_read<sealing_config16_t>(node_to_read);
    break;
  case 8:
    do_node_read<sealing_config8_t>(node_to_read);
    break;
  case 4:
    do_node_read<sealing_config4_t>(node_to_read);
    break;
  case 2:
    do_node_read<sealing_config2_t>(node_to_read);
    break;
  default:
    printf("Unsupported number of sectors %ld\n", num_sectors);
    exit(1);
  }
  return 0;
}

extern "C"
size_t get_max_block_offset() {
  init_ctx();
  if (sealing_ctx->controllers[0].size() == 0) {
    return 0;
  }
  size_t min_block = (*sealing_ctx->controllers)[0].get_page_count(0);
  for (size_t i = 1; i < (*sealing_ctx->controllers).size(); i++) {
    size_t blocks = (*sealing_ctx->controllers)[i].get_page_count(0);
    if (min_block > blocks) {
      min_block = blocks;
    }
  }
  return min_block;
}

extern "C"
size_t get_slot_size(size_t num_sectors) {
  init_ctx();

  size_t pages_per_layer = 0;
  switch (num_sectors) {
  case 128:
    pages_per_layer = sealing_config128_t::PAGES_PER_LAYER;
    break;
  case 64:
    pages_per_layer = sealing_config64_t::PAGES_PER_LAYER;
    break;
  case 32:
    pages_per_layer = sealing_config32_t::PAGES_PER_LAYER;
    break;
  case 16:
    pages_per_layer = sealing_config16_t::PAGES_PER_LAYER;
    break;
  case 8:
    pages_per_layer = sealing_config8_t::PAGES_PER_LAYER;
    break;
  case 4:
    pages_per_layer = sealing_config4_t::PAGES_PER_LAYER;
    break;
  case 2:
    pages_per_layer = sealing_config2_t::PAGES_PER_LAYER;
    break;
  default:
    printf("Unsupported number of sectors %ld\n", num_sectors);
    exit(1);
  }
  size_t num_controllers = sealing_ctx->controllers[0].size();
  size_t pages_per_layer_per_controller =
    ((pages_per_layer + num_controllers - 1) / num_controllers);
  return pages_per_layer_per_controller * LAYER_COUNT;
}
