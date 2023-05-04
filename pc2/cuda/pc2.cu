// Copyright Supranational LLC

#include "../../poseidon/cuda/poseidon.cu"
#include "../../util/debug_helpers.hpp"
#include "host_ptr_t.hpp"

#ifndef __CUDA_ARCH__

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/mman.h>

#include <filesystem>
#include <chrono>
#include "../planner.cpp"
#include "pc2.cuh"
#include "cuda_lambda_t.hpp"
#include "../../util/util.hpp"

template<class C>
pc2_t<C>::pc2_t(SectorParameters& _params, topology_t& _topology,
                bool _tree_r_only, streaming_node_reader_t<C>& _reader,
                size_t _nodes_to_read, size_t _batch_size,
                size_t _stream_count,
                const char** _data_filenames, const char* _output_dir) :
  params(_params),
  topology(_topology),
  tree_r_only(_tree_r_only),
  reader(_reader),
  nodes_to_read(_nodes_to_read),
  batch_size(_batch_size),
  tree_c_address(params.GetNumNodes() / params.GetNumTreeRCFiles(),
                 TREE_ARITY, NODE_SIZE, 0),
  tree_r_address(params.GetNumNodes() / params.GetNumTreeRCFiles(),
                 TREE_ARITY, NODE_SIZE, params.GetNumTreeRDiscardRows() + 1),
  stream_count(_stream_count),
  tree_c_partition_roots(C::PARALLEL_SECTORS * TREE_ARITY),
  tree_r_partition_roots(C::PARALLEL_SECTORS * TREE_ARITY),
  gpu_results_c(tree_r_only ? 0 :_batch_size * C::PARALLEL_SECTORS / TREE_ARITY * stream_count),
  gpu_results_r(_batch_size * C::PARALLEL_SECTORS / TREE_ARITY * stream_count),
  host_buf_storage(num_host_bufs * batch_size * C::PARALLEL_SECTORS * 2),
  data_filenames(_data_filenames),
  output_dir(_output_dir)
{
  assert (TREE_ARITY == params.GetNumTreeRCArity());
  assert (nodes_to_read % stream_count == 0);

  // Put layer11 / sealed file in a replicas directory if it exists
  std::string pc2_replica_output_dir = output_dir;
  pc2_replica_output_dir += "/replicas";
  if (!std::filesystem::exists(pc2_replica_output_dir.c_str())) {
    pc2_replica_output_dir = output_dir;
  }

  
  if (C::PARALLEL_SECTORS == 1) {
    p_aux_template = "%s/p_aux";
  } else {
    p_aux_template = "%s/%03ld/p_aux";
  }
  // Open all tree-c and tree-r files
  const char* tree_c_filename_template;
  const char* tree_r_filename_template;
  if (C::PARALLEL_SECTORS == 1) {
    if (params.GetNumTreeRCFiles() > 1) {
      tree_c_filename_template = "%s/sc-02-data-tree-c-%ld.dat";
      tree_r_filename_template = "%s/sc-02-data-tree-r-last-%ld.dat";
    } else {
      tree_c_filename_template = "%s/sc-02-data-tree-c.dat";
      tree_r_filename_template = "%s/sc-02-data-tree-r-last.dat";
    }
  } else {
    if (params.GetNumTreeRCFiles() > 1) {
      tree_c_filename_template = "%s/%03ld/sc-02-data-tree-c-%ld.dat";
      tree_r_filename_template = "%s/%03ld/sc-02-data-tree-r-last-%ld.dat";
    } else {
      tree_c_filename_template = "%s/%03ld/sc-02-data-tree-c.dat";
      tree_r_filename_template = "%s/%03ld/sc-02-data-tree-r-last.dat";
    }
  }
  // And sealed files
  const char* sealed_filename_template = "%s/%03ld/sealed-file";
  const char* layer11_filename_template = "%s/%03ld/layer11-file";

  if (!std::filesystem::exists(output_dir)) {
    std::filesystem::create_directory(output_dir);
  }
  has_cc_sectors = false;
  has_non_cc_sectors = false;
  
  const size_t MAX = 256;
  char fname[MAX];
  for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
    // Create sector subdirs
    if (C::PARALLEL_SECTORS == 1) {
      snprintf(fname, MAX, "%s", output_dir);
    } else {
      snprintf(fname, MAX, "%s/%03ld", output_dir, i);
    }
    if (!std::filesystem::exists(fname)) {
      std::filesystem::create_directory(fname);
    }
    if (!tree_r_only) {
      if (C::PARALLEL_SECTORS == 1) {
        snprintf(fname, MAX, "%s", pc2_replica_output_dir.c_str());
      } else {
        snprintf(fname, MAX, "%s/%03ld", pc2_replica_output_dir.c_str(), i);
      }
      if (!std::filesystem::exists(fname)) {
        std::filesystem::create_directory(fname);
      }
    }

    if (!tree_r_only) {
      tree_c_files[i].resize(params.GetNumTreeRCFiles());
    }
    tree_r_files[i].resize(params.GetNumTreeRCFiles());
    for (size_t j = 0; j < params.GetNumTreeRCFiles(); j++) {
      // tree-c
      if (!tree_r_only) {
        if (C::PARALLEL_SECTORS == 1) {
          if (params.GetNumTreeRCFiles() > 1) {
            snprintf(fname, MAX, tree_c_filename_template, output_dir, j);
          } else {
            snprintf(fname, MAX, tree_c_filename_template, output_dir);
          }
        } else {
          if (params.GetNumTreeRCFiles() > 1) {
            snprintf(fname, MAX, tree_c_filename_template, output_dir, i, j);
          } else {
            snprintf(fname, MAX, tree_c_filename_template, output_dir, i);
          }
        }
        assert(tree_c_files[i][j].mmap_write(fname, tree_c_address.data_size(), true) == 0);
        tree_c_files[i][j].advise_random();
      }
                            
      // tree-r
      if (C::PARALLEL_SECTORS == 1) {
        if (params.GetNumTreeRCFiles() > 1) {
          snprintf(fname, MAX, tree_r_filename_template, output_dir, j);
        } else {
          snprintf(fname, MAX, tree_r_filename_template, output_dir);
        }
      } else {
        if (params.GetNumTreeRCFiles() > 1) {
          snprintf(fname, MAX, tree_r_filename_template, output_dir, i, j);
        } else {
          snprintf(fname, MAX, tree_r_filename_template, output_dir, i);
        }
      }
      assert(tree_r_files[i][j].mmap_write(fname, tree_r_address.data_size(), true) == 0);
      tree_r_files[i][j].advise_random();
    }

    // Data files for encoding
    if (!tree_r_only) {
      if (data_filenames != nullptr && data_filenames[i] != nullptr) {
        data_files[i].mmap_read(data_filenames[i], SECTOR_SIZE);
        // If there is a data file present we will encode layer 11 and write the
        // sealed data
        snprintf(fname, MAX, sealed_filename_template, pc2_replica_output_dir.c_str(), i);
        assert(sealed_files[i].mmap_write(fname, SECTOR_SIZE, true) == 0);
        has_non_cc_sectors = true;
      } else {
        // Write the raw layer 11 data
        // TODO: no way to differentiate cc vs remote data
        //snprintf(fname, MAX, layer11_filename_template, pc2_replica_output_dir.c_str(), i);
        snprintf(fname, MAX, sealed_filename_template, pc2_replica_output_dir.c_str(), i);
        assert(sealed_files[i].mmap_write(fname, SECTOR_SIZE, true) == 0);
        has_cc_sectors = true;
      }
    }
  }
  
  // Compute the final offset in the file for GPU data
  tree_address_t final_tree(batch_size, TREE_ARITY, sizeof(fr_t), 0);
  final_gpu_offset_c = tree_c_address.data_size() - final_tree.data_size();
  final_gpu_offset_r = tree_r_address.data_size() - final_tree.data_size();

  // Compute an offset table used for multiple partitions
  size_t nodes_per_stream = nodes_to_read / stream_count;
  size_t layer_offset = nodes_per_stream;
  while (layer_offset >= TREE_ARITY) {
    layer_offsets_c.push_back(layer_offset);
    layer_offset /= TREE_ARITY;
  }

  layer_offset = nodes_per_stream;
  for (size_t i = 0; i < params.GetNumTreeRDiscardRows() + 1; i++) {
    layer_offset /= TREE_ARITY;
  }
  while (layer_offset >= TREE_ARITY) {
    layer_offsets_r.push_back(layer_offset);
    layer_offset /= TREE_ARITY;
  }

  // Create GPU poseidon hashers and streams
  size_t resource_id = 0;
  for (size_t i = 0; i < ngpus(); i++) {
    auto& gpu = select_gpu(i);
    if (!tree_r_only) {
      poseidon_columns.push_back(new PoseidonCuda<COL_ARITY_DT>(gpu));
    }
    poseidon_trees.push_back(new PoseidonCuda<TREE_ARITY_DT>(gpu));
      
    for (size_t j = 0; j < stream_count / ngpus(); j++) {
      resources.push_back(new gpu_resource_t<C>(params,resource_id, gpu,
                                                nodes_per_stream, batch_size));
      resource_id++;
    }
  }

  // Register the page buffer with the CUDA driver
  size_t page_buffer_size = 0;
  page_buffer = reader.get_full_buffer(page_buffer_size);
  cudaHostRegister(page_buffer, page_buffer_size, cudaHostRegisterDefault);

  // Set up host side buffers for returning data
  host_bufs0.resize(num_host_bufs);
  host_buf_pool0.create(num_host_bufs);
  host_buf_to_disk0.create(num_host_bufs);

  if (!tree_r_only) {
    host_bufs1.resize(num_host_bufs);
    host_buf_pool1.create(num_host_bufs);
    host_buf_to_disk1.create(num_host_bufs);
  }
  for (size_t i = 0; i < num_host_bufs; i++) {
    host_bufs0[i].data = &host_buf_storage[i * batch_size * C::PARALLEL_SECTORS];
    host_buf_pool0.enqueue(&host_bufs0[i]);
    
    if (!tree_r_only) {
      host_bufs1[i].data = &host_buf_storage[num_host_bufs * batch_size * C::PARALLEL_SECTORS +
                                             i * batch_size * C::PARALLEL_SECTORS];
      host_buf_pool1.enqueue(&host_bufs1[i]);
    }
  }
}

