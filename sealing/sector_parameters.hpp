// Copyright Supranational LLC

// Runtime sector parameters
// Mostly derived from filecoin-proofs/src/constants.rs

#ifndef __SECTOR_PARAMETERS_HPP__
#define __SECTOR_PARAMETERS_HPP__

#include <string>
#include <iostream>
#include "constants.hpp"

class SectorParameters {
 public:
  SectorParameters(size_t sector_size);
  SectorParameters(const std::string sector_size);
  ~SectorParameters() {};

  static constexpr size_t ONE_KB = 1024;
  static constexpr size_t ONE_MB = ONE_KB * 1024;
  static constexpr size_t ONE_GB = ONE_MB * 1024;

  size_t GetSectorSize()           { return sector_size_; }
  size_t GetNumChallenges()        { return num_challenges_; }
  size_t GetNumPartitions()        { return num_partitions_; }
  size_t GetNumLayers()            { return num_layers_; }
  size_t GetNumNodes()             { return num_leaves_; }
  size_t GetNumLeaves()            { return num_leaves_; }
  size_t GetNumTreeDArity()        { return tree_d_arity_; }
  size_t GetNumTreeDLevels()       { return tree_d_levels_; }
  size_t GetNumTreeRLabels()       { return tree_r_labels_; }
  size_t GetChallengeStartMask()   { return ~(tree_r_labels_ - 1); }
  size_t GetNumTreeRCFiles()       { return tree_rc_files_; }
  size_t GetNumTreeRCArity()       { return tree_rc_base_arity_; }
  size_t GetNumTreeRCArityDT()     { return tree_rc_base_arity_ + 1; }
  size_t GetNumTreeRCLevels()      { return tree_rc_levels_; }
  size_t GetNumTreeRCConfig()      { return tree_rc_config_; }
  size_t GetNumTreeRDiscardRows()  { return tree_r_discard_rows_; }

 private:
  void SetParams(size_t sector_size);

  size_t sector_size_;
  size_t num_challenges_;
  size_t num_partitions_;
  size_t num_layers_;
  size_t num_leaves_;
  size_t tree_d_arity_;
  size_t tree_d_levels_;

  // Config is used to set proof type
  // storage-proofs-core/src/merkle/proof.rs
  size_t tree_rc_config_;     

  size_t tree_rc_base_arity_;
  size_t tree_rc_sub_arity_;
  size_t tree_rc_top_arity_;
  size_t tree_rc_levels_;
  size_t tree_r_discard_rows_;
  size_t tree_rc_files_;
  size_t tree_r_labels_;
};

#endif // __SECTOR_PARAMETERS_HPP__
