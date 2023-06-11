// Copyright Supranational LLC

#include <msm/batch_addition.cuh>

template __global__
void batch_addition<bucket_t>(bucket_t::mem_t ret_[],
                              const affine_t::mem_t points_[], uint32_t npoints,
                              const uint32_t bitmap[], bool accumulate,
                              uint32_t sid);

template __global__
void batch_addition<bucket_fp2_t>(bucket_fp2_t::mem_t ret_[],
                                  const affine_fp2_t::mem_t points_[],
                                  uint32_t npoints, const uint32_t bitmap[],
                                  bool accumulate, uint32_t sid);

template<class affine_t>
struct points_c {
    mutable const affine_t* points;
    size_t size;
    size_t skip;
    const uint64_t* density_map;
    size_t total_density;

    inline const affine_t& operator[](size_t i) const { return points[i]; }
};

struct msm_l_a_b_g1_b_g2_inputs_c {
    points_c<affine_t> points_l, points_a, points_b_g1;
    points_c<affine_fp2_t> points_b_g2;
    const fr_t** input_assignments, ** aux_assignments;
    size_t input_assignment_size, aux_assignment_size;
};

struct batch_add_results {
    std::vector<point_t> l;
    std::vector<point_t> a;
    std::vector<point_t> b_g1;
    std::vector<point_fp2_t> b_g2;

    batch_add_results(size_t num_circuits) : l(num_circuits),
                                             a(num_circuits),
                                             b_g1(num_circuits),
                                             b_g2(num_circuits) { }
};

const size_t CHUNK_BITS = sizeof(uint64_t) * 8; // 64 bits

#define NUM_BATCHES 8
#define GPU_DIV (32*WARP_SZ)

class split_vectors {
public:
    std::vector<std::vector<uint64_t>> bit_vector;
    std::vector<std::vector<fr_t>>     tail_msm_scalars;
    size_t batch_size, bit_vector_size;

    split_vectors(size_t num_circuits, size_t num_points)
        :   bit_vector{num_circuits},
            tail_msm_scalars{num_circuits}
    {
        batch_size = (num_points + GPU_DIV - 1) / GPU_DIV;
        batch_size = (batch_size + NUM_BATCHES - 1) / NUM_BATCHES;
        batch_size *= GPU_DIV;

        bit_vector_size = (num_points + CHUNK_BITS - 1) / CHUNK_BITS;

        for (size_t c = 0; c < num_circuits; c++) {
            bit_vector[c].resize(bit_vector_size);
        }
    }

    void tail_msms_resize(size_t num_sig_scalars) {
        size_t num_circuits = tail_msm_scalars.size();
        for (size_t c = 0; c < num_circuits; c++) {
            tail_msm_scalars[c].resize(num_sig_scalars);
        }
    }
};

template<class bucket_t,
         class point_t,
         class bucket_h = class bucket_t::mem_t,
         class affine_t = class bucket_t::affine_t,
         class affine_h = class bucket_t::affine_t::mem_t>
void execute_batch_addition(const gpu_t& gpu,
                            size_t curcuit0, size_t num_circuits,
                            const points_c<affine_t>& points,
                            const split_vectors& split_vector,
                            point_t batch_add_res[])
{
    int sm_count = gpu.sm_count();

    uint32_t nbuckets = sm_count * BATCH_ADD_BLOCK_SIZE / WARP_SZ;

    uint32_t bit_vector_size = (2 * split_vector.bit_vector[0].size() + WARP_SZ - 1) & (0u - WARP_SZ);
    size_t batch_size = split_vector.batch_size;

    size_t d_points_size = batch_size * 2 * sizeof(affine_h);
    size_t d_buckets_size = num_circuits * nbuckets * sizeof(bucket_h);

    dev_ptr_t<byte> d_temp{d_points_size + d_buckets_size +
                           num_circuits * bit_vector_size * sizeof(uint32_t)};

    assert(batch_size == (uint32_t)batch_size);

    vec2d_t<affine_h> d_points{&d_temp[0], (uint32_t)batch_size};
    vec2d_t<bucket_h> d_buckets{&d_temp[d_points_size], nbuckets};
    vec2d_t<uint32_t> d_bit_vectors{&d_temp[d_points_size + d_buckets_size],
                                    bit_vector_size};

    uint32_t sid = 0;

    for (size_t c = 0; c < num_circuits; c++)
        gpu[sid].HtoD(d_bit_vectors[c],
                      split_vector.bit_vector[curcuit0 + c].data(),
                      split_vector.bit_vector[curcuit0 + c].size() * 2);

    size_t remaining_points = points.size - points.skip;

    for (uint32_t batch = 0; remaining_points > 0; batch++, sid ^= 1) {
        uint32_t amount = std::min(remaining_points, batch_size);
        size_t cursor = batch * batch_size;

        gpu[sid].HtoD(d_points[sid], &points[cursor + points.skip], amount);

        for (size_t c = 0; c < num_circuits; c++)
            gpu[sid].launch_coop(batch_addition<bucket_t>,
                {sm_count, BATCH_ADD_BLOCK_SIZE},
                d_buckets[c], (const affine_h*)d_points[sid], amount,
                (const uint32_t*)&d_bit_vectors[c][cursor / 32],
                batch > 0, sid);

        remaining_points -= amount;
    }
    sid ^= 1;

    vec2d_t<bucket_t> buckets{nbuckets, num_circuits};
    gpu[sid].DtoH(buckets[0], d_buckets[0], num_circuits * nbuckets);
    gpu[sid].sync();

    gpu.par_map(num_circuits, 1, [&, batch_add_res, nbuckets](size_t c) {
        batch_add_res[c] = sum_up(buckets[c], nbuckets);
    });
}
