# Commit 2

The final step of the sealing process is to generate a zkSNARK for the proof of replication (porep). Using the inclusion proofs from C1, the inputs are put through the porep circuit and a proof generated using Groth16.

## Intended Usage

The SupraSeal C2 operations are different than the rest of the library in that there are dependencies on primitives in external libraries. Specifically with bellperson through the use of a modified version of synthesize_circuits_batch() to generate the witness. From there the vectors are put through various MSM and NTT kernels on GPU and CPU. Note this requires the usage of a Rust based interface as opposed to the C/C++ seen throughout SupraSeal.

The use of bellperson currently complicates matters since the library needs to be modified slightly in order to run with the SupraSeal Groth16 primitives. For the time being see instructions below for making the modifications. There is a test in the rust directory that demonstrates usage.

## Steps to Compile and Run Test Example

1. Clone version `0.25.0` of [bellperson](https://github.com/filecoin-project/bellperson/tree/v0.25.0) into this directory: `git clone https://github.com/filecoin-project/bellperson.git -b v0.25.0`
2. Navigate into bellperson `cd bellperson`
3. Apply `bellperson-0.25.0.patch` to bellperson: `git apply ../bellperson-0.25.0.patch`
4. Navigate back `cd ..`
5. Run the test: `cargo test --release --test c2 -- --nocapture`
6. The expected C2 runtime is approximately 2-3 minutes depending on GPU
