// Copyright Supranational LLC

// Filecoin Sealing Commit 1 (C1) operation
//  Only 2KB and 32G are currently tested and supported

#include <cstdint>             // uint*
#include <cstring>             // memcpy
#include <fstream>             // file read
#include <fcntl.h>             // file open
#include <unistd.h>            // file close
#include <sys/mman.h>          // mapping
#include <sys/stat.h>          // file stats
#include <iostream>            // printing
#include <iomanip>             // printing
#include <cassert>             // assertions
#include <cmath>               // log2
#include <gmp.h>               // gmp for challenge modulo operation
#include <vector>              //

#include "c1.hpp"
#include <ff/bls12-381.hpp>
#include "tree_d_cc_nodes.h"
#include "../poseidon/poseidon.hpp"
#include "../sha/sha_functions.hpp"

#include "../nvme/nvme.hpp"

#include "path_element.hpp"
#include "tree_proof.hpp"
#include "column_proof.hpp"
#include "label_proof.hpp"
#include "challenge.hpp"


template<class C>
class C1 {
 public:
  C1(SectorParameters* params, streaming_node_reader_t<C>& reader,
     size_t sector_slot);
  ~C1();

  node_t* CreateReplicaID(const uint8_t* prover_id, uint64_t sector_id,
                          const uint8_t* ticket, const uint8_t* comm_d,
                          const uint8_t* porep_seed);
  void ForceReplicaID(const node_t* replica_id); // TODO - remove

  void DeriveChallenges(const uint8_t* seed);

  void SetTreeRBufs(const char* tree_r_cache, const char* file_prefix) {
    size_t num_files = params_->GetNumTreeRCFiles();
    tree_r_bufs_ = new node_t*[num_files]{ nullptr };
    tree_r_bufs_file_size_ = SetTreeBufs(tree_r_bufs_, tree_r_cache,
                                         file_prefix, num_files);
  }

  void SetTreeCBufs(const char* tree_c_cache, const char* file_prefix) {
    size_t num_files = params_->GetNumTreeRCFiles();
    tree_c_bufs_ = new node_t*[num_files]{ nullptr };
    tree_c_bufs_file_size_ = SetTreeBufs(tree_c_bufs_, tree_c_cache,
                                         file_prefix, num_files);
  }

  void GetRoots(const char* cache);
  void SetParentsBuf(const char* filename);

  void WriteProofs(const char* filename);

 private:
  void WriteTreeDProof(uint64_t challenge);
  size_t SetTreeBufs(node_t** bufs, const char* cache,
                     const char* prefix, size_t num_files);

  SectorParameters* params_;
  streaming_node_reader_t<C>& reader_;
  size_t            sector_slot_;
  node_t            replica_id_;
  uint64_t*         challenges_;
  size_t            challenges_count_;
  node_t**          tree_r_bufs_;
  node_t**          tree_c_bufs_;
  size_t            tree_r_bufs_file_size_;
  size_t            tree_c_bufs_file_size_;
  node_t            tree_c_root_;
  node_t            tree_r_root_;
  node_t            comm_r_;
  node_t*           comm_d_;
  node_t*           seed_;
  node_t*           ticket_;
  uint32_t*         parents_buf_;
  size_t            parents_buf_size_;
};

template<class C>
C1<C>::C1(SectorParameters* params, streaming_node_reader_t<C>& reader,
          size_t sector_slot) :
  params_(params), reader_(reader), sector_slot_(sector_slot) {

  challenges_count_ = params->GetNumChallenges() / params->GetNumPartitions();

  challenges_  = nullptr;
  tree_r_bufs_ = nullptr;
  tree_c_bufs_ = nullptr;
  parents_buf_ = nullptr;
}

template<class C>
C1<C>::~C1() {
  if (challenges_  != nullptr) delete challenges_;

  size_t tree_files = params_->GetNumTreeRCFiles();
  if (tree_r_bufs_ != nullptr) {
    for (size_t l = 0; l < tree_files; ++l) {
      munmap(tree_r_bufs_[l], tree_r_bufs_file_size_);
    }
    delete tree_r_bufs_;
  }

  if (tree_c_bufs_ != nullptr) {
    for (size_t l = 0; l < tree_files; ++l) {
      munmap(tree_c_bufs_[l], tree_c_bufs_file_size_);
    }
    delete tree_c_bufs_;
  }

  if (parents_buf_ != nullptr) {
    // TODO: this is the parents file
    const size_t PARENTS_BUF_SIZE  = NODE_COUNT * PARENT_COUNT * PARENT_SIZE;
    munmap(parents_buf_, PARENTS_BUF_SIZE);
  }
}

