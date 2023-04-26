// Copyright Supranational LLC

#include <vector>
#include <deque>
#include <fstream>       // file read
#include <iostream>      // printing
#include <cstring>
#include <arpa/inet.h> // htonl

#include "../sealing/supra_seal.hpp"

// This ultimately comes from the sealing flows
const char* get_parent_filename() {
  switch (SECTOR_SIZE_LG) {
  case SectorSizeLg::Sector2KB:
    // 2KB
    return "/var/tmp/filecoin-parents/v28-sdr-parent-652bae61e906c0732e9eb95b1217cfa6afcce221ff92a8aedf62fa778fa765bc.cache";
  case SectorSizeLg::Sector16MB:
    // 16MB
    return "/var/tmp/filecoin-parents/v28-sdr-parent-7fa3ff8ffb57106211c4be413eb15ea072ebb363fa5a1316fe341ac8d7a03d51.cache";
  case SectorSizeLg::Sector512MB:
    // 512MB
    return "/var/tmp/filecoin-parents/v28-sdr-parent-016f31daba5a32c5933a4de666db8672051902808b79d51e9b97da39ac9981d3.cache";
  case SectorSizeLg::Sector32GB:
    // 32GB
    return "/var/tmp/filecoin-parents/v28-sdr-parent-55c7d1e6bb501cc8be94438f89b577fddda4fafa71ee9ca72eabe2f0265aefa6.cache";
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
  const char* output_dir1 = "/var/tmp/supra_seal/0";

  printf("slot0 %08lx\n", slot0);
  printf("slot1 %08lx\n", slot1);

  // Fill slot0 pc1
  printf("Starting slot0 pc1\n");
  pc1(slot0, num_sectors, replica_ids, parent_filename);

  // Slot0 PC2 + slot1 pc1
  thread j0([&]() {
    printf("Starting slot1 pc1\n");
    pc1(slot1, num_sectors, replica_ids, parent_filename);
  });
  thread j1([&]() {
    printf("Starting slot0 pc2\n");
    pc2(slot0, num_sectors, output_dir0);
  });
  j0.join();
  j1.join();

  // slot1 pc2
  printf("Starting slot1 pc2\n");
  pc2(slot1, num_sectors, output_dir1);

}

int main(int argc, char** argv) {
  uint64_t node_to_read = 0;
  uint64_t slot = 0;
  size_t   num_sectors = 64;
  const char* output_dir = "/var/tmp/supra_seal";

  enum { SEAL_MODE, READ_MODE, PARENTS_MODE, PIPELINE_MODE } mode = PIPELINE_MODE;
  bool perform_pc1 = false;
  bool perform_pc2 = false;
  bool perform_c1 = false;

  int opt;
  while ((opt = getopt(argc, argv, "123r:s:n:ph")) != -1) {
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

  supra_seal_init("src/demos/rust/supra_seal.cfg");

  // 512MB
  uint8_t replica_id_buf_512M[] = {
    37, 249, 121, 174, 70, 206, 91, 232,
    165, 246, 66, 184, 198, 10, 232, 126,
    215, 171, 221, 76, 26, 2, 117, 118,
    201, 142, 116, 143, 25, 131, 167, 37
  };
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
      pc2(block_offset, num_sectors, output_dir);      
    }

    if (perform_c1) {
      auto start = chrono::high_resolution_clock::now();
      for (size_t i = 0; i < num_sectors; i++) {
        c1(block_offset, num_sectors, i, replica_ids, SEED,
           TICKET, output_dir, get_parent_filename());
      }
      auto stop = chrono::high_resolution_clock::now();
      uint64_t secs = std::chrono::duration_cast<
        std::chrono::seconds>(stop - start).count();
      printf("c1 took %ld seconds\n", secs);
    }
  } else if (mode == READ_MODE) {
    node_read(num_sectors, node_to_read);
  }
    
  exit(0);
}
