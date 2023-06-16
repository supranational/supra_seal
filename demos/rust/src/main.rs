// Copyright Supranational LLC

// This is a basic demonstration of the sealing pipeline, the bindings
// interface and order of operations from a rust perspective

#![feature(vec_into_raw_parts)]

use filecoin_proofs_api::RegisteredSealProof;
use filecoin_proofs_v1::{
    ProverId, 
    Ticket,
};

use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use std::thread;
use storage_proofs_core::{
    merkle::MerkleTreeTrait,
};

extern crate chrono;

pub type ReplicaId = Vec<u8>;

// C Bindings
extern "C" {
    // Optional init function. Default config file is supra_config.cfg
    fn supra_seal_init(config_filename: *const c_char);

    fn get_max_block_offset() -> usize;

    fn get_slot_size(num_sectors: usize) -> usize;

    fn pc1(block_offset: usize,
           num_sectors: usize,
           replica_ids: *const u8,
           parents_filename: *const c_char) -> u32;

    fn pc2(block_offset: usize,
           num_sectors: usize,
           output_dir: *const c_char,
           data_filenames: *const *const c_char) -> u32;

    fn pc2_cleanup(num_sectors: usize,
                   output_dir: *const c_char) -> u32;
    
    fn c1(block_offset: usize,
          num_sectors: usize,
          sector_slot: usize,
          replica_id: *const u8,
          seed: *const u8,
          ticket: *const u8,
          cache_path: *const c_char,
          parents_filename: *const c_char,
          replica_path: *const c_char) -> u32;
}

pub fn init_wrapper<T: AsRef<std::path::Path>>(config: T) {
    let config_c = CString::new(config.as_ref().as_os_str().as_bytes()).unwrap();
    unsafe {
        supra_seal_init(config_c.as_ptr());
    };
}

// Rust wrappers around unsafe C calls
pub fn get_max_block_offset_wrapper() -> usize {
    let max_offset = unsafe { get_max_block_offset() };
    println!("Max Offset returned {:x}", max_offset);
    return max_offset;
}

pub fn get_slot_size_wrapper(num_sectors: usize) -> usize {
    let slot_size = unsafe { get_slot_size(num_sectors) };
    println!("Slot size  returned {:x} for {} sectors", slot_size, num_sectors);
    return slot_size;
}

pub fn pc1_wrapper<T: AsRef<std::path::Path>>(
    block_offset: usize,
    num_sectors: usize,
    replica_ids: Vec<ReplicaId>,
    path: T) -> u32 {

    let f = replica_ids.into_iter().flatten().collect::<Vec<u8>>();
    let path_c = CString::new(path.as_ref().as_os_str().as_bytes()).unwrap();
    let pc1_status = unsafe {
        pc1(block_offset, num_sectors, f.as_ptr(), path_c.as_ptr())
    };
    println!("PC1 returned {}", pc1_status);
    return pc1_status;
}

pub fn pc2_wrapper<T: AsRef<std::path::Path>>(
    block_offset: usize,
    num_sectors: usize,
    path: T) -> u32 {

    let path_c = CString::new(path.as_ref().as_os_str().as_bytes()).unwrap();
    let pc2_status = unsafe { pc2(block_offset, num_sectors,
                                  path_c.as_ptr(), std::ptr::null()) };
    println!("PC2 returned {}", pc2_status);
    return pc2_status;
}

pub fn pc2_cleanup_wrapper<T: AsRef<std::path::Path>>(
    num_sectors: usize,
    path: T) -> u32 {

    let path_c = CString::new(path.as_ref().as_os_str().as_bytes()).unwrap();
    let pc2_status = unsafe { pc2_cleanup(num_sectors, path_c.as_ptr()) };
    println!("PC2 cleanup returned {}", pc2_status);
    return pc2_status;
}

pub fn c1_wrapper<T: AsRef<std::path::Path>>(
    block_offset: usize,
    num_sectors: usize,
    sector_id: usize,
    replica_id: *const u8,
    seed: *const u8,
    ticket: *const u8,
    cache_path: T,
    parents_filename: T,
    replica_path: T) -> u32 {

    let cache_path_c =
        CString::new(cache_path.as_ref().as_os_str().as_bytes()).unwrap();
    let parents_c =
        CString::new(parents_filename.as_ref().as_os_str().as_bytes()).unwrap();
    let replica_path_c =
        CString::new(replica_path.as_ref().as_os_str().as_bytes()).unwrap();

    let c1_status = unsafe {
        c1(block_offset,
           num_sectors,
           sector_id,
           replica_id,
           seed,
           ticket,
           cache_path_c.as_ptr(),
           parents_c.as_ptr(),
           replica_path_c.as_ptr())
    };
    println!("C1 returned {}", c1_status);
    return c1_status;
}

