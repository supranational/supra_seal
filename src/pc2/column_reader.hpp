// Copyright Supranational LLC

#ifndef __COLUMN_READER_HPP__
#define __COLUMN_READER_HPP__

template<class C> class streaming_node_reader_t;

template<class C>
class column_reader_t {
  SectorParameters& params;
  size_t batch_size;
  size_t num_batches;
  uint8_t* page_data;
  streaming_node_reader_t<C>* node_reader;
  
public:
  column_reader_t(SectorParameters& _params,
                  streaming_node_reader_t<C>* node_reader,
                  size_t batch_size, size_t num_batches);
  ~column_reader_t();

  uint8_t* get_buffer(size_t& bytes);
  uint8_t* get_buffer_id(size_t id);

  void* alloc_node_ios();
  void free_node_ios(void* node_ios);
  
  // Starting at 'node', read all columns of 'num_nodes' nodes
  uint8_t* read_columns(uint64_t node, size_t buffer_id,
                        atomic<uint64_t>* valid, size_t* valid_count,
                        void* node_ios);
};

#endif
