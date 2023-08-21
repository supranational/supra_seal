// Copyright Supranational LLC

#include <vector>
#include <deque>
#include <fstream>       // file read
#include <iostream>      // printing
#include <cstring>
#include <arpa/inet.h> // htonl
#include <filesystem>

#include "../sealing/supra_seal.hpp"

// This ultimately comes from the sealing flows
const char* get_parent_filename() {
  switch (SECTOR_SIZE_LG) {
  case SectorSizeLg::Sector2KB:
    // 2KB
    return "/var/tmp/filecoin-parents/v28-sdr-parent-494d91dc80f2df5272c4b9e129bc7ade9405225993af9fe34e6542a39a47554b.cache";
  case SectorSizeLg::Sector16MB:
    // 16MB
    return "/var/tmp/filecoin-parents/v28-sdr-parent-7fa3ff8ffb57106211c4be413eb15ea072ebb363fa5a1316fe341ac8d7a03d51.cache";
  case SectorSizeLg::Sector512MB:
    // 512MB
    return "/var/tmp/filecoin-parents/v28-sdr-parent-7ba215a1d2345774ab90b8cb1158d296e409d6068819d7b8c7baf0b25d63dc34.cache";
  case SectorSizeLg::Sector32GB:
    // 32GB
    return "/var/tmp/filecoin-parents/v28-sdr-parent-21981246c370f9d76c7a77ab273d94bde0ceb4e938292334960bce05585dc117.cache";
  default:
    printf("ERROR: unknown sector size lg %ld\n", SECTOR_SIZE_LG);
    return nullptr;
  }
}

void demo_pipeline(size_t num_sectors, uint8_t* replica_ids) {
  size_t slot0 = 0;
  size_t slot1 = get_slot_size(num_sectors) * 1;
  const char* parent_filename = get_parent_filename();
  const char* output_dir0 = "/var/tmp/supra_seal/0";
  const char* output_dir1 = "/var/tmp/supra_seal/1";

  printf("slot0 %08lx\n", slot0);
  printf("slot1 %08lx\n", slot1);

  // Fill slot0 pc1
  printf("Starting slot0 pc1\n");
  pc1(slot0, num_sectors, replica_ids, parent_filename);

  // Slot0 PC2 + slot1 pc1
  std::thread j0([&]() {
    printf("Starting slot1 pc1\n");
    pc1(slot1, num_sectors, replica_ids, parent_filename);
  });
  std::thread j1([&]() {
    printf("Starting slot0 pc2\n");
    pc2(slot0, num_sectors, output_dir0, nullptr);
  });
  j0.join();
  j1.join();

  // slot1 pc2
  printf("Starting slot1 pc2\n");
  pc2(slot1, num_sectors, output_dir1, nullptr);

}

