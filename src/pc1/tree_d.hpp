// Copyright Supranational LLC

#include <cassert>
#include <chrono>
#include <cmath>
#include <cstring>
#include <fcntl.h>
#include <iomanip>
#include <iostream>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../sealing/constants.hpp"
#include "../sealing/sector_parameters.hpp"
#include "../sha/sha_functions.hpp"

class TreeD {
 public:
  TreeD(SectorParameters* params, bool copy) : params_(params), copy_(copy) {}
  ~TreeD() {}

  void print_digest_hex(const node_t* node) {
    uint8_t* digest = (uint8_t*)node;
    for (int i = 0; i < 32; ++i) {
      std::cout << std::hex << std::setfill('0') << std::setw(2)
                << (uint32_t)digest[i];
    }
    std::cout << std::endl;
  }

  void HashNode(node_t* result, const node_t* input) {
    // Padding is fixed here, always hashing two 32B values
    static uint8_t padding_block[64] = {0};
    padding_block[0] = 0x80;
    padding_block[62] = 0x2; // 0x200 = 512 bits

    std::memcpy(result, SHA256_INITIAL_DIGEST, sizeof(node_t));
    blst_sha256_block((uint32_t*)result, input, 1);
    blst_sha256_block((uint32_t*)result, (node_t*)padding_block, 1);

    blst_sha256_emit((uint8_t*)result, (const uint32_t*)result);
    result->limbs[7] &= 0x3FFFFFFF;
  }

  void BuildCCTree(node_t* comm_d, std::string tree_d_filename) {
    size_t arity = params_->GetNumTreeDArity();
    size_t arity_lg = (size_t) log2(arity);

    // Open tree d
    int tree_d_file = open(tree_d_filename.c_str(), O_EXCL | O_CREAT | O_RDWR,
                           S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP);
    if (tree_d_file == -1) {
      std::cout << "Error opening " << tree_d_filename << std::endl;
      std::cout << "Make sure it is deleted first" << std::endl;
      exit(1);
    }

    size_t cur_nodes = params_->GetSectorSize() / sizeof(node_t);
    size_t tree_d_file_size = ((2 * cur_nodes) - 1) * sizeof(node_t);

    posix_fallocate(tree_d_file, 0, tree_d_file_size);

    node_t* tree_d = (node_t*)mmap(NULL, tree_d_file_size,
                                   PROT_WRITE, MAP_SHARED, tree_d_file, 0);

    node_t cc[params_->GetNumTreeDLevels() + 1] = {0};
    node_t buf[2] = {0};

    for (size_t i = 1; i <= params_->GetNumTreeDLevels(); ++i) {
      HashNode(&(cc[i]), &(buf[0]));
      std::memcpy(&(buf[0]), &(cc[i]), sizeof(node_t));
      std::memcpy(&(buf[1]), &(cc[i]), sizeof(node_t));
    }

    node_t* tree_ptr = tree_d;
    size_t cur_level = 0;

    while (cur_nodes > 0) {
      for (size_t i = 0; i < cur_nodes; ++i) {
        std::memcpy(tree_ptr, &(cc[cur_level]), sizeof(node_t));
        tree_ptr++;
      }
      cur_nodes >>= arity_lg;
      cur_level++;
    }

    std::memcpy(comm_d, &(cc[params_->GetNumTreeDLevels()]), sizeof(node_t));

    munmap(tree_d, tree_d_file_size);
    close(tree_d_file);
  }

  void BuildTree(node_t* comm_d,
                 std::string tree_d_filename,
                 std::string data_filename) {
    size_t arity = params_->GetNumTreeDArity();
    size_t arity_lg = (size_t) log2(arity);

    // Open Data File
    int data_fd = open(data_filename.c_str(), O_RDONLY);
    assert (data_fd != -1);
    struct stat buf;
    fstat(data_fd, &buf);
    size_t data_buf_size = buf.st_size;
    node_t* data = (node_t*)mmap(NULL, data_buf_size, PROT_READ,
                                 MAP_PRIVATE, data_fd, 0);
    if (data == MAP_FAILED) {
      perror("mmap failed for data file");
      exit(1);
    }
    close(data_fd);

    // Open tree d
    int tree_d_file = open(tree_d_filename.c_str(), O_EXCL | O_CREAT | O_RDWR,
                           S_IRUSR | S_IWUSR | S_IRGRP | S_IWGRP);
    if (tree_d_file == -1) {
      std::cout << "Error opening " << tree_d_filename << std::endl;
      std::cout << "Make sure it is deleted first" << std::endl;
      exit(1);
    }

    size_t cur_nodes = params_->GetSectorSize() / sizeof(node_t);
    size_t tree_d_file_size = (cur_nodes - 1) * sizeof(node_t);

    if (copy_) {
      tree_d_file_size += params_->GetSectorSize();
    }

    posix_fallocate(tree_d_file, 0, tree_d_file_size);

    node_t* tree_d = (node_t*)mmap(NULL, tree_d_file_size,
                                   PROT_WRITE, MAP_SHARED, tree_d_file, 0);

    node_t* tree_ptr = tree_d;
    node_t* in_ptr   = data;

    // Copy all the data file data into tree_d if asked to
    // Adjust pointers
    if (copy_) {
      std::memcpy(tree_d, data, params_->GetSectorSize());
      munmap(data, data_buf_size);
      tree_ptr = tree_d + cur_nodes;
      in_ptr   = tree_d;
    }

    while (cur_nodes > 1) {
      node_t* start_tree_ptr = tree_ptr;
      for (size_t in_idx = 0; in_idx < cur_nodes; in_idx += arity) {
        HashNode(tree_ptr, &(in_ptr[in_idx]));
        tree_ptr++;
      }
      cur_nodes >>= arity_lg;
      in_ptr      = start_tree_ptr;
    }

    std::memcpy(comm_d, in_ptr, sizeof(node_t));

    if (!copy_) {
      munmap(data, data_buf_size);
    }
    munmap(tree_d, tree_d_file_size);
    close(tree_d_file);
  }

 private:
  SectorParameters* params_;
  bool              copy_;
};
