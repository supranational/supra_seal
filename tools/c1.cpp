// Copyright Supranational LLC

#include <string>
#include "../sealing/constants.hpp"
#include "../c1/streaming_node_reader_files.hpp"
#include "../c1/c1.hpp"
#include "../poseidon/poseidon.cpp"

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

int main() {
  SectorParameters params(SECTOR_SIZE);

  // TODO - get these values from command line
  const uint8_t* seed       = SEED;
  const uint8_t* ticket     = TICKET;

  std::string cache_path = "/var/tmp/cache_benchy_run_32g/";
  if (SECTOR_SIZE_LG == (size_t)SectorSizeLg::Sector512MB) {
    cache_path = "/var/tmp/cache_benchy_run_512MiB_0/";
  }

  // 512MB
  uint8_t replica_id_buf_512M[] __attribute__ ((aligned (32))) = {
    37, 249, 121, 174, 70, 206, 91, 232,
    165, 246, 66, 184, 198, 10, 232, 126,
    215, 171, 221, 76, 26, 2, 117, 118,
    201, 142, 116, 143, 25, 131, 167, 37
  };
  // 32GB
  uint8_t replica_id_buf_32G[] __attribute__ ((aligned (32))) = {
/*
    229, 91, 17, 249, 156, 151, 42, 202,
    166, 244, 38, 151, 243, 192, 151, 186,
    160, 136, 174, 126, 102, 91, 130, 181,
    24, 181, 140, 93, 251, 38, 207, 37
*/
    186,  90, 122, 235, 167, 168, 174, 141,
    12, 118, 248,  12, 198, 220, 168,  96,
    112, 178,  12,  55,  20,  67,  88,   8,
    200,  67,   3, 165, 128, 246, 124,  50
  };
  uint8_t* replica_id_buf = replica_id_buf_512M;
  if (SECTOR_SIZE_LG == (size_t)SectorSizeLg::Sector32GB) {
    replica_id_buf = replica_id_buf_32G;
  }

  size_t layer_count = params.GetNumLayers();

  std::vector<std::string> filenames;
  std::string prefix = "sc-02-data-layer-";
  for (size_t l = 0; l < layer_count; ++l) {
    std::string layer_file = cache_path + prefix + std::to_string(l + 1) + ".dat";
    filenames.push_back(layer_file);
  }

  streaming_node_reader_t<sealing_config1_t> reader(params, filenames, SECTOR_SIZE);

  do_c1<sealing_config1_t>(params, reader,
                           1, // num_sectors
                           0, // sector_slot
                           replica_id_buf, seed, ticket,
                           cache_path.c_str(),
                           get_parent_filename(),
                           cache_path.c_str(),       // replica_path
                           "/var/tmp/supra_seal/0");

  // Example for building tree and node proofs separately then combining
  do_c1_tree<sealing_config1_t>(params, reader,
                                1, // num_sectors
                                0, // sector_slot
                                replica_id_buf, seed, nullptr,
                                cache_path.c_str(),
                                nullptr,
                                cache_path.c_str(),       // replica_path
                                "/var/tmp/supra_seal/0");

  do_c1_node<sealing_config1_t>(params, reader,
                                1, // num_sectors
                                0, // sector_slot
                                replica_id_buf, seed, ticket,
                                cache_path.c_str(),
                                get_parent_filename(),
                                nullptr,
                                "/var/tmp/supra_seal/0");

  do_c1_comb<sealing_config1_t>(params, reader,
                                1, // num_sectors
                                0, // sector_slot
                                nullptr, nullptr, nullptr,
                                nullptr, nullptr, nullptr,
                                "/var/tmp/supra_seal/0");

  return 0;
}
