// Copyright Supranational LLC

#ifndef __C1CHALLENGE_HPP__
#define __C1CHALLENGE_HPP__

#include "../pc2/streaming_node_reader.hpp"

template<class C>
class C1Challenge {
 public:
  C1Challenge(uint64_t challenge, SectorParameters* params,
              node_t* tree_r_root_, node_t* tree_c_root_);
  ~C1Challenge();

  void GetParents(const uint32_t* parents_buf);
  void GetNodes(streaming_node_reader_t<C>& reader, size_t sector_slot);
  size_t WriteProof(uint8_t* file_ptr, size_t buf_index,
                    node_t** tree_r_bufs, node_t** tree_c_bufs);

 private:
  uint64_t          challenge_;
  SectorParameters* params_;
  uint32_t          drg_parents_[PARENT_COUNT_BASE];
  uint32_t          exp_parents_[PARENT_COUNT_EXP];
  node_t*           nodes_;        // This node and its parents for each layer
  node_t*           tree_r_nodes_; // Replica nodes to rebuild discarded rows 
  node_t*           tree_r_root_;
  node_t*           tree_c_root_;
};

template<class C>
C1Challenge<C>::C1Challenge(uint64_t challenge, SectorParameters* params,
                            node_t* tree_r_root, node_t* tree_c_root) :
  challenge_(challenge),
  params_(params),
  tree_r_root_(tree_r_root),
  tree_c_root_(tree_c_root) { 

  nodes_        = new node_t[params->GetNumLayers() * (PARENT_COUNT + 1)];
  tree_r_nodes_ = new node_t[params->GetNumTreeRLabels()];
}

template<class C>
C1Challenge<C>::~C1Challenge() {
  if (nodes_        != nullptr) delete nodes_;
  if (tree_r_nodes_ != nullptr) delete tree_r_nodes_;
}

template<class C>
void C1Challenge<C>::GetParents(const uint32_t* parents_buf) {
  size_t p_idx = challenge_ * PARENT_COUNT;
  for (size_t k = 0; k < PARENT_COUNT_BASE; ++k) {
    drg_parents_[k] = parents_buf[p_idx];
    p_idx++;
  }
  for (size_t k = 0; k < PARENT_COUNT_EXP; ++k) {
    exp_parents_[k] = parents_buf[p_idx];
    p_idx++;
  }
}

template<class C>
void C1Challenge<C>::GetNodes(streaming_node_reader_t<C>& reader, size_t sector_slot) {
  vector<node_id_t> nodes;
  vector<node_id_t> tree_r_nodes;
    
  size_t layer_count = params_->GetNumLayers();
  for (size_t l = 0; l < layer_count; ++l) {
    nodes.push_back(node_id_t(l, challenge_));

    // Get all base parents
    for (size_t k = 0; k < PARENT_COUNT_BASE; ++k) {
      nodes.push_back(node_id_t(l, drg_parents_[k]));
    }

    // Get all exp parents
    for (size_t k = 0; k < PARENT_COUNT_EXP; ++k) {
      nodes.push_back(node_id_t(l, exp_parents_[k]));
    }

    // Final layer, get adjacent nodes for tree r calculation
    if (l == (layer_count - 1)) {
      size_t tree_r_label_idx  = challenge_ & params_->GetChallengeStartMask();
      for (size_t k = 0; k < params_->GetNumTreeRLabels(); ++k) {
        tree_r_nodes.push_back(node_id_t(l, tree_r_label_idx));
        tree_r_label_idx++;
      }
    }
  }
  spdk_ptr_t<page_t<C>> pages(max(nodes.size(), tree_r_nodes.size()));
  reader.load_nodes(&pages[0], nodes);
  for (size_t i = 0; i < nodes.size(); i++) {
    node_t n = pages[i].
      parallel_nodes[nodes[i].node() % C::NODES_PER_PAGE]
      .sectors[sector_slot];
    n.reverse_l();
    nodes_[i] = n;
  }
  reader.load_nodes(&pages[0], tree_r_nodes);
  for (size_t i = 0; i < tree_r_nodes.size(); i++) {
    node_t n = pages[i].
      parallel_nodes[tree_r_nodes[i].node() % C::NODES_PER_PAGE]
      .sectors[sector_slot];
    n.reverse_l();
    tree_r_nodes_[i] = n;
  }
}

