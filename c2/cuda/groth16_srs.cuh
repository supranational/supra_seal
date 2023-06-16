// Copyright Supranational LLC

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#include <map>

#include <util/thread_pool_t.hpp>

struct verifying_key {
    affine_t alpha_g1;
    affine_t beta_g1;
    affine_fp2_t beta_g2;
    affine_fp2_t gamma_g2;
    affine_t delta_g1;
    affine_fp2_t delta_g2;
};

extern "C" {
    int blst_p1_deserialize(affine_t*, const byte[96]);
    int blst_p2_deserialize(affine_fp2_t*, const byte[192]);
}

class SRS;

class SRS {
private:
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
    class SRS_internal {
        friend class SRS;

    private:
        static const int max_num_circuits = 10;

        static size_t get_num_threads() {
            int total_threads = groth16_pool.size();

            // Assume that the CPU supports hyperthreading to be on the safe
            // side and ensure that there are at least max_num_circuits number
            // of physical cores left available if the SRS is going to be read
            // concurrently with synthesis
            // If there are not enough physical cores, just use all of them
            // and read it.
            return (total_threads / 2 - max_num_circuits) < max_num_circuits ?
                   (size_t)total_threads / 2 :
                   (size_t)total_threads / 2 - max_num_circuits;
        }

        // size of p1 affine and p2 affine points in the SRS file in bytes
        static const size_t p1_affine_size = 96;
        static const size_t p2_affine_size = 192;

        // 3 p1 affine and 3 p2 affine points are in the verification key. 864 bytes
        static const size_t vk_offset = p1_affine_size * 3 + p2_affine_size * 3;

        // the number of points for each of h, l, a, b_g1 and b_g2 are stored as
        // a big-endian uint32_t in the SRS file
        static const size_t four_bytes = 4;

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

        static inline void read_g1_point(affine_t* point, const byte* srs_ptr) {
            blst_p1_deserialize(point, srs_ptr);
        }

        static inline void read_g2_point(affine_fp2_t* point, const byte* srs_ptr) {
            blst_p2_deserialize(point, srs_ptr);
        }

        static void read_g1_points(affine_t* points, const byte* srs_ptr,
                                   uint32_t num_points)
        {
            size_t batch_size = get_batch_size(num_points, get_num_threads());

            const byte (*srs)[p1_affine_size] =
                reinterpret_cast<decltype(srs)>(srs_ptr);

            groth16_pool.par_map(num_points, batch_size, [&](size_t i) {
                read_g1_point(&points[i], srs[i]);
            }, get_num_threads());
        }

        static void read_g2_points(affine_fp2_t* points, const byte* srs_ptr,
                                   uint32_t num_points)
        {
            size_t batch_size = get_batch_size(num_points, get_num_threads());

            const byte (*srs)[p2_affine_size] =
                reinterpret_cast<decltype(srs)>(srs_ptr);

            groth16_pool.par_map(num_points, batch_size, [&](size_t i) {
                read_g2_point(&points[i], srs[i]);
            }, get_num_threads());
        }

        srs_data data_h, data_l, data_a, data_b_g1, data_b_g2;

        std::thread read_th;
        mutable std::mutex mtx;

    public:
        std::string path;
        verifying_key vk;
        affine_t* h, * l, * a, * b_g1;
        affine_fp2_t* b_g2;

        SRS_internal(SRS_internal const&)   = delete;
        void operator=(SRS_internal const&) = delete;

