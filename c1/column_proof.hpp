// Copyright Supranational LLC
    
#ifndef __COLUMN_PROOF_HPP__
#define __COLUMN_PROOF_HPP__ 

class ColumnProof {
 public:
  ColumnProof(uint64_t challenge, SectorParameters* params,
              node_t* labels, size_t label_idx, size_t label_inc,
              node_t** tree_bufs, node_t* root);
  ~ColumnProof();

  size_t WriteProof(uint8_t* file_ptr, size_t buf_index, uint32_t proof_type);
  static size_t ProofSize(SectorParameters* params);

 private:
  SectorParameters* params_;
  uint64_t          challenge_;
  uint64_t          layers_;
  node_t*         labels_;
  size_t            label_idx_;
  size_t            label_inc_;
  TreeProof*        tree_;
};

ColumnProof::ColumnProof(uint64_t challenge, SectorParameters* params,
                         node_t* labels, size_t label_idx, size_t label_inc,
                         node_t** tree_bufs, node_t* root) :
  params_(params),
  challenge_(challenge),
  layers_(params->GetNumLayers()),
  labels_(labels),
  label_idx_(label_idx),
  label_inc_(label_inc)
{
  tree_ = new TreeProof(params->GetNumTreeRCArity(),
                        params->GetNumTreeRCLevels(),
                        tree_bufs, params->GetNumTreeRCFiles());
  tree_->SetRoot(root);
  tree_->GenInclusionPath(challenge, nullptr);
}

ColumnProof::~ColumnProof() {
  if (tree_ != nullptr) {
    delete tree_;
  }
}

size_t ColumnProof::ProofSize(SectorParameters* params) {
  size_t proof_size = 4;
  proof_size += 8;
  proof_size += (sizeof(node_t) * params->GetNumLayers());
  proof_size += TreeProof::ProofSize(params->GetNumTreeRCArity(),
                                     params->GetNumTreeRCLevels(),
                                     params->GetNumTreeRCConfig());
  return proof_size;
}

size_t ColumnProof::WriteProof(uint8_t* file_ptr, size_t buf_index,
                               uint32_t proof_type) {
  std::memcpy(file_ptr + buf_index, (uint32_t*)&challenge_, sizeof(uint32_t));
  buf_index += sizeof(uint32_t);

  std::memcpy(file_ptr + buf_index, &layers_, sizeof(uint64_t));
  buf_index += sizeof(uint64_t);

  for (uint64_t l = 0; l < layers_; ++l) {
    std::memcpy(file_ptr + buf_index, labels_ + label_idx_ + (l * label_inc_),
                sizeof(node_t));
    buf_index += sizeof(node_t);
  }

  buf_index = tree_->WriteProof(file_ptr, buf_index, proof_type);

  return buf_index;
}

#endif // __COLUMN_PROOF_HPP__
