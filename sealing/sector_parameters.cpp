// Copyright Supranational LLC

#include <assert.h>
#include "sector_parameters.hpp"

void  SectorParameters::SetParams(size_t sector_size) {
  sector_size_ = sector_size;

  // NODE_COUNT
  num_leaves_ = sector_size / sizeof(node_t);

  switch (sector_size) {
    case (2   * ONE_KB):
    case (8   * ONE_MB):
    case (512 * ONE_MB):
      tree_rc_config_     = 0;
      tree_rc_sub_arity_  = 0;
      tree_rc_top_arity_  = 0;
      break;
    case (4   * ONE_KB):
    case (16  * ONE_MB):
    case (1   * ONE_GB):
      tree_rc_config_     = 1;
      tree_rc_sub_arity_  = 2;
      tree_rc_top_arity_  = 0;
      break;
    case (16  * ONE_KB):
    case (32  * ONE_GB):
      tree_rc_config_     = 1;
      tree_rc_sub_arity_  = 8;
      tree_rc_top_arity_  = 0;
      break;
    case (32  * ONE_KB):
    case (64  * ONE_GB):
      tree_rc_config_     = 2;
      tree_rc_sub_arity_  = 8;
      tree_rc_top_arity_  = 2;
      break;
    default:
      std::cout << "Invalid sector size" << std::endl;
      exit(1);
  }

  tree_rc_base_arity_ = 8;
  tree_d_arity_       = 2;

  if (sector_size <= ONE_GB) {
    num_challenges_ = 2;
    num_partitions_ = 1;
    num_layers_     = 2;
  } else {
    num_challenges_ = 180;
    num_partitions_ = 10;
    num_layers_     = 11;
  }

  if (sector_size == (2 * ONE_KB)) {
    tree_r_discard_rows_ = 1;
  } else {
    tree_r_discard_rows_ = 2;
  } 

  // get_base_tree_count()
  if ((tree_rc_top_arity_ == 0) && (tree_rc_sub_arity_ == 0)) {
    tree_rc_files_ = 1;
  } else if (tree_rc_top_arity_ > 0) {
    tree_rc_files_ = tree_rc_top_arity_ * tree_rc_sub_arity_;
  } else {
    tree_rc_files_ = tree_rc_sub_arity_;
  }

  tree_r_labels_ = pow(tree_rc_base_arity_, tree_r_discard_rows_ + 1);

  // FIXME - this won't work for non-uniform trees
  tree_rc_levels_ = log2(num_leaves_) / log2(tree_rc_base_arity_);
  assert(tree_rc_top_arity_ == 0);
  assert(tree_rc_sub_arity_ != 2);

  tree_d_levels_  = log2(num_leaves_);
}

SectorParameters::SectorParameters(size_t sector_size) {
  SetParams(sector_size);
}

SectorParameters::SectorParameters(const std::string sector_size) {
  if (sector_size ==   "2KiB") SetParams(2   * ONE_KB);
  if (sector_size ==   "4KiB") SetParams(4   * ONE_KB);
  if (sector_size ==  "16KiB") SetParams(16  * ONE_KB);
  if (sector_size ==  "32KiB") SetParams(32  * ONE_KB);

  if (sector_size ==   "8MiB") SetParams(8   * ONE_MB);
  if (sector_size ==  "16MiB") SetParams(16  * ONE_MB);
  if (sector_size == "512MiB") SetParams(512 * ONE_MB);

  if (sector_size ==   "1GiB") SetParams(1   * ONE_GB);
  if (sector_size ==  "32GiB") SetParams(32  * ONE_GB);
  if (sector_size ==  "64GiB") SetParams(64  * ONE_GB);
}