template<class C>
pc2_t<C>::~pc2_t() {
  while (resources.size() > 0) {
    gpu_resource_t<C>* r = resources.back();
    select_gpu(r->gpu);
      
    delete r;
    resources.pop_back();
  }
  for (size_t i = 0; i < ngpus(); i++) {
    if (!tree_r_only) {
      delete poseidon_columns[i];
    }
    delete poseidon_trees[i];
  }
  cudaHostUnregister(page_buffer);
}

template<class C>
void pc2_t<C>::hash() {
  auto start = std::chrono::high_resolution_clock::now();
  for (size_t partition = 0; partition < params.GetNumTreeRCFiles(); partition++) {
    auto pstart_gpu = std::chrono::high_resolution_clock::now();
    hash_gpu(partition);
    auto pstop_gpu = std::chrono::high_resolution_clock::now();
    if (!tree_r_only) {
      hash_cpu(&tree_c_partition_roots[partition * C::PARALLEL_SECTORS],
               partition, &(gpu_results_c[0]), tree_c_files, final_gpu_offset_c);
    }
    hash_cpu(&tree_r_partition_roots[partition * C::PARALLEL_SECTORS],
             partition, &(gpu_results_r[0]), tree_r_files, final_gpu_offset_r);
    auto pstop_cpu = std::chrono::high_resolution_clock::now();
    uint64_t secs_gpu = std::chrono::duration_cast<
      std::chrono::seconds>(pstop_gpu - pstart_gpu).count();
    uint64_t secs_cpu = std::chrono::duration_cast<
      std::chrono::seconds>(pstop_cpu - pstop_gpu).count();
    printf("Partition %ld took %ld seconds (gpu %ld, cpu %ld)\n",
           partition, secs_gpu + secs_cpu, secs_gpu, secs_cpu);
  }
  write_roots(&tree_c_partition_roots[0], &tree_r_partition_roots[0]);
  auto stop = std::chrono::high_resolution_clock::now();
  uint64_t secs = std::chrono::duration_cast<
    std::chrono::seconds>(stop - start).count();

  size_t total_page_reads = nodes_to_read * params.GetNumTreeRCFiles() /
    C::NODES_PER_PAGE * params.GetNumLayers();
  printf("pc2 took %ld seconds utilizing %0.1lf iOPS\n",
         secs, (double)total_page_reads / (double)secs);
}

