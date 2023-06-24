// Copyright Supranational LLC

sppark::cuda_error!();

use std::path::PathBuf;

#[repr(C)]
pub struct SRS {
    ptr: *const core::ffi::c_void,
}

impl Default for SRS {
    fn default() -> Self {
        Self {
            ptr: core::ptr::null(),
        }
    }
}

impl SRS {
    pub fn try_new(srs_path: PathBuf, cache: bool) -> Result<Self, cuda::Error> {
        extern "C" {
            fn create_SRS(
                ret: &mut SRS,
                srs_path: *const std::os::raw::c_char,
                cache: bool,
            ) -> cuda::Error;
        }
        let c_srs_path = std::ffi::CString::new(srs_path.to_str().unwrap()).unwrap();

        let mut ret = SRS::default();
        let err = unsafe { create_SRS(&mut ret, c_srs_path.as_ptr(), cache) };
        if err.code != 0 {
            Err(err)
        } else {
            Ok(ret)
        }
    }

    pub fn evict(&self) {
        extern "C" {
            fn evict_SRS(by_ref: &SRS);
        }
        unsafe { evict_SRS(self) };
    }
}

impl Drop for SRS {
    fn drop(&mut self) {
        extern "C" {
            fn drop_SRS(by_ref: &SRS);
        }
        unsafe { drop_SRS(self) };
        self.ptr = core::ptr::null();
    }
}

impl Clone for SRS {
    fn clone(&self) -> Self {
        extern "C" {
            fn clone_SRS(by_ref: &SRS) -> SRS;
        }
        unsafe { clone_SRS(self) }
    }
}

unsafe impl Sync for SRS {}
unsafe impl Send for SRS {}

#[repr(C)]
struct points_c {
    points: core::cell::Cell<Option<core::ptr::NonNull<i8>>>,
    size: usize,
    skip: usize,
    density_map: *const u64,
    total_density: usize,
}

#[repr(C)]
struct ntt_msm_h_inputs_c {
    h: core::cell::Cell<Option<core::ptr::NonNull<i8>>>,
    a: *const *const core::ffi::c_void,
    b: *const *const core::ffi::c_void,
    c: *const *const core::ffi::c_void,
    lg_domain_size: usize,
    actual_size: usize, // this value is very close to a power of 2
}

#[repr(C)]
struct msm_l_a_b_g1_b_g2_inputs_c {
    points_l: points_c,
    points_a: points_c,
    points_b_g1: points_c,
    points_b_g2: points_c,
    density_map_inp: *const u64,
    input_assignments: *const *const core::ffi::c_void,
    aux_assignments: *const *const core::ffi::c_void,
    input_assignment_size: usize,
    aux_assignment_size: usize,
}

extern "C" {
    fn generate_groth16_proof_c(
        ntt_msm_h_inputs: &ntt_msm_h_inputs_c,
        msm_l_a_b_g1_b_g2_inputs: &msm_l_a_b_g1_b_g2_inputs_c,
        num_circuits: usize,
        r_s: *const core::ffi::c_void,
        s_s: *const core::ffi::c_void,
        proofs: *mut core::ffi::c_void,
        srs: &SRS,
    ) -> cuda::Error;
}

