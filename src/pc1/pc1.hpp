// Copyright Supranational LLC

#ifndef __PC1_HPP__
#define __PC1_HPP__

#include "../sealing/topology_t.hpp"

// Forward declarations
class nvme_controllers_t;

template<class C>
int do_pc1(nvme_controllers_t* controllers,
           topology_t& topology,
           uint64_t block_offset,
           const uint32_t* replica_ids,
           const char* parents_filename);

#endif
