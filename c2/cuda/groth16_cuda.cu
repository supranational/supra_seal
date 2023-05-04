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

struct verifying_key {
    affine_t alpha_g1;
    affine_t beta_g1;
    affine_fp2_t beta_g2;
    affine_fp2_t gamma_g2;
    affine_t delta_g1;
    affine_fp2_t delta_g2;
};

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

extern "C" {
    int blst_p1_deserialize(affine_t*, const byte[96]);
    int blst_p2_deserialize(affine_fp2_t*, const byte[192]);
}

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// This class assumes that the SRS files used by filecoin have a specific file
// layout and assumes some properties of data types that are present in the file
//
// There are 3 data types in the file:
//     4-byte   big-endian unsigned integer,
//     92-byte  BLS12-381 P1 affine point,
//     192-byte BLS12-381 P2 affine point
//
// The layout of the file is as such, in order, without any padding:
//
// alpha_g1: g1 affine
// beta_g1 : g1 affine
// beta_g2 : g2 affine
// gamma_g2: g2 affine
// delta_g1: g1 affine
// delta_g2: g2 affine
// number of ic points: 4-byte big-endian unsigned integer
// ic points: g1 affines
// number of h points: 4-byte big-endian unsigned integer
// h points: g1 affines
// number of l points: 4-byte big-endian unsigned integer
// l points: g1 affines
// number of a points: 4-byte big-endian unsigned integer
// a points: g1 affines
// number of b_g1 points: 4-byte big-endian unsigned integer
// b_g1 points: g1 affines
// number of b_g2 points: 4-byte big-endian unsigned integer
// b_g2 points: g2 affines
class SRS {
private:
    // size of p1 affine and p2 affine points in the SRS file in bytes
    static const size_t p1_affine_size = 96;
    static const size_t p2_affine_size = 192;

    // 3 p1 affine and 3 p2 affine points are in the verification key. 864 bytes
    static const size_t vk_offset = p1_affine_size * 3 + p2_affine_size * 3;

    // the number of points for each of h, l, a, b_g1 and b_g2 are stored as
    // a big-endian uint32_t in the SRS file
    static const size_t four_bytes = 4;

    bool currently_initialized = false;

    struct srs_data {
        uint32_t size = 0;
        size_t off = 0; // in bytes
    };

    template<typename T>
    static T from_big_endian(const unsigned char* ptr) {
        T res = ptr[0];
        for (size_t i = 1; i < sizeof(T); i++) {
            res <<= 8;
            res |= ptr[i];
        }

        return res;
    }

    static size_t get_batch_size(uint32_t num_points, size_t num_threads) {
        size_t batch_size = (num_points + num_threads - 1) / num_threads;
        batch_size = (batch_size + 64 - 1) / 64;
        return batch_size;
    }

    void read_g1_points(affine_t* points, const byte* srs_ptr,
                        uint32_t num_points = 1)
    {
        size_t batch_size = get_batch_size(num_points, groth16_pool.size());

        const byte (*srs)[p1_affine_size] =
            reinterpret_cast<decltype(srs)>(srs_ptr);

        groth16_pool.par_map(num_points, batch_size, [&](size_t i) {
            blst_p1_deserialize(&points[i], srs[i]);
        });
    }

    void read_g2_points(affine_fp2_t* points, const byte* srs_ptr,
                        uint32_t num_points = 1)
    {
        size_t batch_size = get_batch_size(num_points, groth16_pool.size());

        const byte (*srs)[p2_affine_size] =
            reinterpret_cast<decltype(srs)>(srs_ptr);

        groth16_pool.par_map(num_points, batch_size, [&](size_t i) {
            blst_p2_deserialize(&points[i], srs[i]);
        });
    }

    srs_data data_h, data_l, data_a, data_b_g1, data_b_g2;

    SRS() {}

public:
    static SRS& get_instance() {
        static SRS instance;
        return instance;
    }

    SRS(SRS const&)            = delete;
    void operator=(SRS const&) = delete;

    verifying_key vk;
    std::vector<affine_t> h, l, a, b_g1;
    std::vector<affine_fp2_t> b_g2;

    // in case one wants to deallocate before program's end
    void reset() {
        if (!currently_initialized)
            return;

        h = std::vector<affine_t>();
        l = std::vector<affine_t>();
        a = std::vector<affine_t>();
        b_g1 = std::vector<affine_t>();
        b_g2 = std::vector<affine_fp2_t>();

        currently_initialized = false;
    }

