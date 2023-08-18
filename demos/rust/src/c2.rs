// Copyright Supranational LLC

use anyhow::Context;
use bincode::deserialize;
use filecoin_proofs_api::SectorId;
use filecoin_proofs_v1::{
    PoRepConfig, ProverId, seal_commit_phase2, SealCommitPhase1Output,
    verify_seal,
};

use std::fs::read;
use std::path::PathBuf;
use storage_proofs_core::{
    api_version::ApiVersion,
    merkle::MerkleTreeTrait,
};
use std::time::Instant;

use std::thread;
use std::sync::{Arc, Mutex};

fn run_c2<Tree: 'static + MerkleTreeTrait>(
    num_sectors: usize,
    c1_dir: &str,
    start_sector_id: usize,
    porep_config: Arc<PoRepConfig>,
) -> usize {
    // Choose some fixed values for demonstration
    // All sectors using the same prover id, ticket, and wait seed
    let prover_id: ProverId = [ 9u8; 32];
    let slots_sector_id = Arc::new(Mutex::new(start_sector_id));
    let successes = Arc::new(Mutex::new(0));
    
    let mut provers = vec![];

    let commit_phase1_output_path =
        PathBuf::from(c1_dir);
    
    for _ in 0..2 {
        let slots_sector_id = Arc::clone(&slots_sector_id);
        let successes = Arc::clone(&successes);
        let commit_phase1_output_base_path = commit_phase1_output_path.clone();
        let porep_config = Arc::clone(&porep_config);
            
        let prover = thread::spawn(move || {
            loop {
                let mut sector_lock = slots_sector_id.lock().unwrap();
                let cur_sector = *sector_lock;
                let sector_slot = cur_sector - start_sector_id;
                let sector_id = SectorId::from(cur_sector as u64);
                
                *sector_lock += 1;
                drop(sector_lock);
                if sector_slot >= num_sectors {
                    println!("Exiting, sector_slot {} num_sectors {}",
                             sector_slot, num_sectors);
                    break;
                }
                println!("Starting c2 sector {}", cur_sector);
                
                let commit_phase1_output = {
                    let mut commit_phase1_output_path = commit_phase1_output_base_path.clone();
                    commit_phase1_output_path.push(
                        format!("{:03}/commit-phase1-output", sector_slot)
                    );
                    println!("Restoring commit phase1 output file {:?}", commit_phase1_output_path);
                    let commit_phase1_output_bytes =
                        read(&commit_phase1_output_path).with_context(|| {
                            format!(
                                "couldn't read commit_phase1_output_path={:?}",
                                commit_phase1_output_path
                            )
                        }).unwrap();
                    
                    let res: SealCommitPhase1Output<Tree> =
                        deserialize(&commit_phase1_output_bytes).unwrap();
                    res
                };
                
                let SealCommitPhase1Output {
                    vanilla_proofs: _,
                    comm_d,
                    comm_r,
                    replica_id: _,
                    seed,
                    ticket,
                } = commit_phase1_output;
                
                println!("Starting seal_commit_phase2 sector {}", sector_slot);
                let now = Instant::now();
                let commit_output = seal_commit_phase2(
                    &porep_config,
                    commit_phase1_output,
                    prover_id,
                    sector_id
                )
                    .unwrap();
                println!("seal_commit_phase2 took: {:.2?}", now.elapsed());
                
                let result = verify_seal::<Tree>(
                    &porep_config,
                    comm_r,
                    comm_d,
                    prover_id,
                    sector_id,
                    ticket,
                    seed,
                    &commit_output.proof,
                )
                    .unwrap();
                
                if result == true {
                    println!("Verification PASSED!");
                    *successes.lock().unwrap() += 1;
                } else {
                    println!("Verification FAILED!");
                }
            }
        });
        provers.push(prover);
    }
    for prover in provers {
        prover.join().unwrap();
    }
    let count = *successes.lock().unwrap();
    count
}

#[cfg(feature = "32GiB")]
fn run_c2_32(num_sectors: usize, c1_dir: &str, start_sector_id: usize) -> usize {
    let arbitrary_porep_id = [99; 32];
    let porep_config = Arc::new(PoRepConfig::new_groth16(
        filecoin_proofs_v1::constants::SECTOR_SIZE_32_GIB,
        arbitrary_porep_id,
        ApiVersion::V1_1_0));

    run_c2::<filecoin_proofs_v1::SectorShape32GiB>(
        num_sectors,
        c1_dir,
        start_sector_id,
        porep_config,
    )
}

#[cfg(feature = "512MiB")]
fn run_c2_512(num_sectors: usize, c1_dir: &str, start_sector_id: usize) -> usize {
    let arbitrary_porep_id = [99; 32];
    let porep_config = Arc::new(PoRepConfig::new_groth16(
        filecoin_proofs_v1::constants::SECTOR_SIZE_512_MIB,
        arbitrary_porep_id,
        ApiVersion::V1_1_0));

    run_c2::<filecoin_proofs_v1::SectorShape512MiB>(
        num_sectors,
        c1_dir,
        start_sector_id,
        porep_config,
    )
}

fn main() {
    let num_sectors: usize = 128;
    //let num_sectors: usize = 64;
    //let num_sectors: usize = 32;

    let args: Vec<String> = std::env::args().collect();

    if args.len() < 2 {
        println!("Usage: c2 <cache_path> <start_sector_id>");
        std::process::exit(-1);
    }
    println!("path:         {:?}", args[1]);
    println!("start sector: {:?}", args[2]);
    let c1_dir = &args[1];
    let start_sector_id: usize = args[2].trim().parse().expect("Wanted a number");

    #[cfg(feature = "32GiB")]
    let successes = run_c2_32(num_sectors, &c1_dir, start_sector_id);
    
    #[cfg(feature = "512MiB")]
    let successes = run_c2_512(num_sectors, &c1_dir, start_sector_id);

    std::process::exit((num_sectors - successes) as i32);
}