template<class C>
void pc2_t<C>::process_writes(int core,
                              mt_fifo_t<buf_to_disk_t<C>>& to_disk_fifo,
                              mt_fifo_t<buf_to_disk_t<C>>& pool,
                              std::atomic<bool>& terminate,
                              std::atomic<int>& disk_writer_done) {
  set_core_affinity(core);
  
  while(!terminate || to_disk_fifo.size() > 0) {
    if (pool.is_full()) {
      continue;
    }

    buf_to_disk_t<C>* to_disk = to_disk_fifo.dequeue();
    if (to_disk != nullptr) {
#ifndef DISABLE_FILE_WRITES
      if (to_disk->stride == 1) {
        // Copy chunks of contiguous data
        for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
          if (to_disk->src[i] != nullptr) {
            memcpy(to_disk->dst[i], to_disk->src[i], to_disk->size * sizeof(fr_t));
          }
        }
      } else {
        //  Copy strided src data
        for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
          if (to_disk->src[i] != nullptr) {
            for (size_t j = 0; j < to_disk->size; j++) {
              fr_t elmt = to_disk->src[i][j * to_disk->stride];
              if (to_disk->reverse) {
                node_t* n = (node_t*)&elmt;
                n->reverse_l();
              }
              to_disk->dst[i][j] = elmt;
            }
          }
        }
      }
#endif
      pool.enqueue(to_disk);
    }
  }
  disk_writer_done++;
}

