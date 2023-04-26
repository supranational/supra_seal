// Copyright Supranational LLC

// This is a basic demonstration of the sealing pipeline, the bindings
// interface and order of operations from a rust perspective

#![feature(vec_into_raw_parts)]

//use anyhow::Context;
//use bincode::deserialize;
//use filecoin_proofs::constants::{SectorShape32GiB};

//use filecoin_proofs::types::{ProverId, SealCommitPhase1Output, Ticket};
use filecoin_proofs::types::{ProverId, Ticket};
//use filecoin_proofs::{seal_commit_phase2};
use filecoin_proofs_api::{RegisteredSealProof};
//use filecoin_proofs_api::{RegisteredSealProof, SectorId};
use sha2::{Digest, Sha256};
use std::ffi::CString;
//use std::fs::{read};
use std::os::raw::c_char;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::thread;

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
           output_dir: *const c_char) -> u32;

    fn c1(block_offset: usize,
          num_sectors: usize,
          sector_slot: usize,
          replica_id: *const u8,
          seed: *const u8,
          ticket: *const u8,
          cache_path: *const c_char,
          parents_filename: *const c_char) -> u32;
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
    let pc2_status = unsafe { pc2(block_offset, num_sectors, path_c.as_ptr()) };
    println!("PC2 returned {}", pc2_status);
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
    parents_filename: T) -> u32 {

    let cache_path_c =
        CString::new(cache_path.as_ref().as_os_str().as_bytes()).unwrap();
    let parents_c =
        CString::new(parents_filename.as_ref().as_os_str().as_bytes()).unwrap();

    let c1_status = unsafe { 
        c1(block_offset,
           num_sectors,
           sector_id,
           replica_id,
           seed,
           ticket,
           cache_path_c.as_ptr(),
           parents_c.as_ptr())
    };
    println!("C1 returned {}", c1_status);
    return c1_status;
}

// Helper function to create replica ids
fn create_replica_id(
    prover_id: ProverId,
    _registered_proof: RegisteredSealProof,
    sector_id: u64,
    comm_d: [u8; 32],
    ticket: Ticket,
) -> ReplicaId {
    // TODO - This is correct method, put back
    //let config = registered_proof.as_v1_config();

    // For testing
    let porep_seed: [u8; 32] = [99u8; 32]; // TODO - remove
    let hash = Sha256::new()
        .chain_update(&prover_id)
        .chain_update(sector_id.to_be_bytes())
        .chain_update(&ticket)
        .chain_update(&comm_d)
        //.chain_update(&config.porep_id)
        .chain_update(&porep_seed)
        .finalize();

    let mut id = [0u8; 32];
    id.copy_from_slice(&hash);
    id[31] &= 0b0011_1111;
    id.to_vec()
}

