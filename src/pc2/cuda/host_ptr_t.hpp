// Copyright Supranational LLC

#ifndef __HOST_PTR_T_HPP__
#define __HOST_PTR_T_HPP__

// A simple way to allocate a host pointer without having to
// care about freeing it.
template<typename T> class host_ptr_t {
  T* h_ptr;
public:
  host_ptr_t(size_t nelems) : h_ptr(nullptr)
  {
    if (nelems) {
      CUDA_OK(cudaMallocHost(&h_ptr, nelems * sizeof(T)));
    }
  }
  ~host_ptr_t() { if (h_ptr) cudaFreeHost((void*)h_ptr); }

  inline operator const T*() const            { return h_ptr; }
  inline operator T*() const                  { return h_ptr; }
  inline operator void*() const               { return (void*)h_ptr; }
  inline const T& operator[](size_t i) const  { return h_ptr[i]; }
  inline T& operator[](size_t i)              { return h_ptr[i]; }
};

#endif