template<class C>
void pc2_t<C>::hash_gpu(size_t partition) {
  assert (stream_count % ngpus() == 0);

  nodes_per_stream = nodes_to_read / stream_count;

  thread_pool_t pool(2);

  for (size_t i = 0; i < resources.size(); i++) {
    resources[i]->reset();
  }
  
  // Start a thread to process writes to disk
  std::atomic<bool> terminate = false;
  std::atomic<int> disk_writer_done(0);
  // tree-c and tree-r
  pool.spawn([this, &terminate, &disk_writer_done]() {
    process_writes(this->topology.pc2_writer0,
                   host_buf_to_disk0, host_buf_pool0,
                   terminate, disk_writer_done);
  });
  // last layer / sealed file
  if (!tree_r_only) {
    pool.spawn([this, &terminate, &disk_writer_done]() {
      process_writes(this->topology.pc2_writer1,
                     host_buf_to_disk1, host_buf_pool1,
                     terminate, disk_writer_done);
    });
  }
  
  bool all_done = false;
  cuda_lambda_t cuda_notify(1);
  in_ptrs_d<TREE_ARITY> in_d;
  buf_to_disk_t<C>* to_disk = nullptr;
  buf_to_disk_t<C>* to_disk_r = nullptr;
  fr_t* fr = nullptr;
  size_t disk_bufs_needed = 0;
  
  while (!all_done) {
    all_done = true;
    for (size_t resource_num = 0; resource_num < resources.size(); resource_num++) {
      gpu_resource_t<C>& resource = *resources[resource_num];
      select_gpu(resource.gpu);
      int gpu_id = resource.gpu.id();

      if (resource.state != ResourceState::DONE) {
        all_done = false;
      }

      fr_t* out_c_d = nullptr;
      fr_t* out_r_d = nullptr;
      size_t layer_offset;
      node_id_t addr;
      size_t offset_c;
      size_t offset_r;
      bool write_tree_r;

      // Device storage for the hash result
      if (resource.work_c.buf != nullptr) {
        out_c_d = &(*resource.work_c.buf)[0];
        out_r_d = &(*resource.work_r.buf)[0];
      }

      switch (resource.state) {
      case ResourceState::DONE:
        // Nothing
        break;
        
      case ResourceState::IDLE:
        // Initiate data read
        resource.last = !resource.scheduler_c.next([](work_item_t<gpu_buffer_t>& w) {},
                                                   &resource.work_c);
        resource.scheduler_r.next([](work_item_t<gpu_buffer_t>& w) {},
                                  &resource.work_r);
        if (resource.work_c.is_leaf) {
#ifdef DISABLE_FILE_READS
          resource.state = ResourceState::HASH_COLUMN;
#else
          resource.state = ResourceState::DATA_READ;
#endif
        } else {
          resource.state = ResourceState::HASH_LEAF;
        }
        break;

      case ResourceState::DATA_READ:
        // Initiate the next data read
        resource.start_node = (// Perform batch_size nodes in parallel
                               (uint64_t)resource.work_c.idx.node() * batch_size +
                               // Each resource (GPU stream) works on a differet nodes_per_stream chunk
                               nodes_per_stream * resource.id +
                               // Each partition is size nodes_to_read
                               partition * nodes_to_read);
        resource.column_data = (fr_t*)reader.load_layers
          (resource.id,
           tree_r_only ? params.GetNumLayers() - 1 : 0, // start layer
           resource.start_node, batch_size,
           tree_r_only ? 1 : params.GetNumLayers(), // num_layers
           &resource.valid, &resource.valid_count);
        resource.state = ResourceState::DATA_WAIT;
        break;

      case ResourceState::DATA_WAIT:
        if (resource.valid.load() == resource.valid_count) {
          if (!tree_r_only) {
            // Prepare to Write layer 11 / sealed data to disk          
            if (host_buf_to_disk1.is_full()) {
              break;
            }
            to_disk = host_buf_pool1.dequeue();
            if (to_disk == nullptr) {
              break;
            }
          }
          fr_t* encode_buf = &resource.replica_data[0];
          
          // Copy layer 11 data to to_disk buffer for encoding/writing
          // If only building tree-r then only the last layer is present
          fr_t* layer11;
          if (tree_r_only) {
            layer11 = &resource.column_data[0];
          } else {
            layer11 = &resource.column_data[C::PARALLEL_SECTORS *
                                            (params.GetNumLayers() - 1) * batch_size];
          }
          memcpy(encode_buf, layer11,
                 C::PARALLEL_SECTORS * batch_size * sizeof(fr_t));

          // Encode non CC sectors
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            if (data_files[i].is_open()) {
              for (size_t j = 0; j < batch_size; j++) {
                // Perform the field add without moving to Montgomery space
                fr_t data = data_files[i][resource.start_node + j];
                fr_t* elmt = &encode_buf[i + j * C::PARALLEL_SECTORS];
                node_t* n = (node_t*)elmt;
                n->reverse_l();
                *elmt += data;
                n->reverse_l();
              }
            }
          }

          if (!tree_r_only) {
            // Prepare write pointers
            to_disk->size = batch_size;
            to_disk->stride = C::PARALLEL_SECTORS;
            to_disk->reverse = true;
            for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
              to_disk->src[i] = &to_disk->data[i];
              to_disk->dst[i] = &sealed_files[i][resource.start_node];
              if (data_files[i].is_open()) {
              }
            }
            // Copy the encoded replica data into the disk buffer
            memcpy(&to_disk->data[0],
                   &resource.replica_data[0],
                   batch_size * C::PARALLEL_SECTORS * sizeof(fr_t));
          }
          
          if (tree_r_only) {
            resource.state = ResourceState::HASH_COLUMN_LEAVES;
          } else {
            host_buf_to_disk1.enqueue(to_disk);
            resource.state = ResourceState::HASH_COLUMN;
          }
        }
        break;
      
      case ResourceState::HASH_COLUMN:
        if (host_buf_to_disk0.is_full()) {
          break;
        }
        to_disk = host_buf_pool0.dequeue();
        if (to_disk == nullptr) {
          break;
        }
        
        resource.stream.HtoD(&resource.column_data_d[0], resource.column_data, resource.batch_elements);

        // Hash the columns
        poseidon_columns[gpu_id]->hash_batch_device
          (out_c_d, &resource.column_data_d[0], &resource.aux_d[0],
           batch_size * C::PARALLEL_SECTORS, C::PARALLEL_SECTORS,
           resource.stream, true, false, true, true,
           !reader.data_is_big_endian());

        // Initiate copy of the hashed data from GPU
        fr = to_disk->data;
        resource.stream.DtoH(fr, out_c_d, batch_size * C::PARALLEL_SECTORS);

        // Initiate transfer of tree-c data to files
        layer_offset = layer_offsets_c[resource.work_c.idx.layer() - 1];
        addr = node_id_t(resource.work_c.idx.layer() - 1,
                         resource.work_c.idx.node() * batch_size + layer_offset * resource_num);
        offset_c = tree_c_address.address(addr);

        for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
          to_disk->dst[i] = (fr_t*)&tree_c_files[i][partition][offset_c];
          to_disk->src[i] = &to_disk->data[i * batch_size];
        }
        to_disk->size = batch_size;
        to_disk->stride = 1;
        to_disk->reverse = false;

        resources[resource_num]->async_done = false;
        cuda_notify.schedule(resource.stream, [this, resource_num, to_disk, offset_c]() {
          this->host_buf_to_disk0.enqueue(to_disk);
          resources[resource_num]->async_done = true;
        });

        resource.state = ResourceState::HASH_COLUMN_LEAVES;
        break;
        
      case ResourceState::HASH_COLUMN_LEAVES:
        if (!resources[resource_num]->async_done) {
          break;
        }
        if (!tree_r_only) {
          if (host_buf_to_disk0.is_full()) {
            break;
          }
          to_disk = host_buf_pool0.dequeue();
          if (to_disk == nullptr) {
            break;
          }

          // Hash tree-c
          poseidon_trees[gpu_id]->hash_batch_device
            (out_c_d, out_c_d, &resource.aux_d[0],
             batch_size * C::PARALLEL_SECTORS / TREE_ARITY, 1,
             resource.stream, false, false, true, true,
             !reader.data_is_big_endian());
        }

        // Hash tree-r using the replica data. If there are any non-CC
        // sectors then copy the encoded replica data over
        if (has_non_cc_sectors || tree_r_only) {
          resource.stream.HtoD
            (&resource.column_data_d[batch_size * C::PARALLEL_SECTORS * (params.GetNumLayers() - 1)],
             &resource.replica_data[0], C::PARALLEL_SECTORS * batch_size);
        }
        poseidon_trees[gpu_id]->hash_batch_device
          (out_r_d,
           &resource.column_data_d[batch_size * C::PARALLEL_SECTORS * (params.GetNumLayers() - 1)],
           &resource.aux_d[0],
           batch_size * C::PARALLEL_SECTORS / TREE_ARITY,
           C::PARALLEL_SECTORS,
           resource.stream, false, true, true, true,
           !reader.data_is_big_endian());

        if (!tree_r_only) {
          // Initiate copy of the hashed data from GPU, reusing the host side column buffer
          resource.stream.DtoH(&to_disk->data[0], out_c_d,
                               batch_size * C::PARALLEL_SECTORS / TREE_ARITY);
          
          // Initiate transfer of tree-c data to files
          layer_offset = layer_offsets_c[resource.work_c.idx.layer()];
          addr = node_id_t(resource.work_c.idx.layer(),
                           resource.work_c.idx.node() * batch_size / TREE_ARITY +
                           layer_offset * resource_num);
          offset_c = tree_c_address.address(addr);
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            to_disk->dst[i] = (fr_t*)&tree_c_files[i][partition][offset_c];
            to_disk->src[i] = &to_disk->data[i * batch_size / TREE_ARITY];
          }
          to_disk->size = batch_size / TREE_ARITY;
          to_disk->stride = 1;
          to_disk->reverse = false;
        }
        
        resources[resource_num]->async_done = false;
        cuda_notify.schedule(resource.stream, [this, resource_num, to_disk]() {
          if (!tree_r_only) {
            this->host_buf_to_disk0.enqueue(to_disk);
          }
          resources[resource_num]->async_done = true;
        });
        
        resource.state = ResourceState::HASH_WAIT;
        break;

      case ResourceState::HASH_LEAF:
        disk_bufs_needed = tree_r_only ? 1 : 2;
        if (host_buf_to_disk0.free_count() < disk_bufs_needed) {
          break;
        }
        if (host_buf_pool0.size() < disk_bufs_needed) {
          break;
        }
        if (!tree_r_only) {
          to_disk = host_buf_pool0.dequeue();
          assert (to_disk != nullptr);
        
          // Hash tree-c
          for (size_t i = 0; i < TREE_ARITY; i++) {
            in_d.ptrs[i] = &(*resource.work_c.inputs[i])[0];
          }

          poseidon_trees[gpu_id]->hash_batch_device_ptrs
            (out_c_d, in_d, &resource.aux_d[0],
             batch_size * C::PARALLEL_SECTORS / TREE_ARITY,
             C::PARALLEL_SECTORS,
             resource.stream, false, false, true, true,
             !reader.data_is_big_endian());
        }
        
        // Hash tree-r 
        for (size_t i = 0; i < TREE_ARITY; i++) {
          in_d.ptrs[i] = &(*resource.work_r.inputs[i])[0];
        }
        poseidon_trees[gpu_id]->hash_batch_device_ptrs
          (out_r_d, in_d, &resource.aux_d[0],
           batch_size * C::PARALLEL_SECTORS / TREE_ARITY,
           C::PARALLEL_SECTORS,
           resource.stream, false, false, true, true,
           !reader.data_is_big_endian());
        
        if (!tree_r_only) {
          // Initiate copy of the hashed data
          resource.stream.DtoH(&to_disk->data[0], out_c_d,
                               batch_size * C::PARALLEL_SECTORS / TREE_ARITY);
          if (resource.last) {
            // Stash the final result in a known place
            size_t stride = batch_size * C::PARALLEL_SECTORS / TREE_ARITY;
            fr_t* host_buf_c = (fr_t*)&gpu_results_c[resource.id * stride];
            CUDA_OK(cudaMemcpyAsync(host_buf_c, &to_disk->data[0],
                                    batch_size * C::PARALLEL_SECTORS / TREE_ARITY * sizeof(fr_t),
                                    cudaMemcpyHostToHost, resource.stream));
          }

          // Compute offsets in the output files - tree-c
          layer_offset = layer_offsets_c[resource.work_c.idx.layer()];
          addr = node_id_t(resource.work_c.idx.layer(),
                           resource.work_c.idx.node() * batch_size / TREE_ARITY +
                           layer_offset * resource_num);
          offset_c = tree_c_address.address(addr);
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            to_disk->dst[i] = (fr_t*)&tree_c_files[i][partition][offset_c];
            to_disk->src[i] = &to_disk->data[i * batch_size / TREE_ARITY];
          }
          to_disk->size = batch_size / TREE_ARITY;
          to_disk->stride = 1;
          to_disk->reverse = false;
        }
        
        // tree-r
        write_tree_r = resource.work_r.idx.layer() > params.GetNumTreeRDiscardRows();
        if (write_tree_r) {
          to_disk_r = host_buf_pool0.dequeue();
          assert (to_disk_r != nullptr);
          resource.stream.DtoH(&to_disk_r->data[0], out_r_d,
                               batch_size * C::PARALLEL_SECTORS / TREE_ARITY);
          
          if (resource.last) {
            // Stash the final result in a known place
            size_t stride = batch_size * C::PARALLEL_SECTORS / TREE_ARITY;
            fr_t* host_buf_r = (fr_t*)&gpu_results_r[resource.id * stride];
            CUDA_OK(cudaMemcpyAsync(host_buf_r, &to_disk_r->data[0],
                                    batch_size * C::PARALLEL_SECTORS / TREE_ARITY * sizeof(fr_t),
                                    cudaMemcpyHostToHost, resource.stream));
          }

          layer_offset = layer_offsets_r[resource.work_r.idx.layer() - params.GetNumTreeRDiscardRows() - 1];
          addr = node_id_t(resource.work_r.idx.layer() - params.GetNumTreeRDiscardRows() - 1,
                           resource.work_r.idx.node() * batch_size / TREE_ARITY +
                           layer_offset * resource_num);
          offset_r = tree_r_address.address(addr);
          for (size_t i = 0; i < C::PARALLEL_SECTORS; i++) {
            to_disk_r->dst[i] = (fr_t*)&tree_r_files[i][partition][offset_r];
            to_disk_r->src[i] = &to_disk_r->data[i * batch_size / TREE_ARITY];
          }
          to_disk_r->size = batch_size / TREE_ARITY;
          to_disk_r->stride = 1;
          to_disk_r->reverse = false;
        }
        
        // Initiate transfer of data to files
        resources[resource_num]->async_done = false;
        cuda_notify.schedule(resource.stream, [this, resource_num,
                                               to_disk, to_disk_r, write_tree_r]() {
          if (!tree_r_only) {
            this->host_buf_to_disk0.enqueue(to_disk);
          }
          if (write_tree_r) {
            this->host_buf_to_disk0.enqueue(to_disk_r);
          }
          resources[resource_num]->async_done = true;
        });

        resource.state = ResourceState::HASH_WAIT;
        break;
      
      case ResourceState::HASH_WAIT:
        if (resource.async_done.load() == true) {
          if (resource.last) {
            resource.state = ResourceState::DONE;
          } else {
            resource.state = ResourceState::IDLE;
          }
        }
        break;

      default:
        abort();
      }
    }
  }
  //printf("PC2: GPU state machine done, syncing streams\n");
  for (size_t resource_num = 0; resource_num < stream_count; resource_num++) {
    resources[resource_num]->stream.sync();
  }

  terminate = true;

  // Really only need this at the last partition...
  if (tree_r_only) {
    while (disk_writer_done < 1) {}
  } else {
    while (disk_writer_done < 2) {}
  }
}