pub fn generate_groth16_proof<S, D, PR>(
    ntt_a_scalars: &[*const S],
    ntt_b_scalars: &[*const S],
    ntt_c_scalars: &[*const S],
    ntt_scalars_actual_size: usize,
    input_assignments: &[*const S],
    aux_assignments: &[*const S],
    input_assignments_size: usize,
    aux_assignments_size: usize,
    a_aux_density_bv: &[D],
    b_g1_input_density_bv: &[D],
    b_g1_aux_density_bv: &[D],
    a_aux_total_density: usize,
    b_g1_input_total_density: usize,
    b_g1_aux_total_density: usize,
    num_circuits: usize,
    r_s: &[S],
    s_s: &[S],
    proofs: &mut [PR],
    srs: &SRS,
) {
    let lg_domain_size = (std::mem::size_of_val(&ntt_scalars_actual_size) * 8)
        - (ntt_scalars_actual_size - 1).leading_zeros() as usize;

    assert_eq!(ntt_a_scalars.len(), num_circuits);
    assert_eq!(ntt_b_scalars.len(), num_circuits);
    assert_eq!(ntt_c_scalars.len(), num_circuits);
    assert_eq!(input_assignments.len(), num_circuits);
    assert_eq!(aux_assignments.len(), num_circuits);
    assert_eq!(r_s.len(), num_circuits);
    assert_eq!(s_s.len(), num_circuits);
    assert_eq!(proofs.len(), num_circuits);

    let bv_element_size: usize = std::mem::size_of::<D>() * 8; // length of D in bits
    assert!(
        bv_element_size == 64,
        "only 64-bit elements in bit vectors are supported"
    );

    assert!(a_aux_density_bv.len() * bv_element_size >= aux_assignments_size);
    assert!(b_g1_aux_density_bv.len() * bv_element_size >= aux_assignments_size);

    let ntt_msm_h_inputs = ntt_msm_h_inputs_c {
        h: None.into(),
        a: ntt_a_scalars.as_ptr() as *const *const _,
        b: ntt_b_scalars.as_ptr() as *const *const _,
        c: ntt_c_scalars.as_ptr() as *const *const _,
        lg_domain_size: lg_domain_size,
        actual_size: ntt_scalars_actual_size,
    };

    let points_l = points_c {
        points: None.into(),
        size: aux_assignments_size,
        skip: 0usize,
        density_map: std::ptr::null() as *const _, // l always has FullDensity
        total_density: aux_assignments_size,
    };

    let points_a = points_c {
        points: None.into(),
        size: a_aux_total_density + input_assignments_size,
        skip: input_assignments_size,
        density_map: a_aux_density_bv.as_ptr() as *const _,
        total_density: a_aux_total_density,
    };

    let points_b_g1 = points_c {
        points: None.into(),
        size: b_g1_aux_total_density + b_g1_input_total_density,
        skip: b_g1_input_total_density,
        density_map: b_g1_aux_density_bv.as_ptr() as *const _,
        total_density: b_g1_aux_total_density,
    };

    let points_b_g2 = points_c {
        points: None.into(),
        size: b_g1_aux_total_density + b_g1_input_total_density,
        skip: b_g1_input_total_density,
        density_map: b_g1_aux_density_bv.as_ptr() as *const _,
        total_density: b_g1_aux_total_density,
    };

    let msm_l_a_b_g1_b_g2_inputs = msm_l_a_b_g1_b_g2_inputs_c {
        points_l: points_l,
        points_a: points_a,
        points_b_g1: points_b_g1,
        points_b_g2: points_b_g2,
        density_map_inp: b_g1_input_density_bv.as_ptr() as *const _,
        input_assignments: input_assignments.as_ptr() as *const *const _,
        aux_assignments: aux_assignments.as_ptr() as *const *const _,
        input_assignment_size: input_assignments_size,
        aux_assignment_size: aux_assignments_size,
    };

    let err = unsafe {
        generate_groth16_proof_c(
            &ntt_msm_h_inputs,
            &msm_l_a_b_g1_b_g2_inputs,
            num_circuits,
            r_s.as_ptr() as *const core::ffi::c_void,
            s_s.as_ptr() as *const core::ffi::c_void,
            proofs.as_mut_ptr() as *mut core::ffi::c_void,
            srs,
        )
    };

    if err.code != 0 {
        panic!("{}", String::from(err));
    }
}

#[repr(C)]
pub struct Assignment<Scalar> {
    // Density of queries
    pub a_aux_density: *const usize,
    pub a_aux_bit_len: usize,
    pub a_aux_popcount: usize,

    pub b_inp_density: *const usize,
    pub b_inp_bit_len: usize,
    pub b_inp_popcount: usize,

    pub b_aux_density: *const usize,
    pub b_aux_bit_len: usize,
    pub b_aux_popcount: usize,

    // Evaluations of A, B, C polynomials
    pub a: *const Scalar,
    pub b: *const Scalar,
    pub c: *const Scalar,
    pub abc_size: usize,

    // Assignments of variables
    pub inp_assignment_data: *const Scalar,
    pub inp_assignment_size: usize,

    pub aux_assignment_data: *const Scalar,
    pub aux_assignment_size: usize,
}

extern "C" {
    fn generate_groth16_proofs_c(
        provers: *const core::ffi::c_void,
        num_circuits: usize,
        r_s: *const core::ffi::c_void,
        s_s: *const core::ffi::c_void,
        proofs: *mut core::ffi::c_void,
        srs: &SRS,
    ) -> cuda::Error;
}

pub fn generate_groth16_proofs<S, PR>(
    provers: &[Assignment<S>],
    r_s: &[S],
    s_s: &[S],
    proofs: &mut [PR],
    srs: &SRS,
) {
    let num_circuits = provers.len();

    assert_eq!(r_s.len(), num_circuits);
    assert_eq!(s_s.len(), num_circuits);
    assert_eq!(proofs.len(), num_circuits);

    let err = unsafe {
        generate_groth16_proofs_c(
            provers.as_ptr() as *const _,
            num_circuits,
            r_s.as_ptr() as *const _,
            s_s.as_ptr() as *const _,
            proofs.as_mut_ptr() as *mut _,
            srs,
        )
    };

    if err.code != 0 {
        panic!("{}", String::from(err));
    }
}
