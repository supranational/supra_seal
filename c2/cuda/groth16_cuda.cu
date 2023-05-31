// Copyright Supranational LLC

#include <iostream>
#include <thread>
#include <vector>

#if defined(FEATURE_BLS12_381)
# include <ff/bls12-381-fp2.hpp>
#else
# error "only FEATURE_BLS12_381 is supported"
#endif

#include <ec/jacobian_t.hpp>
#include <ec/xyzz_t.hpp>

typedef jacobian_t<fp_t> point_t;
typedef xyzz_t<fp_t> bucket_t;
typedef bucket_t::affine_t affine_t;

typedef jacobian_t<fp2_t> point_fp2_t;
typedef xyzz_t<fp2_t> bucket_fp2_t;
typedef bucket_fp2_t::affine_t affine_fp2_t;

typedef fr_t scalar_t;

#include <msm/pippenger.cuh>
#include <msm/pippenger.hpp>

#include "groth16_ntt_h.cu"
#include "groth16_split_msm.cu"

template<class point_t, class affine_t>
static void mult(point_t& ret, const affine_t point, const scalar_t& fr,
                 size_t top = scalar_t::nbits)
{
    scalar_t::pow_t scalar;
    fr.to_scalar(scalar);

    mult(ret, point, scalar, top);
}

static thread_pool_t groth16_pool;

struct msm_results {
    std::vector<point_t> h;
    std::vector<point_t> l;
    std::vector<point_t> a;
    std::vector<point_t> b_g1;
    std::vector<point_fp2_t> b_g2;

    msm_results(size_t num_circuits) : h(num_circuits),
                                       l(num_circuits),
                                       a(num_circuits),
                                       b_g1(num_circuits),
                                       b_g2(num_circuits) {}
};

struct groth16_proof {
    point_t::affine_t a;
    point_fp2_t::affine_t b;
    point_t::affine_t c;
};

#ifndef __CUDA_ARCH__

#include "groth16_srs.cuh"