template<class C>
void pc2_t<C>::hash_cpu(fr_t* roots, size_t partition, fr_t* input,
                        std::vector<mmap_t<uint8_t>>* tree_files,
                        size_t file_offset) {
  // This count is one layer above the leaves
  const size_t nodes_to_hash = batch_size * stream_count / TREE_ARITY / TREE_ARITY;
  // Number of consecutive nodes in the input stream
  const size_t group_size = batch_size / TREE_ARITY;
  // For simplicity of indexing require batch size to be a multiple of arity
  assert (group_size % TREE_ARITY == 0);

  tree_address_t final_tree(nodes_to_hash, TREE_ARITY, sizeof(fr_t), 0);

  Poseidon hasher(TREE_ARITY);

  auto hash_func = [this, &hasher, &final_tree, input, partition, tree_files, file_offset, group_size]
    (work_item_t<host_buffer_t>& w) {
    node_id_t addr(w.idx.layer() - 1, w.idx.node());
    size_t offset = final_tree.address(addr) + file_offset;

    if (w.is_leaf) {
      for (size_t sector = 0; sector < C::PARALLEL_SECTORS; sector++) {
        fr_t* out = &(*w.buf)[sector];
        fr_t in[TREE_ARITY];

        size_t first_input_node = w.idx.node() * TREE_ARITY;
        for (size_t i = 0; i < TREE_ARITY; i++) {
          size_t input_group   = (first_input_node + i) / group_size;
          size_t node_in_group = (first_input_node + i) % group_size;
          
          in[i] = input[input_group * group_size * C::PARALLEL_SECTORS +
                        sector * group_size + node_in_group];
        }
        hasher.Hash((uint8_t*)out, (uint8_t*)in);
        memcpy(&tree_files[sector][partition][offset],
               &out[0], sizeof(fr_t));
      }
    } else {
      for (size_t sector = 0; sector < C::PARALLEL_SECTORS; sector++) {
        fr_t* out = &(*w.buf)[sector];
        fr_t in[TREE_ARITY];
        for (size_t i = 0; i < TREE_ARITY; i++) {
          in[i] = (*w.inputs[i])[sector];
        }
        hasher.Hash((uint8_t*)out, (uint8_t*)in);
        
        memcpy(&tree_files[sector][partition][offset],
               &out[0], sizeof(fr_t));
      }
    }
  };
  
  buffers_t<host_buffer_t> buffers(C::PARALLEL_SECTORS);
  scheduler_t<host_buffer_t> scheduler(nodes_to_hash, TREE_ARITY, buffers);
  host_buffer_t* host_buf = scheduler.run(hash_func);
  memcpy(roots, &(*host_buf)[0], sizeof(fr_t) * C::PARALLEL_SECTORS);
  assert (scheduler.is_done());
}

