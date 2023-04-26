// Copyright Supranational LLC

#ifndef __SUPRA_SEAL_H__
#define __SUPRA_SEAL_H__

#ifdef __cplusplus
extern "C" {
#endif

// Optional init function.
// config_file - topology config file. Defaults to supra_config.cfg
void supra_seal_init(const char* config_file);

// Perform pc1, storing the sealed layers starting at block_offset.
int pc1(uint64_t block_offset, size_t num_sectors,
        const uint8_t* replica_ids, const char* parents_filename);

// Perform pc2 for layers stored starting at block_offset.
int pc2(size_t block_offset, size_t num_sectors, const char* output_dir);

int c1(size_t block_offset,size_t num_sectors, size_t sector_slot,
       const uint8_t* replica_id, const uint8_t* seed,
       const uint8_t* ticket, const char* cache_path,
       const char* parents_filename);

// Returns the highest available block offset, which is the minimum block
// count across all attached NVMe drives, plus one. I.e., the usable blocks
// are [0 .. max).
size_t get_max_block_offset();

// Returns the size in blocks required to for the given num_sectors.
size_t get_slot_size(size_t num_sectors);

#ifdef __cplusplus
}
#endif

#endif
