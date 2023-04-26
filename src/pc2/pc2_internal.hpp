// Copyright Supranational LLC
#ifndef __PC2_INTERNAL_HPP__
#define __PC2_INTERNAL_HPP__

#include <spdk/env.h>
#include "../sealing/constants.hpp"
#include "../sealing/data_structures.hpp"
#include "column_reader.hpp"

template<class C>
void pc2_hash(SectorParameters& params, column_reader_t<C>& _reader,
              size_t _nodes_to_read, size_t _batch_size,
              size_t _stream_count, int _write_core, const char* output_dir);

#endif