template<class C>
void pc2_t<C>::write_roots(fr_t* roots_c, fr_t* roots_r) {
  if (params.GetNumTreeRCFiles() > 1) {
    Poseidon hasher(TREE_ARITY);
    for (size_t sector = 0; sector < C::PARALLEL_SECTORS; sector++) {
      fr_t in[TREE_ARITY];
      fr_t out_c;
      if (!tree_r_only) {
        for (size_t i = 0; i < TREE_ARITY; i++) {
          in[i] = roots_c[i * C::PARALLEL_SECTORS + sector];
        }
        hasher.Hash((uint8_t*)&out_c, (uint8_t*)in);
      }
      
      fr_t out_r;
      for (size_t i = 0; i < TREE_ARITY; i++) {
        in[i] = roots_r[i * C::PARALLEL_SECTORS + sector];
      }
      hasher.Hash((uint8_t*)&out_r, (uint8_t*)in);
    
      const size_t MAX = 256;
      char fname[MAX];
      if (C::PARALLEL_SECTORS == 1) {
        snprintf(fname, MAX, p_aux_template, output_dir);
      } else {
        snprintf(fname, MAX, p_aux_template, output_dir, sector);
      }
      int p_aux = open(fname, O_RDWR | O_CREAT, (mode_t)0664);
      assert (p_aux != -1);
      if (tree_r_only) {
        fr_t zero;
        zero.zero();
        assert (write(p_aux, &zero, sizeof(fr_t)) == sizeof(fr_t));
      } else {
        assert (write(p_aux, &out_c, sizeof(fr_t)) == sizeof(fr_t));
      }
      assert (write(p_aux, &out_r, sizeof(fr_t)) == sizeof(fr_t));
      close(p_aux);
    }
  } else {
    for (size_t sector = 0; sector < C::PARALLEL_SECTORS; sector++) {
      fr_t out_c = roots_c[sector];
      fr_t out_r = roots_r[sector];

      const size_t MAX = 256;
      char fname[MAX];
      if (C::PARALLEL_SECTORS == 1) {
        snprintf(fname, MAX, p_aux_template, output_dir);
      } else {
        snprintf(fname, MAX, p_aux_template, output_dir, sector);
      }
      int p_aux = open(fname, O_RDWR | O_CREAT, (mode_t)0664);
      assert (p_aux != -1);
      if (tree_r_only) {
        fr_t zero;
        zero.zero();
        assert (write(p_aux, &zero, sizeof(fr_t)) == sizeof(fr_t));
      } else {
        assert (write(p_aux, &out_c, sizeof(fr_t)) == sizeof(fr_t));
      }
      assert (write(p_aux, &out_r, sizeof(fr_t)) == sizeof(fr_t));
      close(p_aux);
    }
  }
}