template<class C>
void C1<C>::ForceReplicaID(const node_t* replica_id) {
  std::memcpy(&replica_id_, replica_id,  sizeof(node_t));
  comm_d_ = (node_t*) CC_TREE_D_NODE_VALUES[params_->GetNumTreeDLevels()];
  ticket_ = (node_t*) TICKET;
}

template<class C>
node_t* C1<C>::CreateReplicaID(const uint8_t* prover_id,
                              uint64_t       sector_id,
                              const uint8_t* ticket,
                              const uint8_t* comm_d,
                              const uint8_t* porep_seed) {
  comm_d_ = (node_t*) comm_d;
  ticket_ = (node_t*) ticket;

  uint8_t buf[192] = {0};

  std::memcpy(buf,       prover_id,  32);
  std::memcpy(buf +  32, &sector_id,  8);
  std::memcpy(buf +  40, ticket,     32);
  std::memcpy(buf +  72, comm_d,     32);
  std::memcpy(buf + 104, porep_seed, 32);

  // Add padding and length (1088 bits -> 0x440)
  buf[136] = 0x80;
  buf[190] = 0x04;
  buf[191] = 0x40;

  // Initialize digest
  std::memcpy(&replica_id_, SHA256_INITIAL_DIGEST, 32);

  // Hash buffer, takes 3 SHA-256 blocks
  blst_sha256_block((uint32_t*)&replica_id_, buf, 3);

  // Top two bits cutoff due to keeping in field
  replica_id_.limbs[7] &= 0xFFFFFF3F;

  return &replica_id_;
}

// https://spec.filecoin.io/#section-algorithms.sdr.porep-challenges
template<class C>
void C1<C>::DeriveChallenges(const uint8_t* seed) {
  seed_   = (node_t*) seed;

  uint32_t hash[8];
  size_t leaves = params_->GetNumLeaves();
  challenges_   = new uint64_t[params_->GetNumChallenges()];

  for (uint8_t k = 0; k < params_->GetNumPartitions(); ++k) {
    uint8_t buf[128] = {0};
    std::memcpy(buf, &replica_id_, 32);
    std::memcpy(buf + 32, seed, 32);
    buf[68] = 0x80;  // padding
    // 544 bits -> 0x220
    buf[126] = 0x02; // padding length
    buf[127] = 0x20; // padding length
  
    mpz_t gmp_challenge;
    mpz_init(gmp_challenge);
  
    for (size_t i = 0; i < challenges_count_; ++i) {
      uint32_t j = (uint32_t)((challenges_count_ * k) + i);
      buf[64] = (uint8_t)(j & 0xFF);
      buf[65] = (uint8_t)((j >> 8) & 0xFF);
  
      std::memcpy(hash, SHA256_INITIAL_DIGEST, NODE_SIZE);
      blst_sha256_block(hash, buf, 2);
      blst_sha256_emit((uint8_t*)hash, hash);
  
      mpz_import(gmp_challenge, 8, -1, 4, 0, 0, hash);

      // Resulting challenge must be a leaf index and not the first leaf
      // Use gmp to perform modulo operation
      challenges_[i + (k * challenges_count_)] =
        mpz_mod_ui(gmp_challenge, gmp_challenge, leaves - 1) + 1;
    }
  }
}

template<class C>
void C1<C>::SetParentsBuf(const char* filename) {
  int parents_fd = open(filename, O_RDONLY);
  assert (parents_fd != -1);
  struct stat buf;
  fstat(parents_fd, &buf);
  parents_buf_size_ = buf.st_size;
  parents_buf_ = (uint32_t*)mmap(NULL, parents_buf_size_, PROT_READ,
                                 MAP_SHARED, parents_fd, 0);
  if (parents_buf_ == MAP_FAILED) {
    perror("mmap failed for parents file");
    exit(1);
  }
  close(parents_fd);
}

template<class C>
size_t C1<C>::SetTreeBufs(node_t** bufs, const char* cache,
                          const char* prefix, size_t num_files) {
  size_t file_size = 0;
  for (size_t l = 0; l < num_files; ++l) {
    const size_t MAX = 256;
    char fname[MAX];
    snprintf(fname, MAX, prefix, cache, sector_slot_, l);

    int tree_fd = open(fname, O_RDONLY);
    if (tree_fd == -1) {
      printf("Failed to open tree file %s\n", fname);
    }

    assert (tree_fd != -1);
    struct stat buf;
    fstat(tree_fd, &buf);
    bufs[l] = (node_t*)mmap(NULL, buf.st_size, PROT_READ, MAP_SHARED,
                              tree_fd, 0);
    file_size = buf.st_size;
    if (bufs[l] == MAP_FAILED) {
      perror("mmap failed for tree file");
      exit(1);
    }
    close(tree_fd);
  }
  return file_size;
}

