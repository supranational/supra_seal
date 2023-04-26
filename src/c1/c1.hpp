// Copyright Supranational LLC

#ifndef __C1_HPP__
#define __C1_HPP__

#include "../sealing/constants.hpp"

class nvme_controllers_t;

template<class C>
int do_c1(SectorParameters& params, nvme_controllers_t* _controllers,
          size_t qpair, int core_num,
          size_t block_offset, size_t num_sectors, size_t sector_slot,
          const uint8_t* replica_id, const uint8_t* seed,
          const uint8_t* ticket, const char* cache_path,
          const char* parents_filename, const char* output_dir);

#endif