// Helper function to create replica ids
fn create_replica_id(
    prover_id: ProverId,
    _registered_proof: RegisteredSealProof,
    sector_id: u64,
    comm_d: &[u8; 32],
    ticket: Ticket,
) -> ReplicaId {
    //let config = registered_proof.as_v1_config();

    // For testing
    let porep_seed: [u8; 32] = [99u8; 32]; // TODO - remove
    let hash = Sha256::new()
        .chain_update(&prover_id)
        .chain_update(sector_id.to_be_bytes())
        .chain_update(&ticket)
        .chain_update(comm_d)
        //.chain_update(&config.porep_id)
        .chain_update(&porep_seed)
        .finalize();

    let mut id = [0u8; 32];
    id.copy_from_slice(&hash);
    id[31] &= 0b0011_1111;
    id.to_vec()
}

fn run_pipeline<Tree: 'static + MerkleTreeTrait>(
    num_sectors: usize,
    c2_cores: &str,
    parents_cache_filename: &str,
    registered_proof: RegisteredSealProof,
    comm_d: [u8; 32],
) {
    #[cfg(feature = "32GiB")]
    let wait_seed_time = Duration::from_secs(60 * 75); // 75 min

    #[cfg(feature = "512MiB")]
    let wait_seed_time = Duration::from_secs(30); // 30s

    let mut parents_cache_file = PathBuf::new();
    parents_cache_file.push(parents_cache_filename);

    // This is optional but if present must be the first call into the library
    //init_wrapper("supra_seal_zen.cfg");

    let max_offset = get_max_block_offset_wrapper();
    let slot_size = get_slot_size_wrapper(num_sectors);

    println!("max_offset {} and slot_size {}", max_offset, slot_size);

    // Choose some fixed values for demonstration
    // All sectors using the same prover id, ticket, and wait seed
    let prover_id: ProverId = [ 9u8; 32];
    let ticket: Ticket = [ 1u8; 32];
    let seed: Ticket = [ 0u8; 32];

    // Example showing operations running in parallel
    let pc1_counter = Arc::new(Mutex::new((0, 0)));
    let pc2_counter = Arc::new(Mutex::new(0));
    let c1_counter = Arc::new(Mutex::new(0));
    let c2_counter = Arc::new(Mutex::new(0));
    
    //let passed_counter = Arc::new(Mutex::new(0));
    let failed_counter = Arc::new(Mutex::new(0));
    let gpu_counter = Arc::new(Mutex::new(0));

    let pipeline_start = Arc::new(Mutex::new(Instant::now()));
    let gpu_lock = Arc::new(Mutex::new(false));
    
    // Specify the number of slots that can be run at a time
    // This will come down to resources on the machine and number of sectors
    //   being sealed in parallel.
    let num_slots = 2; // This matches mutex array below
    let slot_counter = Arc::new([Mutex::new(0), Mutex::new(0)]);
    let mut pipelines = vec![];

    // Demonstrate three passes through the pipeline
    // Batch 0  PC1  PC2   C1   C2
    // Batch 1       PC1  PC2   C1   C2
    // Batch 2            PC1  PC2   C1   C2
    let num_batches = 5;
    for batch_num in 0..num_batches {
        let pc1_counter = Arc::clone(&pc1_counter);
        let pc2_counter = Arc::clone(&pc2_counter);
        let c1_counter = Arc::clone(&c1_counter);
        let c2_counter = Arc::clone(&c2_counter);
        let c2_cores = c2_cores.to_string();

        let failed_counter = Arc::clone(&failed_counter);
        let gpu_counter = Arc::clone(&gpu_counter);
        let slot_counter = Arc::clone(&slot_counter);
        let parents_cache_file = parents_cache_file.clone();

        let pipeline_start = Arc::clone(&pipeline_start);
        let gpu_lock = Arc::clone(&gpu_lock);
        
        let pipeline = thread::spawn(move || {
            let pipe_dir = "/var/tmp/supra_seal/".to_owned() + &batch_num.to_string();
            let output_dir = Path::new(&pipe_dir);

            // Grab unique sector ids for each sector in the batch
            let batch_sector_start = batch_num * num_sectors;

            // Create replica_ids
            let mut cur_sector_id = batch_sector_start;
            let mut replica_ids: Vec<ReplicaId> = Vec::new();
            for _ in 0..num_sectors {
                let replica_id = create_replica_id(
                    prover_id,
                    registered_proof,
                    cur_sector_id as u64,
                    &comm_d,
                    ticket);

                cur_sector_id += 1; // Increment sector id for each sector
                replica_ids.push(replica_id);
            }

            // Indent based on batch number
            let mut indent: String = "".to_owned();
            for _x in 0..batch_num {
                indent += "    ";
            }

            //if batch_num > 0 { // TODO SNP: testing only, remove
            // Wait until it's time for this batch's pc1 to start
            {
                let mut pc1_counter_lock = pc1_counter.lock().unwrap();
                while (*pc1_counter_lock).0 != batch_num {
                    drop(pc1_counter_lock);
                    thread::sleep(Duration::from_millis(100));
                    pc1_counter_lock = pc1_counter.lock().unwrap();
                }
            }
            
            // Lock the slot
            let cur_slot = batch_num % num_slots;
            let mut slot_count = slot_counter[cur_slot].lock().unwrap();
            println!("{}**** {} Batch {} locked slot {}", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num, cur_slot);
            *slot_count += 1;
            
            // Lock PC1
            let cur_offset;
            let cp_replica_ids = replica_ids.clone();
            {
                let mut pc1_count = pc1_counter.lock().unwrap();
                println!("{}**** {} Batch {} start PC1", indent,
                         chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                         batch_num);
                cur_offset = (*pc1_count).1;
                (*pc1_count).1 += slot_size;
                
                // Check if pc1 will overflow available disk space
                if ((*pc1_count).1 + slot_size) >  max_offset {
                    (*pc1_count).1 = 0;
                }
                
                // Do PC1
                //if batch_num > 0 { // TODO SNP: testing only, remove
                    pc1_wrapper(cur_offset, num_sectors,
                                replica_ids, parents_cache_file.clone());
                //}
                (*pc1_count).0 += 1;
                println!("{}**** {} Batch {} done with PC1", indent,
                         chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                         batch_num);
            }
            
            // PC2
            {
                let mut gpu_lock = gpu_lock.lock().unwrap();
                *gpu_lock = true;
                
                if batch_num == 1 {
                    let mut pipeline_start_lock = pipeline_start.lock().unwrap();
                    *pipeline_start_lock = Instant::now();
                    drop(pipeline_start_lock);
                    println!("\n**** {} Pipeline start\n",
                             chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"));
                }
                
                let mut pc2_count = pc2_counter.lock().unwrap();
                let mut gpu_count = gpu_counter.lock().unwrap();
                println!("{}**** {} Batch {} start PC2", indent,
                         chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                         batch_num);
                *gpu_count += 1;
                
                pc2_wrapper(cur_offset, num_sectors, output_dir);
                *pc2_count += 1;
                *gpu_lock = false;
                println!("{}**** {} Batch {} done with PC2", indent,
                         chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                         batch_num);
            }
            
            println!("{}**** {} Batch {} Wait Seed sleeping {:?}", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num, wait_seed_time);
            thread::sleep(wait_seed_time);
            println!("{}**** {} Batch {} Wait Seed done sleeping", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num);
            
            // C1
            // Each of these can be parallelized, however the function only
            //  operates on a single sector at a time as opposed to PC1/PC2
            println!("{}**** {} Batch {} start C1", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num);
            for sector_slot in 0..num_sectors {
                let mut cur_cache_path = PathBuf::from(output_dir);
                cur_cache_path.push(format!("{:03}", sector_slot));
                let mut cur_replica_dir = PathBuf::from(output_dir);
                cur_replica_dir.push(format!("{:03}", sector_slot));
                
                c1_wrapper(cur_offset,
                           num_sectors,
                           sector_slot,
                           cp_replica_ids[sector_slot].as_ptr(),
                           seed.as_ptr(),
                           ticket.as_ptr(),
                           cur_cache_path,
                           //parents_cache_file.to_path_buf(),
                           parents_cache_file.clone(),
                           cur_replica_dir);
            }
            *c1_counter.lock().unwrap() += 1;
            println!("{}**** {} Batch {} done with C1", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num);
            
            // At this point the layers on NVME for this batch can be reused
            println!("{}**** {} Batch {} dropping lock on slot {}", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num, cur_slot);
            drop(slot_count);
            
            // Delete pc2 content
            println!("{}**** {} Batch {} cleanup pc2 on slot {}", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num, cur_slot);
            pc2_cleanup_wrapper(num_sectors, output_dir);
            
            // Wait until it's time for this batch's c2 to start, which is after
            // the next batch's pc2
            if batch_num < num_batches - 1 {
                let mut pc2_counter_lock = pc2_counter.lock().unwrap();
                while *pc2_counter_lock != batch_num + 2 {
                    drop(pc2_counter_lock);
                    thread::sleep(Duration::from_millis(100));
                    pc2_counter_lock = pc2_counter.lock().unwrap();
                }
            }

            // TODO SNP: testing only, remove
            // } else {
            //     let cur_slot = batch_num % num_slots;
            //     *slot_counter[cur_slot].lock().unwrap() += 1;
            //     let mut pc1_count = pc1_counter.lock().unwrap();
            //     (*pc1_count).1 += slot_size;
            //     // Check if pc1 will overflow available disk space
            //     if ((*pc1_count).1 + slot_size) >  max_offset {
            //         (*pc1_count).1 = 0;
            //     }
            //     (*pc1_count).0 += 1;
                
            //     *pc2_counter.lock().unwrap() += 1;
            //     *c1_counter.lock().unwrap() += 1;
            // }
                
            // C2
            let mut gpu_lock = gpu_lock.lock().unwrap();
            *gpu_lock = true;
            println!("{}**** {} Batch {} start C2", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num);
            let mut c2_count = c2_counter.lock().unwrap();
            *gpu_counter.lock().unwrap() += 1;

            let now = Instant::now();
            let status = std::process::Command::new("/usr/bin/taskset")
                .arg("-c").arg(c2_cores).arg("./target/release/c2")
                .arg(output_dir).arg(batch_sector_start.to_string())
                .status().expect("failed to execute process");
            println!("status: {}", status);
            println!("{}**** {} Batch {} C2 done took {:.2?}", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num, now.elapsed());
            *failed_counter.lock().unwrap() += status.code().unwrap();

            if batch_num == 0 {
                let pipeline_start_lock = pipeline_start.lock().unwrap();
                println!("**** {} Pipeline took {:?}\n",
                         chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                         (*pipeline_start_lock).elapsed());
            }                
            println!("{}**** {} Batch {} done with C2", indent,
                     chrono::Local::now().format("%Y-%m-%d %H:%M:%S %s"),
                     batch_num);
            *c2_count += 1;
            drop(c2_count);
            *gpu_lock = false;
            drop(gpu_lock);
        });
        pipelines.push(pipeline);
    }

    for pipeline in pipelines {
        pipeline.join().unwrap();
    }

    let pc1_count = pc1_counter.lock().unwrap();
    println!("PC1 counter: {} {}", (*pc1_count).0, (*pc1_count).1);
    println!("PC2 counter: {}", *pc2_counter.lock().unwrap());
    println!("C1 counter:  {}", *c1_counter.lock().unwrap());
    println!("C2 counter:  {}", *c2_counter.lock().unwrap());
    println!("GPU counter:  {}", *gpu_counter.lock().unwrap());
    println!("Failed counter:  {}", *failed_counter.lock().unwrap());
    for i in 0..num_slots {
      println!("Slot counter[{}]: {}", i, *slot_counter[i].lock().unwrap());
    }
}

#[cfg(feature = "32GiB")]
fn run_pipeline_32(num_sectors: usize, c2_cores: &str) {
    let parents_cache_filename = "/var/tmp/filecoin-parents/v28-sdr-parent-55c7d1e6bb501cc8be94438f89b577fddda4fafa71ee9ca72eabe2f0265aefa6.cache";

    // 32GB CC sector comm d
    let comm_d: [u8; 32] = [ 0x07, 0x7e, 0x5f, 0xde, 0x35, 0xc5, 0x0a, 0x93,
                             0x03, 0xa5, 0x50, 0x09, 0xe3, 0x49, 0x8a, 0x4e,
                             0xbe, 0xdf, 0xf3, 0x9c, 0x42, 0xb7, 0x10, 0xb7,
                             0x30, 0xd8, 0xec, 0x7a, 0xc7, 0xaf, 0xa6, 0x3e ];

    let registered_proof = RegisteredSealProof::StackedDrg32GiBV1_1;

    run_pipeline::<filecoin_proofs_v1::SectorShape32GiB>(
        num_sectors,
        c2_cores,
        parents_cache_filename,
        registered_proof,
        comm_d,
    );
}

#[cfg(feature = "512MiB")]
fn run_pipeline_512(num_sectors: usize, c2_cores: &str) {
    let parents_cache_filename = "/var/tmp/filecoin-parents/v28-sdr-parent-016f31daba5a32c5933a4de666db8672051902808b79d51e9b97da39ac9981d3.cache";

    let comm_d: [u8;32] =  [  57,  86,  14, 123,  19, 169,  59,   7,
                             162,  67, 253,  39,  32, 255, 167, 203,
                              62,  29,  46,  80,  90, 179,  98, 158,
                             121, 244,  99,  19,  81,  44, 218,   6 ];

    let registered_proof = RegisteredSealProof::StackedDrg512MiBV1_1;

    run_pipeline::<filecoin_proofs_v1::SectorShape512MiB>(
        num_sectors,
        c2_cores,
        parents_cache_filename,
        registered_proof,
        comm_d,
    );
}

fn main() {
    let num_sectors: usize = 128;
    //let num_sectors: usize = 64;
    //let num_sectors: usize = 32;

    // Cores for C2 use, in a string that can be passed to taskset
    let c2_cores = "4-7,45-47,48-63";

    #[cfg(feature = "32GiB")]
    run_pipeline_32(num_sectors, c2_cores);

    #[cfg(feature = "512MiB")]
    run_pipeline_512(num_sectors, c2_cores);
}