template<class C>
void C1<C>::GetRoots(const char* cache) {
  // Get tree_c_root and tree_r_last_root from p_aux file
  const char* p_aux_template = "%s/p_aux-s-%03ld.dat";
  const size_t MAX = 256;
  char fname[MAX];
  snprintf(fname, MAX, p_aux_template, cache, sector_slot_);
  
  int p_aux_fd = open(fname, O_RDONLY);
  assert (p_aux_fd != -1);
  node_t* p_aux_buf = (node_t*)mmap(NULL, sizeof(node_t) * 2, PROT_READ,
                                        MAP_PRIVATE, p_aux_fd, 0);
  close(p_aux_fd);

  if (p_aux_buf == MAP_FAILED) {
    perror("mmap failed for p_aux file");
    exit(1);
  }

  std::memcpy(&tree_c_root_, &(p_aux_buf[0]), sizeof(node_t));
  std::memcpy(&tree_r_root_, &(p_aux_buf[1]), sizeof(node_t));

  // Calculate comm r
  Poseidon poseidon_comm_r(2);
  poseidon_comm_r.Hash((uint8_t*)&comm_r_, (uint8_t*)p_aux_buf);

  munmap(p_aux_buf, sizeof(node_t) * 2);
}

template<class C>
void C1<C>::WriteProofs(const char* filename) {
  remove(filename);
  int commit_file = open(filename, O_EXCL | O_CREAT | O_RDWR,
                         S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH);
  if (commit_file == -1) {
    std::cout << "Error opening " << filename << std::endl;
    std::cout << "Make sure it is deleted first" << std::endl;
    exit(1);
  }
// TODO - figure out COMMIT_FILE_SIZE
  posix_fallocate(commit_file, 0, COMMIT_FILE_SIZE);

  uint8_t* file_ptr = (uint8_t*)mmap(NULL, COMMIT_FILE_SIZE,
                                     PROT_WRITE, MAP_SHARED, commit_file, 0);
  size_t buf_index = 0;

  // Need to put together  pub vanilla_proofs: Vec<Vec<VanillaSealProof<Tree>>>,
  uint64_t vp_outer_length = params_->GetNumPartitions();
  uint64_t vp_inner_length = challenges_count_;

  std::memcpy(file_ptr + buf_index, &vp_outer_length, sizeof(uint64_t));
  buf_index += sizeof(uint64_t);

  for (uint64_t i = 0; i < vp_outer_length; ++i) {
    std::memcpy(file_ptr + buf_index, &vp_inner_length, sizeof(uint64_t));
    buf_index += sizeof(uint64_t);

    for (uint64_t j = 0; j < vp_inner_length; ++j) {
      C1Challenge<C> challenge(challenges_[j + (i * challenges_count_)], params_,
                               &tree_r_root_, &tree_c_root_);
      challenge.GetParents(parents_buf_);
      challenge.GetNodes(reader_, sector_slot_);
      buf_index = challenge.WriteProof(file_ptr, buf_index,
                                       tree_r_bufs_, tree_c_bufs_);
    }
  }

  // Comm R
  std::memcpy(file_ptr + buf_index, &comm_r_, sizeof(node_t));
  buf_index += sizeof(node_t);

  // Comm D
  std::memcpy(file_ptr + buf_index, comm_d_, sizeof(node_t));
  buf_index += sizeof(node_t);

  // Replica ID
  std::memcpy(file_ptr + buf_index, &replica_id_, sizeof(node_t));
  buf_index += sizeof(node_t);

  // Seed
  std::memcpy(file_ptr + buf_index, seed_, sizeof(node_t));
  buf_index += sizeof(node_t);

  // Ticket
  std::memcpy(file_ptr + buf_index, ticket_, sizeof(node_t));
  buf_index += sizeof(node_t);

  munmap(file_ptr, COMMIT_FILE_SIZE);
  close(commit_file);
}



/*
pub struct RemoteCommit1RequestBody {
    pub ticket: String,
    pub seed: String,
    pub unsealed: Map<String, serde_json::Value>,
    pub sealed: Map<String, serde_json::Value>,
    pub proof_type: usize,
}

    porep_config: PoRepConfig,
      sector_size
      partitions
      porep_id
      api_version
    cache_path: T,
    replica_path: T,
    prover_id: ProverId,
    sector_id: SectorId,
    ticket: Ticket,
    seed: Ticket,
    pre_commit: SealPreCommitOutput,
    piece_infos: &[PieceInfo],

// Inputs required
//  replica_id
//  seed
//  ticket
//  p_aux file or data directly (comm_c and comm_r_last)
//  parents cache file - this is fixed location
//  labels file(s) - eventually from NVME raw blocks through spdk
//  tree c file(s) - PC2 output, can be in raw blocks or any number of files
//  tree r file(s) - PC2 output, can be in raw blocks or any number of files
//                    we will support the default discarded rows

  sector size
  seed
  ticket
  replica_id
    prover_id
    sector_id
    ticket
    comm_d
    porep_seed (porep_config.porep_id)
  cache_path




JSON
  seed
  ticket
  cache_path
  
*/