fn main() {
    let num_sectors: usize = 32;

    // This is optional but if persent must be the first call into the library
    //init_wrapper("supra_seal_zen2.cfg");

    let max_offset = get_max_block_offset_wrapper();
    let slot_size = get_slot_size_wrapper(num_sectors);

    println!("max_offset {} and slot_size {}", max_offset, slot_size);

    #[cfg(feature = "32GiB")]
    let parents_cache_file = Path::new("/var/tmp/filecoin-parents/v28-sdr-parent-55c7d1e6bb501cc8be94438f89b577fddda4fafa71ee9ca72eabe2f0265aefa6.cache");
    #[cfg(feature = "512MiB")]
    let parents_cache_file = Path::new("/var/tmp/filecoin-parents/v28-sdr-parent-016f31daba5a32c5933a4de666db8672051902808b79d51e9b97da39ac9981d3.cache");
    

    // Choose some fixed values for demonstration
    // All sectors using the same prover id, ticket, and wait seed
    let prover_id: ProverId = [ 9u8; 32];
    //let sector_id = SectorId::from(1);
    //let mut cur_sector_id: u64 = 0xFACE;
    let ticket: Ticket = [ 1u8; 32];
    let seed: Ticket = [ 0u8; 32];

    #[cfg(feature = "32GiB")]
    let registered_proof = RegisteredSealProof::StackedDrg32GiBV1_1;
    #[cfg(feature = "512MiB")]
    let registered_proof = RegisteredSealProof::StackedDrg512MiBV1_1;
    
    #[cfg(feature = "32GiB")]
    // 32GB CC sector comm d
    let comm_d: [u8; 32] = [ 0x07, 0x7e, 0x5f, 0xde, 0x35, 0xc5, 0x0a, 0x93,
                             0x03, 0xa5, 0x50, 0x09, 0xe3, 0x49, 0x8a, 0x4e,
                             0xbe, 0xdf, 0xf3, 0x9c, 0x42, 0xb7, 0x10, 0xb7,
                             0x30, 0xd8, 0xec, 0x7a, 0xc7, 0xaf, 0xa6, 0x3e ];
    #[cfg(feature = "512MiB")]
    let comm_d: [u8;32] =  [57, 86, 14, 123, 19, 169, 59, 7,
                            162, 67, 253, 39, 32, 255, 167, 203,
                            62, 29, 46, 80, 90, 179, 98, 158,
                            121, 244, 99, 19, 81, 44, 218, 6];
    // Example showing operations running in parallel
    let sector_ids = Arc::new(Mutex::new(0u64));
    let pc1_counter = Arc::new(Mutex::new((0, 0)));
    let pc2_counter = Arc::new(Mutex::new(0));
    let c2_counter = Arc::new(Mutex::new(0));
    let mut pipelines = vec![];

    // Demonstrate three passes through the pipeline
    // Batch 0  PC1  PC2   C1   C2
    // Batch 1       PC1  PC2   C1   C2
    // Batch 2            PC1  PC2   C1   C2
    for i in 0..3 {
        //let block_offset = Arc::clone(&block_offset);
        let sector_ids = Arc::clone(&sector_ids);
        let pc1_counter = Arc::clone(&pc1_counter);
        let pc2_counter = Arc::clone(&pc2_counter);
        let c2_counter = Arc::clone(&c2_counter);

        let pipeline = thread::spawn(move || {
            let pipe_dir = "/var/tmp/supra_seal/".to_owned() + &i.to_string();
            let output_dir = Path::new(&pipe_dir);

            // Grab unique sector ids for each sector in the batch
            let mut start_sector_id = sector_ids.lock().unwrap();
            let mut cur_sector_id = *start_sector_id;
            *start_sector_id += num_sectors as u64;
            drop(start_sector_id);
        
            // Create replica_ids
            // FIXME - all are using the same prover id and ticket
            let mut replica_ids: Vec<ReplicaId> = Vec::new();
            for _ in 0..num_sectors {
                let replica_id = create_replica_id(
                    prover_id,
                    registered_proof,
                    cur_sector_id,
                    comm_d,
                    ticket);
        
                cur_sector_id += 1; // Increment sector id for each sector
                replica_ids.push(replica_id);
            }

            // Lock PC1
            let mut pc1_count = pc1_counter.lock().unwrap();
            println!("\n**** Batch {} start PC1", i);
            let cur_offset = (*pc1_count).1;
            (*pc1_count).0 += 1;
            (*pc1_count).1 += slot_size;

            // Check if pc1 will overflow available disk space
            if ((*pc1_count).1 + slot_size) >  max_offset {
                // FIXME - need to ensure offset 0 has been freed
                (*pc1_count).1 = 0;
            }

            // FIXME - Cloned to get around borrow 
            let cp_replica_ids = replica_ids.clone();

            // Do PC1
            pc1_wrapper(cur_offset, num_sectors,
                        replica_ids, parents_cache_file);

            // PC1 is complete, drop mutex
            drop(pc1_count);
            println!("\n**** Batch {} done with PC1", i);

            let mut pc2_count = pc2_counter.lock().unwrap();
            println!("\n**** Batch {} start PC2", i);
            *pc2_count += 1;

            pc2_wrapper(cur_offset, num_sectors, output_dir);

            drop(pc2_count);
            println!("\n**** Batch {} done with PC2", i);

            // Each of these can be parallelized, however the function only
            //  operates on a single sector at a time as opposed to PC1/PC2
            // FIXME - output_dir per sector?
            println!("\n**** Batch {} start C1", i);
            for sector_slot in 0..num_sectors {
                c1_wrapper(cur_offset,
                           num_sectors,
                           sector_slot,
                           cp_replica_ids[sector_slot].as_ptr(),
                           seed.as_ptr(),
                           ticket.as_ptr(),
                           output_dir,
                           parents_cache_file);
            }
            println!("\n**** Batch {} done with C1", i);

            // At this point the layers on NVME for this batch can be reused
            // FIXME - need to keep track of available space
        
            // Example how to extract C1 output
            // FIXME - This needs to be done per sector
/*
            let _commit_phase1_output = {
                //let commit_phase1_output_path =
                //    cache_dir.join(COMMIT_PHASE1_OUTPUT_FILE);
                let commit_phase1_output_path = COMMIT_PHASE1_OUTPUT_FILE;
                println!("*** Restoring commit phase1 output file");
                let commit_phase1_output_bytes =
                    read(&commit_phase1_output_path).with_context(|| {
                        format!(
                            "couldn't read file commit_phase1_output_path={:?}",
                            commit_phase1_output_path
                        )
                    }).unwrap();
                println!("commit_phase1_output_bytes len {}",
                         commit_phase1_output_bytes.len());
        
                let res: SealCommitPhase1Output<SectorShape32GiB> =
                    deserialize(&commit_phase1_output_bytes).unwrap();
                res
            };
*/

            let mut c2_count = c2_counter.lock().unwrap();
            println!("\n**** Batch {} start C2", i);
            *c2_count += 1;

            // FIXME - This needs to be done per sector
            // FIXME - Takes forever, may need caching
/*
            let config = registered_proof.as_v1_config();
            let sector_id = SectorId::from(0xFACE);
            let commit_output =
                seal_commit_phase2::<SectorShape32GiB>(config,
                                                       commit_phase1_output,
                                                       prover_id,
                                                       sector_id);
            println!("commit_output {:?}", commit_output);
*/
            drop(c2_count);
            println!("\n**** Batch {} done with C2", i);
        });
        pipelines.push(pipeline);
    }

    for pipeline in pipelines {
        pipeline.join().unwrap();
    }

    let pc1_count = pc1_counter.lock().unwrap();
    println!("PC1 counter: {} {}", (*pc1_count).0, (*pc1_count).1);
    println!("PC2 counter: {}", *pc2_counter.lock().unwrap());
    println!("C2 counter:  {}", *c2_counter.lock().unwrap());
}