template<class C>
void pc2_hash(SectorParameters& params, topology_t& topology,
              bool tree_r_only,
              streaming_node_reader_t<C>& reader,
              size_t nodes_to_read, size_t batch_size,
              size_t stream_count,
              const char** data_filenames, const char* output_dir) {
  pc2_t<C> pc2(params, topology, tree_r_only, reader, nodes_to_read, batch_size, stream_count,
               data_filenames, output_dir);
  pc2.hash();
}

template void pc2_hash<sealing_config128_t>(SectorParameters& params, topology_t& topology,
                                            bool tree_r_only,
                                            streaming_node_reader_t<sealing_config128_t>& reader,
                                            size_t nodes_to_read, size_t batch_size,
                                            size_t stream_count,
                                            const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config64_t>(SectorParameters& params, topology_t& topology,
                                           bool tree_r_only,
                                           streaming_node_reader_t<sealing_config64_t>& reader,
                                           size_t nodes_to_read, size_t batch_size,
                                           size_t stream_count,
                                           const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config32_t>(SectorParameters& params, topology_t& topology,
                                           bool tree_r_only,
                                           streaming_node_reader_t<sealing_config32_t>& reader,
                                           size_t nodes_to_read, size_t batch_size,
                                           size_t stream_count,
                                           const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config16_t>(SectorParameters& params, topology_t& topology,
                                           bool tree_r_only,
                                           streaming_node_reader_t<sealing_config16_t>& reader,
                                           size_t nodes_to_read, size_t batch_size,
                                           size_t stream_count,
                                           const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config8_t>(SectorParameters& params, topology_t& topology,
                                          bool tree_r_only,
                                          streaming_node_reader_t<sealing_config8_t>& reader,
                                          size_t nodes_to_read, size_t batch_size,
                                          size_t stream_count,
                                          const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config4_t>(SectorParameters& params, topology_t& topology,
                                          bool tree_r_only,
                                          streaming_node_reader_t<sealing_config4_t>& reader,
                                          size_t nodes_to_read, size_t batch_size,
                                          size_t stream_count,
                                          const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config2_t>(SectorParameters& params, topology_t& topology,
                                          bool tree_r_only,
                                          streaming_node_reader_t<sealing_config2_t>& reader,
                                          size_t nodes_to_read, size_t batch_size,
                                          size_t stream_count,
                                          const char** data_filenames, const char* output_dir);
template void pc2_hash<sealing_config1_t>(SectorParameters& params, topology_t& topology,
                                          bool tree_r_only,
                                          streaming_node_reader_t<sealing_config1_t>& reader,
                                          size_t nodes_to_read, size_t batch_size,
                                          size_t stream_count,
                                          const char** data_filenames, const char* output_dir);

#endif