template<class C>
size_t C1Challenge<C>::WriteProof(uint8_t* file_ptr, size_t buf_index,
                               node_t** tree_r_bufs, node_t** tree_c_bufs) {
  ///////////////////////////////////////
  // Build Tree D inclusion proof
  ///////////////////////////////////////
  TreeDCCProof tree_d(params_->GetNumTreeDArity(),
                      params_->GetNumTreeDLevels(), nullptr, 0, 0);
  tree_d.GenInclusionPath(challenge_, (node_t*) CC_TREE_D_NODE_VALUES); 
  buf_index = tree_d.WriteProof(file_ptr, buf_index, SINGLE_PROOF_DATA);

  ///////////////////////////////////////
  // Build Tree R inclusion proof
  ///////////////////////////////////////
  TreeProof tree_r(params_->GetNumTreeRCArity(),
                   params_->GetNumTreeRCLevels(), tree_r_bufs,
                   params_->GetNumTreeRCFiles(),
                   params_->GetNumTreeRDiscardRows());
  tree_r.SetRoot(tree_r_root_);
  tree_r.GenInclusionPath(challenge_, tree_r_nodes_);
  buf_index = tree_r.WriteProof(file_ptr, buf_index,
                                params_->GetNumTreeRCConfig());

  ///////////////////////////////////////
  // Column proofs
  ///////////////////////////////////////
  ColumnProof c_x = ColumnProof(challenge_, params_,
                                nodes_, 0, (PARENT_COUNT + 1),
                                tree_c_bufs, tree_c_root_);
  buf_index = c_x.WriteProof(file_ptr, buf_index,
                             params_->GetNumTreeRCConfig());

  ///////////////////////////////////////
  // DRG Parents
  ///////////////////////////////////////
  std::memcpy(file_ptr + buf_index, &PARENT_COUNT_BASE, sizeof(uint64_t));
  buf_index += sizeof(uint64_t);

  for (size_t k = 0; k < PARENT_COUNT_BASE; ++k) {
    ColumnProof drg = ColumnProof(drg_parents_[k], params_,
                                  nodes_, k + 1, (PARENT_COUNT + 1),
                                  tree_c_bufs, tree_c_root_);
    buf_index = drg.WriteProof(file_ptr, buf_index,
                               params_->GetNumTreeRCConfig());
  }

  ///////////////////////////////////////
  // Expander Parents
  ///////////////////////////////////////
  std::memcpy(file_ptr + buf_index, &PARENT_COUNT_EXP, sizeof(uint64_t));
  buf_index += sizeof(uint64_t);

  for (size_t k = 0; k < PARENT_COUNT_EXP; ++k) {
    ColumnProof exp = ColumnProof(exp_parents_[k], params_, nodes_,
                                  k + 1 + PARENT_COUNT_BASE,
                                  (PARENT_COUNT + 1),
                                  tree_c_bufs, tree_c_root_);
    buf_index = exp.WriteProof(file_ptr, buf_index,
                               params_->GetNumTreeRCConfig());
  }

  ///////////////////////////////////////
  // Labeling Proofs
  ///////////////////////////////////////
  size_t layer_count = params_->GetNumLayers();
  LabelProof label_proof(challenge_, layer_count, nodes_, (PARENT_COUNT + 1));
  buf_index = label_proof.WriteProof(file_ptr, buf_index);

  ///////////////////////////////////////
  // Encoding Proof
  ///////////////////////////////////////
  LabelProof enc_proof(challenge_, layer_count, nodes_, (PARENT_COUNT + 1));
  buf_index = enc_proof.WriteProof(file_ptr, buf_index, true);

  return buf_index;
}
#endif // __C1CHALLENGE_HPP__
