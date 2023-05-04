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
       const char* parents_filename, const char* replica_path);

// Returns the highest available block offset, which is the minimum block
// count across all attached NVMe drives, plus one. I.e., the usable blocks
// are [0 .. max).
size_t get_max_block_offset();

// Returns the size in blocks required to for the given num_sectors.
size_t get_slot_size(size_t num_sectors);


// 32 bytes of space for the comm_ values should be preallocated prior to call

// Returns comm_c after calculating from tree file(s)
bool get_comm_c_from_tree(uint8_t* comm_c, const char* cache_path);

// Returns comm_c from p_aux file
bool get_comm_c(uint8_t* comm_c, const char* cache_path);

// Sets comm_c in the p_aux file
bool set_comm_c(uint8_t* comm_c, const char* cache_path);

// Returns comm_r_last after calculating from tree file(s)
bool get_comm_r_last_from_tree(uint8_t* comm_r_last, const char* cache_path);

// Returns comm_r_last from p_aux file
bool get_comm_r_last(uint8_t* comm_r_last, const char* cache_path);

// Sets comm_r_last in the p_aux file
bool set_comm_r_last(uint8_t* comm_r_last, const char* cache_path);

// Returns comm_r after calculating from p_aux file
bool get_comm_r(uint8_t* comm_r, const char* cache_path);

// Returns comm_d from tree_d file
bool get_comm_d(uint8_t* comm_d, const char* cache_path);

// Returns comm_d for a cc sector
bool get_cc_comm_d(uint8_t* comm_d);

#ifdef __cplusplus
}
#endif

#endif