extern "C"
RustError generate_groth16_proof_c(ntt_msm_h_inputs_c& ntt_msm_h_inputs,
    msm_l_a_b_g1_b_g2_inputs_c& msm_l_a_b_g1_b_g2_inputs, size_t num_circuits,
    const fr_t r_s[], const fr_t s_s[], groth16_proof proofs[], SRS& srs)
{
    const verifying_key* vk = &srs.get_vk();

    ntt_msm_h_inputs.points_h = srs.get_h().data();
    msm_l_a_b_g1_b_g2_inputs.points_l.points = srs.get_l().data();
    msm_l_a_b_g1_b_g2_inputs.points_a.points = srs.get_a().data();
    msm_l_a_b_g1_b_g2_inputs.points_b_g1.points = srs.get_b_g1().data();
    msm_l_a_b_g1_b_g2_inputs.points_b_g2.points = srs.get_b_g2().data();

    const points_c<affine_t>& points_l = msm_l_a_b_g1_b_g2_inputs.points_l;
    const points_c<affine_t>& points_a = msm_l_a_b_g1_b_g2_inputs.points_a;
    const points_c<affine_t>& points_b_g1 = msm_l_a_b_g1_b_g2_inputs.points_b_g1;
    const points_c<affine_fp2_t>& points_b_g2 = msm_l_a_b_g1_b_g2_inputs.points_b_g2;

    split_vectors split_vectors_l{num_circuits, points_l.size};
    split_vectors split_vectors_a{num_circuits, points_a.size - points_a.skip};
    split_vectors split_vectors_b{num_circuits, points_b_g1.size - points_b_g1.skip};

    std::vector<affine_t> tail_msm_l_bases,
                          tail_msm_a_bases,
                          tail_msm_b_g1_bases;
    std::vector<affine_fp2_t> tail_msm_b_g2_bases;

    msm_results results{num_circuits};

    semaphore_t barrier;
    std::atomic<bool> caught_exception{false};
    size_t n_gpus = std::min(ngpus(), num_circuits);

    std::thread prep_msm_thread([&, num_circuits]
    {
#if 1   // minimize reference passing
        const points_c<affine_t>& points_l = msm_l_a_b_g1_b_g2_inputs.points_l;
        const points_c<affine_t>& points_a = msm_l_a_b_g1_b_g2_inputs.points_a;
        const points_c<affine_t>& points_b_g1 = msm_l_a_b_g1_b_g2_inputs.points_b_g1;
        const points_c<affine_fp2_t>& points_b_g2 = msm_l_a_b_g1_b_g2_inputs.points_b_g2;
#endif
        const fr_t** input_assignments = msm_l_a_b_g1_b_g2_inputs.input_assignments;
        const fr_t** aux_assignments = msm_l_a_b_g1_b_g2_inputs.aux_assignments;

        size_t input_assignment_size = msm_l_a_b_g1_b_g2_inputs.input_assignment_size;
        size_t aux_assignment_size = msm_l_a_b_g1_b_g2_inputs.aux_assignment_size;

        // pre-processing step
        const fr_t* input_assignment0 = input_assignments[0];
        const fr_t* aux_assignment0 = aux_assignments[0];

        size_t l_counter = 0,
               a_counter = points_a.skip,
               b_counter = points_b_g1.skip;

        for (size_t i = 0; i < aux_assignment_size; i += chunk_bits) {
            uint64_t a_chunk = points_a.density_map[i / chunk_bits];
            uint64_t b_chunk = points_b_g1.density_map[i / chunk_bits];

            for (size_t j = 0; j < chunk_bits; j++) {
                if (i + j >= aux_assignment_size) break;

                const fr_t& scalar = aux_assignment0[i + j];

                bool a_dense = a_chunk & 1;
                bool b_g1_dense = b_chunk & 1;

                if (!scalar.is_zero() && !scalar.is_one()) {
                    l_counter++;
                    if (a_dense)
                        a_counter++;
                    if (b_g1_dense)
                        b_counter++;
                }

                a_chunk >>= 1;
                b_chunk >>= 1;
            }
        }
        // end of pre-processing step

        if (caught_exception)
            return;

        split_vectors_l.tail_msms_resize(l_counter);
        split_vectors_a.tail_msms_resize(a_counter);
        split_vectors_b.tail_msms_resize(b_counter);

        tail_msm_l_bases.resize(l_counter);
        tail_msm_a_bases.resize(a_counter);
        tail_msm_b_g1_bases.resize(b_counter);
        tail_msm_b_g2_bases.resize(b_counter);

        groth16_pool.par_map(num_circuits, [&](size_t c) {
            uint64_t bit_vector_a_chunk = 0, bit_vector_b_chunk = 0;
            size_t a_chunk_counter = 0, b_chunk_counter = 0;
            size_t a_chunk_cursor = 0, b_chunk_cursor = 0;

            uint32_t points_a_cursor = 0, points_b_cursor = 0;
            size_t l_meaningful_scalars_counter = 0;
            size_t a_meaningful_scalars_counter = 0;
            size_t b_meaningful_scalars_counter = 0;

            for (size_t i = 0; i < input_assignment_size; i++) {
                const fr_t& scalar = input_assignments[c][i];

                if (i < points_a.skip) {
                    if (c == 0)
                        split_vectors_a.tail_msm_indices[a_meaningful_scalars_counter] = points_a_cursor;
                    split_vectors_a.tail_msm_scalars[c][a_meaningful_scalars_counter] = scalar;

                    a_meaningful_scalars_counter++;
                    points_a_cursor++;
                }

                if (i < points_b_g1.skip) {
                    if (c == 0)
                        split_vectors_b.tail_msm_indices[b_meaningful_scalars_counter] = points_b_cursor;
                    split_vectors_b.tail_msm_scalars[c][b_meaningful_scalars_counter] = scalar;

                    b_meaningful_scalars_counter++;
                    points_b_cursor++;
                }
            }

            if (caught_exception)
                return;

            for (size_t i = 0; i < aux_assignment_size; i += chunk_bits) {

                uint64_t a_chunk = points_a.density_map[i / chunk_bits];
                uint64_t b_chunk = points_b_g1.density_map[i / chunk_bits];

                uint64_t bit_vector_l_chunk = 0;

                for (size_t j = 0; j < chunk_bits; j++) {
                    if (i + j >= aux_assignment_size) break;

                    const fr_t& scalar = aux_assignments[c][i + j];

                    bool a_dense = a_chunk & 1;
                    bool b_g1_dense = b_chunk & 1;

                    if (scalar.is_one()) {
                        bit_vector_l_chunk |= ((uint64_t)1 << j);
                    }
                    else if (!scalar.is_zero()) {
                        if (c == 0)
                            split_vectors_l.tail_msm_indices[l_meaningful_scalars_counter] = (uint32_t)(i + j);
                        split_vectors_l.tail_msm_scalars[c][l_meaningful_scalars_counter] = scalar;

                        l_meaningful_scalars_counter++;
                    }

                    if (a_dense) {
                        if (scalar.is_one()) {
                            bit_vector_a_chunk |= ((uint64_t)1 << a_chunk_counter);
                        }
                        else if (!scalar.is_zero()) {
                            if (c == 0)
                                split_vectors_a.tail_msm_indices[a_meaningful_scalars_counter] = points_a_cursor;
                            split_vectors_a.tail_msm_scalars[c][a_meaningful_scalars_counter] = scalar;

                            a_meaningful_scalars_counter++;
                        }

                        a_chunk_counter++;
                        points_a_cursor++;
                    }

                    if (b_g1_dense) {
                        if (scalar.is_one()) {
                            bit_vector_b_chunk |= ((uint64_t)1 << b_chunk_counter);
                        }
                        else if (!scalar.is_zero()) {
                            if (c == 0)
                                split_vectors_b.tail_msm_indices[b_meaningful_scalars_counter] = points_b_cursor;
                            split_vectors_b.tail_msm_scalars[c][b_meaningful_scalars_counter] = scalar;

                            b_meaningful_scalars_counter++;
                        }

                        b_chunk_counter++;
                        points_b_cursor++;
                    }

                    if (a_chunk_counter == chunk_bits) {
                        split_vectors_a.bit_vector[c][a_chunk_cursor] = bit_vector_a_chunk;
                        a_chunk_counter = 0;
                        bit_vector_a_chunk = 0;
                        a_chunk_cursor++;
                    }

                    if (b_chunk_counter == chunk_bits) {
                        split_vectors_b.bit_vector[c][b_chunk_cursor] = bit_vector_b_chunk;
                        b_chunk_counter = 0;
                        bit_vector_b_chunk = 0;
                        b_chunk_cursor++;
                    }

                    a_chunk >>= 1;
                    b_chunk >>= 1;
                }

                split_vectors_l.bit_vector[c][i / chunk_bits] = bit_vector_l_chunk;
            }
        });

        if (caught_exception)
            return;

        for (size_t i = 0; i < l_counter; i++)
            tail_msm_l_bases[i] = points_l[split_vectors_l.tail_msm_indices[i]];

        for (size_t i = 0; i < a_counter; i++)
            tail_msm_a_bases[i] = points_a[split_vectors_a.tail_msm_indices[i]];

        for (size_t i = 0; i < b_counter; i++) {
            tail_msm_b_g1_bases[i] = points_b_g1[split_vectors_b.tail_msm_indices[i]];
            tail_msm_b_g2_bases[i] = points_b_g2[split_vectors_b.tail_msm_indices[i]];
        }

        for (size_t i = 0; i < n_gpus; i++)
            barrier.notify();

        if (caught_exception)
            return;

        // tail MSM b_g2 - on CPU
        for (size_t c = 0; c < num_circuits; c++) {
            mult_pippenger<bucket_fp2_t>(results.b_g2[c],
                tail_msm_b_g2_bases, split_vectors_b.tail_msm_scalars[c],
                true, &groth16_pool);

            if (caught_exception)
                return;
        }
    });

    batch_add_results batch_add_res{num_circuits};
    std::vector<std::thread> per_gpu;
    RustError ret{cudaSuccess};

    for (size_t tid = 0; tid < n_gpus; tid++) {
        per_gpu.emplace_back(std::thread([&, tid, n_gpus](size_t num_circuits)
        {
#if 1   // minimize reference passing
            const points_c<affine_t>& points_l = msm_l_a_b_g1_b_g2_inputs.points_l;
            const points_c<affine_t>& points_a = msm_l_a_b_g1_b_g2_inputs.points_a;
            const points_c<affine_t>& points_b_g1 = msm_l_a_b_g1_b_g2_inputs.points_b_g1;
            const points_c<affine_fp2_t>& points_b_g2 = msm_l_a_b_g1_b_g2_inputs.points_b_g2;
#endif
            const gpu_t& gpu = select_gpu(tid);

            size_t rem = num_circuits % n_gpus;
            num_circuits /= n_gpus;
            num_circuits += tid < rem;
            size_t circuit0 = tid * num_circuits;
            if (tid >= rem)
                circuit0 += rem;

            try {
                {
                    size_t d_a_sz = sizeof(fr_t) << ntt_msm_h_inputs.lg_domain_size;
                    gpu_ptr_t<fr_t> d_a{(scalar_t*)gpu.Dmalloc(d_a_sz)};

                    for (size_t c = 0; c < num_circuits; c++) {
                        ntt_msm_h::execute_ntt_msm_h(gpu, d_a, ntt_msm_h_inputs,
                                                     circuit0 + c, &results.h[0]);
                        if (caught_exception)
                            return;
                    }
                }

                barrier.wait();

                if (caught_exception)
                    return;

                // batch addition L - on GPU
                execute_batch_addition<bucket_t>(gpu, circuit0, num_circuits,
                                                 points_l, split_vectors_l,
                                                 &batch_add_res.l[circuit0]);
                if (caught_exception)
                    return;

                // batch addition a - on GPU
                execute_batch_addition<bucket_t>(gpu, circuit0, num_circuits,
                                                 points_a, split_vectors_a,
                                                 &batch_add_res.a[circuit0]);
                if (caught_exception)
                    return;

                // batch addition b_g1 - on GPU
                execute_batch_addition<bucket_t>(gpu, circuit0, num_circuits,
                                                 points_b_g1, split_vectors_b,
                                                 &batch_add_res.b_g1[circuit0]);
                if (caught_exception)
                    return;

                // batch addition b_g2 - on GPU
                execute_batch_addition<bucket_fp2_t>(gpu, circuit0, num_circuits,
                                                     points_b_g2, split_vectors_b,
                                                     &batch_add_res.b_g2[circuit0]);
                if (caught_exception)
                    return;

                {
                    msm_t<bucket_t, point_t, affine_t, scalar_t> msm{nullptr,
                        tail_msm_l_bases.size()};

                    for (size_t c = circuit0; c < circuit0+num_circuits; c++) {
                        // tail MSM l - on GPU
                        msm.invoke(results.l[c], tail_msm_l_bases,
                                   split_vectors_l.tail_msm_scalars[c], true);
                        if (caught_exception)
                            return;

                        // tail MSM a - on GPU
                        msm.invoke(results.a[c], tail_msm_a_bases,
                                   split_vectors_a.tail_msm_scalars[c], true);
                        if (caught_exception)
                            return;

                        // tail MSM b_g1 - on GPU
                        msm.invoke(results.b_g1[c], tail_msm_b_g1_bases,
                                   split_vectors_b.tail_msm_scalars[c], true);
                        if (caught_exception)
                            return;
                    }
                }
            } catch (const cuda_error& e) {
                bool already = caught_exception.exchange(true);
                if (!already) {
                    for (size_t i = 1; i < n_gpus; i++)
                        barrier.notify();
#ifdef TAKE_RESPONSIBILITY_FOR_ERROR_MESSAGE
                    ret = RustError{e.code(), e.what()};
#else
                    ret = RustError{e.code()};
#endif
                }
                gpu.sync();
            }
        }, num_circuits));
    }

    prep_msm_thread.join();
    for (auto& tid : per_gpu)
        tid.join();

    if (caught_exception)
        return ret;

    for (size_t circuit = 0; circuit < num_circuits; circuit++) {
        results.l[circuit].add(batch_add_res.l[circuit]);
        results.a[circuit].add(batch_add_res.a[circuit]);
        results.b_g1[circuit].add(batch_add_res.b_g1[circuit]);
        results.b_g2[circuit].add(batch_add_res.b_g2[circuit]);

        fr_t r = r_s[circuit], s = s_s[circuit];
        fr_t rs = r * s;
        // we want the scalars to be in Montomery form when passing them to
        // "mult" routine

        point_t g_a, g_c, a_answer, b1_answer, vk_delta_g1_rs, vk_alpha_g1_s,
                vk_beta_g1_r;
        point_fp2_t g_b;

        mult(vk_delta_g1_rs, vk->delta_g1, rs);
        mult(vk_alpha_g1_s, vk->alpha_g1, s);
        mult(vk_beta_g1_r, vk->beta_g1, r);

        mult(b1_answer, results.b_g1[circuit], r);

        // A
        mult(g_a, vk->delta_g1, r);
        g_a.add(vk->alpha_g1);
        g_a.add(results.a[circuit]);

        // B
        mult(g_b, vk->delta_g2, s);
        g_b.add(vk->beta_g2);
        g_b.add(results.b_g2[circuit]);

        // C
        mult(g_c, results.a[circuit], s);
        g_c.add(b1_answer);
        g_c.add(vk_delta_g1_rs);
        g_c.add(vk_alpha_g1_s);
        g_c.add(vk_beta_g1_r);
        g_c.add(results.h[circuit]);
        g_c.add(results.l[circuit]);

        // to affine
        proofs[circuit].a = g_a;
        proofs[circuit].b = g_b;
        proofs[circuit].c = g_c;
    }

    return ret;
}

#endif