//int main() {

template<class C>
int do_c1(SectorParameters& params, nvme_controllers_t* controllers,
          size_t qpair, int core_num,
          size_t block_offset, size_t num_sectors, size_t sector_slot,
          const uint8_t* replica_id, const uint8_t* seed,
          const uint8_t* ticket, const char* cache_path,
          const char* parents_filename, const char* output_dir) {
  streaming_node_reader_t<C> reader(controllers, qpair,
                                     block_offset, core_num);
  C1<C> c1(&params, reader, sector_slot);
  c1.ForceReplicaID((node_t*)replica_id); // TODO - remove
  // TODO - c1.CreateReplicaID(
  //node_t* CreateReplicaID(const uint8_t* prover_id, uint64_t sector_id,
  //                          const uint8_t* ticket, const uint8_t* comm_d,
  //                          const uint8_t* porep_seed);

  c1.DeriveChallenges(seed);
  c1.SetTreeRBufs(cache_path, "%s/sc-02-data-tree-r-last-s-%03ld-%ld.dat");
  c1.SetTreeCBufs(cache_path, "%s/sc-02-data-tree-c-s-%03ld-%ld.dat");
  c1.GetRoots(cache_path);
  c1.SetParentsBuf(parents_filename);

  const size_t MAX = 256;
  char fname[MAX];
  snprintf(fname, MAX, "%s/commit-phase1-output-%03ld", output_dir, sector_slot);
  c1.WriteProofs(fname);

  return 0;
}

template int do_c1<sealing_config128_t>(
          SectorParameters& params, nvme_controllers_t* controllers,
          size_t qpair, int core_num,
          size_t block_offset, size_t num_sectors, size_t sector_slot,
          const uint8_t* replica_id, const uint8_t* seed,
          const uint8_t* ticket, const char* cache_path,
          const char* parents_filename, const char* output_dir);
template int do_c1<sealing_config64_t>(
          SectorParameters& params, nvme_controllers_t* controllers,
          size_t qpair, int core_num,
          size_t block_offset, size_t num_sectors, size_t sector_slot,
          const uint8_t* replica_id, const uint8_t* seed,
          const uint8_t* ticket, const char* cache_path,
          const char* parents_filename, const char* output_dir);
template int do_c1<sealing_config32_t>(
          SectorParameters& params, nvme_controllers_t* controllers,
          size_t qpair, int core_num,
          size_t block_offset, size_t num_sectors, size_t sector_slot,
          const uint8_t* replica_id, const uint8_t* seed,
          const uint8_t* ticket, const char* cache_path,
          const char* parents_filename, const char* output_dir);
template int do_c1<sealing_config16_t>(
          SectorParameters& params, nvme_controllers_t* controllers,
          size_t qpair, int core_num,
          size_t block_offset, size_t num_sectors, size_t sector_slot,
          const uint8_t* replica_id, const uint8_t* seed,
          const uint8_t* ticket, const char* cache_path,
          const char* parents_filename, const char* output_dir);
template int do_c1<sealing_config8_t>(
          SectorParameters& params, nvme_controllers_t* controllers,
          size_t qpair, int core_num,
          size_t block_offset, size_t num_sectors, size_t sector_slot,
          const uint8_t* replica_id, const uint8_t* seed,
          const uint8_t* ticket, const char* cache_path,
          const char* parents_filename, const char* output_dir);
template int do_c1<sealing_config4_t>(
          SectorParameters& params, nvme_controllers_t* controllers,
          size_t qpair, int core_num,
          size_t block_offset, size_t num_sectors, size_t sector_slot,
          const uint8_t* replica_id, const uint8_t* seed,
          const uint8_t* ticket, const char* cache_path,
          const char* parents_filename, const char* output_dir);
template int do_c1<sealing_config2_t>(
          SectorParameters& params, nvme_controllers_t* controllers,
          size_t qpair, int core_num,
          size_t block_offset, size_t num_sectors, size_t sector_slot,
          const uint8_t* replica_id, const uint8_t* seed,
          const uint8_t* ticket, const char* cache_path,
          const char* parents_filename, const char* output_dir);