    private:
        void read(size_t file_size, const byte* srs_ptr, semaphore_t* barrier)
        {
           std::lock_guard<std::mutex> guard(mtx);
            barrier->notify();

            read_g1_point(&vk.alpha_g1, srs_ptr + 0);
            read_g1_point(&vk.beta_g1, srs_ptr + p1_affine_size);
            read_g2_point(&vk.beta_g2, srs_ptr + 2 * p1_affine_size);
            read_g2_point(&vk.gamma_g2, srs_ptr + 2 * p1_affine_size +
                                                      p2_affine_size);
            read_g1_point(&vk.delta_g1, srs_ptr + 2 * p1_affine_size +
                                                  2 * p2_affine_size);
            read_g2_point(&vk.delta_g2, srs_ptr + 3 * p1_affine_size +
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

            cudaHostAlloc(&h, data_h.size * sizeof(affine_t), cudaHostAllocMapped);
            cudaHostAlloc(&l, data_l.size * sizeof(affine_t), cudaHostAllocMapped);
            cudaHostAlloc(&a, data_a.size * sizeof(affine_t), cudaHostAllocMapped);
            cudaHostAlloc(&b_g1, data_b_g1.size * sizeof(affine_t), cudaHostAllocMapped);
            cudaHostAlloc(&b_g2, data_b_g2.size * sizeof(affine_fp2_t), cudaHostAllocMapped);

            read_g1_points(&h[0], srs_ptr + data_h.off, data_h.size);
            read_g1_points(&l[0], srs_ptr + data_l.off, data_l.size);
            read_g1_points(&a[0], srs_ptr + data_a.off, data_a.size);
            read_g1_points(&b_g1[0], srs_ptr + data_b_g1.off, data_b_g1.size);
            read_g2_points(&b_g2[0], srs_ptr + data_b_g2.off, data_b_g2.size);

            munmap(const_cast<byte*>(srs_ptr), file_size);
        }

    public:
        SRS_internal(const char* srs_path) : path(srs_path) {
            int srs_file = open(srs_path, O_RDONLY);

            struct stat st;
            fstat(srs_file, &st);
            size_t file_size = st.st_size;

            const byte* srs_ptr = (const byte*)mmap(NULL, file_size, PROT_READ,
                                                    MAP_PRIVATE, srs_file, 0);
            close(srs_file);

            semaphore_t barrier;
            read_th = std::thread{[=, &barrier] { read(file_size, srs_ptr, &barrier); }};
            barrier.wait();
        }
        ~SRS_internal() {
            if (read_th.joinable())
                read_th.join();
            if (h)
                cudaFreeHost(h);
            if (l)
                cudaFreeHost(l);
            if (a)
                cudaFreeHost(a);
            if (b_g1)
                cudaFreeHost(b_g1);
            if (b_g2)
                cudaFreeHost(b_g2);
        }
    };

public:
    struct inner {
        const SRS_internal srs;
        std::atomic<size_t> ref_cnt;
        inline inner(const char* srs_path) : srs(srs_path), ref_cnt(1) {}
    };
    inner* ptr = nullptr;
    inline static std::map<std::string, inner*> srs_cache;

public:
    SRS(const char* srs_path) { ptr = new inner(srs_path); }
    SRS(const SRS& r)   { *this = r; }
    ~SRS() {
        if (ptr && ptr->ref_cnt.fetch_sub(1, std::memory_order_seq_cst) == 1) {
            srs_cache.erase(ptr->srs.path);
            delete ptr;
        }
    }

    SRS& operator=(const SRS& r) {
        if (this != &r)
            (ptr = r.ptr)->ref_cnt.fetch_add(1, std::memory_order_relaxed);
        return *this;
    }

    SRS& operator=(SRS&& r) noexcept {
        if (this != &r) {
            ptr = r.ptr;
            r.ptr = nullptr;
        }
        return *this;
    }

    const verifying_key& get_vk() const {
        std::lock_guard<std::mutex> guard(ptr->srs.mtx);
        return ptr->srs.vk;
    }

    const affine_t* get_h() const {
        std::lock_guard<std::mutex> guard(ptr->srs.mtx);
        return ptr->srs.h;
    }

    const affine_t* get_l() const {
        std::lock_guard<std::mutex> guard(ptr->srs.mtx);
        return ptr->srs.l;
    }

    const affine_t* get_a() const {
        std::lock_guard<std::mutex> guard(ptr->srs.mtx);
        return ptr->srs.a;
    }

    const affine_t* get_b_g1() const {
        std::lock_guard<std::mutex> guard(ptr->srs.mtx);
        return ptr->srs.b_g1;
    }

    const affine_fp2_t* get_b_g2() const {
        std::lock_guard<std::mutex> guard(ptr->srs.mtx);
        return ptr->srs.b_g2;
    }

    const std::string& get_path() const {
        return ptr->srs.path;
    }

    // facilitate return by value through FFI, as SRS::by_value.
    struct by_value { inner *ptr; };
    operator by_value() const {
        ptr->ref_cnt.fetch_add(1, std::memory_order_relaxed);
        return {ptr};
    }
    SRS(by_value v) { ptr = v.ptr; }
};

extern "C" SRS::by_value create_SRS(const char* srs_path) {
    std::string path(srs_path);

    if (SRS::srs_cache.find(path) == SRS::srs_cache.end()) {
        SRS srs{srs_path};
        SRS::srs_cache[path] = srs.ptr;
        return srs;
    }
    else {
        SRS::inner* ptr = SRS::srs_cache[path];
        ptr->ref_cnt.fetch_add(1, std::memory_order_relaxed);
        return SRS::by_value{ptr};
    }
}

extern "C" void drop_SRS(SRS& ref) {
    ref.~SRS();
}

extern "C" SRS::by_value clone_SRS(const SRS& rhs) {
    return rhs;
}