int main(int argc, char** argv) {
  uint64_t node_to_read = 0;
  uint64_t slot = 0;
  size_t   num_sectors = 64;
  const char* output_dir = "/var/tmp/supra_seal/0";

  enum { SEAL_MODE, READ_MODE, PARENTS_MODE, PIPELINE_MODE } mode = PIPELINE_MODE;
  bool perform_pc1 = false;
  bool perform_pc2 = false;
  bool perform_c1 = false;

  int opt;
  while ((opt = getopt(argc, argv, "123r:s:n:po:h")) != -1) {
    switch (opt) {
    case '1':
      mode = SEAL_MODE;
      perform_pc1 = true;
      break;
    case '2':
      mode = SEAL_MODE;
      perform_pc2 = true;
      break;
    case '3':
      mode = SEAL_MODE;
      perform_c1 = true;
      break;
    case 'r':
      mode = READ_MODE;
      node_to_read = strtol(optarg, NULL, 16);
      break;
    case 's':
      slot = strtol(optarg, NULL, 16);
      break;
    case 'o':
      output_dir = optarg;
      break;
    case 'n':
      num_sectors = strtol(optarg, NULL, 10);
      break;
    case 'p':
      mode = PIPELINE_MODE;
      break;
    case 'h':
      printf("Usage: sudo ./seal [options]\n");
      printf("  -1 - perform pc1\n");
      printf("  -2 - perform pc2\n");
      printf("  -3 - perform c1\n");
      printf("  -p - perform pc1, pc2, and c1 pipeline (default)\n");
      printf("  -n - number of parallel sectors (default 64)\n");
      exit(0);
      break;
    }
  }

  supra_seal_init("demos/rust/supra_seal.cfg");

  // 512MB CC
  uint8_t replica_id_buf_512M[] = {
    37, 249, 121, 174, 70, 206, 91, 232,
    165, 246, 66, 184, 198, 10, 232, 126,
    215, 171, 221, 76, 26, 2, 117, 118,
    201, 142, 116, 143, 25, 131, 167, 37
  };

  // // 512mb random data
  // uint8_t replica_id_buf_512M[] = {
  //   89, 186, 126, 238, 239, 37, 73, 20,
  //   148, 180, 147, 227, 154, 153, 224, 173,
  //   101, 206, 212, 202, 229, 49, 100, 20,
  //   19, 156, 251, 17, 68, 212, 238, 32
  // };

  // 32GB
  uint8_t replica_id_buf_32G[] = {
    229, 91, 17, 249, 156, 151, 42, 202,
    166, 244, 38, 151, 243, 192, 151, 186,
    160, 136, 174, 126, 102, 91, 130, 181,
    24, 181, 140, 93, 251, 38, 207, 37
  };
  uint8_t* replica_id_buf = replica_id_buf_512M;
  if (SECTOR_SIZE_LG == (size_t)SectorSizeLg::Sector32GB) {
    replica_id_buf = replica_id_buf_32G;
  }
  uint8_t* replica_ids = new uint8_t[num_sectors * sizeof(replica_id_buf_512M)];
  assert (replica_ids != nullptr);
  for (size_t i = 0; i < num_sectors; i++) {
    memcpy(&replica_ids[sizeof(replica_id_buf_512M) * i],
           replica_id_buf, sizeof(replica_id_buf_512M));
  }

  if (mode == PIPELINE_MODE) {
    demo_pipeline(num_sectors, replica_ids);
    exit(0);
  }
  
  printf("mode %d, node_to_read %lx, slot %lx, num_sectors %ld\n",
         mode, node_to_read, slot, num_sectors);
  size_t block_offset = get_slot_size(num_sectors) * slot;
  node_to_read += block_offset;

  // Perform sealing
  if (mode == SEAL_MODE) {
    if (perform_pc1) {
      pc1(block_offset, num_sectors, replica_ids, get_parent_filename());
    }

    if (perform_pc2) {
      pc2(block_offset, num_sectors, output_dir, nullptr);
    }

    if (perform_c1) {
      std::string replica_cache_path = output_dir;
      replica_cache_path += "/replicas";
      if (!std::filesystem::exists(replica_cache_path.c_str())) {
        replica_cache_path = output_dir;
      }
      
      auto start = std::chrono::high_resolution_clock::now();
      for (size_t i = 0; i < num_sectors; i++) {
        const size_t MAX = 256;
        char sector_output_dir[MAX];
        snprintf(sector_output_dir, MAX, "%s/%03ld", output_dir, i);
        char sector_replica_dir[MAX];
        snprintf(sector_replica_dir, MAX, "%s/%03ld", replica_cache_path.c_str(), i);

        
        c1(block_offset, num_sectors, i, replica_ids, SEED,
           TICKET, sector_output_dir, get_parent_filename(),
           sector_replica_dir);
      }
      auto stop = std::chrono::high_resolution_clock::now();
      uint64_t secs = std::chrono::duration_cast<
        std::chrono::seconds>(stop - start).count();
      printf("c1 took %ld seconds\n", secs);
    }
  } else if (mode == READ_MODE) {
    node_read(num_sectors, node_to_read);
  }
    
  exit(0);
}