    void read(const char* srs_path) {
        if (currently_initialized)
            reset();

        int srs_file = open(srs_path, O_RDONLY);

        struct stat st;
        fstat(srs_file, &st);
        size_t file_size = st.st_size;

        const byte* srs_ptr = (const byte*)mmap(NULL, file_size, PROT_READ,
                                                MAP_PRIVATE, srs_file, 0);
        close(srs_file);

        read_g1_points(&vk.alpha_g1, srs_ptr + 0);
        read_g1_points(&vk.beta_g1, srs_ptr + p1_affine_size);
        read_g2_points(&vk.beta_g2, srs_ptr + 2 * p1_affine_size);
        read_g2_points(&vk.gamma_g2, srs_ptr + 2 * p1_affine_size +
                                                   p2_affine_size);
        read_g1_points(&vk.delta_g1, srs_ptr + 2 * p1_affine_size +
                                               2 * p2_affine_size);
        read_g2_points(&vk.delta_g2, srs_ptr + 3 * p1_affine_size +
                                               2 * p2_affine_size);

        uint32_t vk_ic_size = from_big_endian<uint32_t>(srs_ptr + vk_offset);

        data_h.size = from_big_endian<uint32_t>(srs_ptr + vk_offset +
                                                four_bytes +
                                                vk_ic_size * p1_affine_size);
        data_h.off = vk_offset + four_bytes + vk_ic_size * p1_affine_size +
                     four_bytes;

        data_l.size = from_big_endian<uint32_t>(srs_ptr + data_h.off +
                                                data_h.size * p1_affine_size);
        data_l.off = data_h.off + data_h.size * p1_affine_size + four_bytes;

        data_a.size = from_big_endian<uint32_t>(srs_ptr + data_l.off +
                                                data_l.size * p1_affine_size);
        data_a.off = data_l.off + data_l.size * p1_affine_size + four_bytes;

        data_b_g1.size = from_big_endian<uint32_t>(srs_ptr + data_a.off +
                                                   data_a.size *
                                                   p1_affine_size);
        data_b_g1.off = data_a.off + data_a.size * p1_affine_size + four_bytes;

        data_b_g2.size = from_big_endian<uint32_t>(srs_ptr + data_b_g1.off +
                                                   data_b_g1.size *
                                                   p1_affine_size);
        data_b_g2.off = data_b_g1.off + data_b_g1.size * p1_affine_size +
                        four_bytes;

        h.resize(data_h.size);
        l.resize(data_l.size);
        a.resize(data_a.size);
        b_g1.resize(data_b_g1.size);
        b_g2.resize(data_b_g2.size);

        read_g1_points(&h[0], srs_ptr + data_h.off, data_h.size);
        read_g1_points(&l[0], srs_ptr + data_l.off, data_l.size);
        read_g1_points(&a[0], srs_ptr + data_a.off, data_a.size);
        read_g1_points(&b_g1[0], srs_ptr + data_b_g1.off, data_b_g1.size);
        read_g2_points(&b_g2[0], srs_ptr + data_b_g2.off, data_b_g2.size);

        munmap(const_cast<byte*>(srs_ptr), file_size);

        currently_initialized = true;
    }
};

extern "C"
void read_srs_c(const char* srs_path) {
    SRS::get_instance().read(srs_path);
}

extern "C"
void reset_srs_c() {
    SRS::get_instance().reset();
}

extern "C"
RustError generate_groth16_proof_c(ntt_msm_h_inputs_c& ntt_msm_h_inputs,
    msm_l_a_b_g1_b_g2_inputs_c& msm_l_a_b_g1_b_g2_inputs, size_t num_circuits,
    const fr_t r_s[], const fr_t s_s[], groth16_proof proofs[])
{
    SRS& srs = SRS::get_instance();
    verifying_key* vk = &srs.vk;

    ntt_msm_h_inputs.points_h = &srs.h[0];
    msm_l_a_b_g1_b_g2_inputs.points_l.points = &srs.l[0];
    msm_l_a_b_g1_b_g2_inputs.points_a.points = &srs.a[0];
    msm_l_a_b_g1_b_g2_inputs.points_b_g1.points = &srs.b_g1[0];
    msm_l_a_b_g1_b_g2_inputs.points_b_g2.points = &srs.b_g2[0];

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
