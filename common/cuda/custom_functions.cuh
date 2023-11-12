#ifndef QUAD_UTIL_CUDA_CUSTOM_FUNCTIONS_CUH
#define QUAD_UTIL_CUDA_CUSTOM_FUNCTIONS_CUH

#include <iostream>
#include <limits>
#include <cuda.h>
#include "cuda/pagani/quad/GPUquad/Sample.cuh"
#include "common/cuda/cudaDebugUtil.h"
#include "common/cuda/cudaMemoryUtil.h"

/*
        require blocks to be equal to size
*/

template <typename T>
__global__ void
device_custom_reduce(T* arr, size_t size, T* out)
{
  T sum = 0.;
  // reduce multiple elements per thread
  const int tid = blockIdx.x * blockDim.x + threadIdx.x;
  const int total_num_threads = blockDim.x * gridDim.x;

  for (size_t i = tid; i < size; i += total_num_threads) {
    sum += arr[i];
  }

  sum = quad::blockReduceSum(sum);

  if (threadIdx.x == 0)
    out[blockIdx.x] = sum;
}

template <typename T>
T
custom_reduce(T* arr, size_t size)
{
  size_t num_threads = 512;
  size_t max_num_blocks = 1024;
  size_t num_blocks =
    min((size + num_threads - 1) / num_threads, max_num_blocks);
  T* out = quad::cuda_malloc<T>(num_blocks);

  device_custom_reduce<<<num_blocks, num_threads>>>(arr, size, out);
  device_custom_reduce<<<1, 1024>>>(out, num_blocks, out);
  cudaFree(out);
}

template <typename T>
__global__ void
device_custom_reduce_atomics(T* arr, size_t size, T* out)
{
  T sum = 0.;
  // reduce multiple elements per thread
  const int tid = blockIdx.x * blockDim.x + threadIdx.x;
  const int total_num_threads = blockDim.x * gridDim.x;

  for (size_t i = tid; i < size; i += total_num_threads) {
    sum += arr[i];
  }

  sum = quad::warpReduceSum(sum);
  const int warpSize = 32;
  if ((threadIdx.x & (warpSize - 1)) == 0) {
    atomicAdd(out, sum);
  }
}

template <typename T>
T
custom_reduce_atomics(T* arr, size_t size)
{
  T res = 0.;
  size_t num_threads = 512;
  size_t max_num_blocks = 1024;
  size_t num_blocks =
    min((size + num_threads - 1) / num_threads, max_num_blocks);
  T* out = quad::cuda_malloc<T>(1);
  quad::cuda_memcpy_to_device<T>(out, &res, 1);

  quad::cuda_memcpy_to_device<T>(out, &res, 1);
  device_custom_reduce_atomics<<<num_blocks, num_threads>>>(arr, size, out);

  quad::cuda_memcpy_to_host<T>(&res, out, 1);
  cudaFree(out);
  return res;
}

template <typename T1, typename T2>
__global__ void
device_custom_inner_product_atomics(T1* arr1, T2* arr2, size_t size, T2* out)
{
  T2 sum = 0.;
  // reduce multiple elements per thread
  const int tid = blockIdx.x * blockDim.x + threadIdx.x;
  const int total_num_threads = blockDim.x * gridDim.x;

  for (size_t i = tid; i < size; i += total_num_threads) {
    sum += arr1[i] * arr2[i];
  }

  sum = quad::warpReduceSum(sum);
  __syncthreads();
  const int warpSize = 32;
  if ((threadIdx.x & (warpSize - 1)) == 0) {
    atomicAdd(out, sum);
  }
}

template <typename T1, typename T2>
T2
custom_inner_product_atomics(T1* arr1, T2* arr2, size_t size)
{
  T2 res = 0.;
  size_t num_threads = 512;
  size_t max_num_blocks = 1024;
  size_t num_blocks =
    min((size + num_threads - 1) / num_threads, max_num_blocks);
  T2* out = quad::cuda_malloc<T2>(1);
  quad::cuda_memcpy_to_device<T2>(out, &res, 1);
  device_custom_inner_product_atomics<T1, T2>
    <<<num_blocks, num_threads>>>(arr1, arr2, size, out);
  quad::cuda_memcpy_to_host<T2>(&res, out, 1);
  cudaFree(out);
  return res;
}

template <typename T>
__inline__ __device__ T
warpReduceMax(T val)
{
  const unsigned int FULL_MASK = 0xffffffff;

  for (int mask = warpSize / 2; mask > 0; mask /= 2) {
    val = max(__shfl_xor_sync(FULL_MASK, val, mask), val);
  }

  return val;
}

template <typename T>
__inline__ __device__ T
warpReduceMin(T val)
{
  const unsigned int FULL_MASK = 0xffffffff;

  for (int mask = warpSize / 2; mask > 0; mask /= 2) {
    val = min(__shfl_xor_sync(FULL_MASK, val, mask), val);
  }

  return val;
}

template <typename T>
__device__ void
blockReduceMinMax(T& min, T& max)
{
  static __shared__ T shared_max[32];
  static __shared__ T shared_min[32];

  int lane = threadIdx.x % 32; // 32 is for warp size
  int wid = threadIdx.x >> 5 /* threadIdx.x / 32  */;

  min = warpReduceMin(min);
  max = warpReduceMax(max);

  if (lane == 0) {
    shared_min[wid] = min;
    shared_max[wid] = max;
    // printf("all warps blockReduceMinMax [%i](%i) min:%f\n", blockIdx.x,
    // threadIdx.x, min);
  }
  __syncthreads(); // Wait for all partial reductions

  // read from shared memory only if that warp existed
  min = (threadIdx.x < (blockDim.x >> 5)) ? shared_min[lane] : std::numeric_limits<T>::max();
  max = (threadIdx.x < (blockDim.x >> 5)) ? shared_max[lane] : 0;

  if (wid == 0) {
    min = warpReduceMin(min);
    max = warpReduceMax(max);
  }
}

template <typename T>
__global__ void
blocks_min_max(const T* __restrict__ input, const int size, T* min, T* max)
{
  const int tid = blockIdx.x * blockDim.x + threadIdx.x;
  const int total_num_threads = blockDim.x * gridDim.x;

  T localMax = 0;
  T localMin = std::numeric_limits<T>::max();

  for (size_t i = tid; i < size; i += total_num_threads) {
    T val = input[tid];

    if (localMax < val) {
      localMax = val;
    }

    if (localMin > val) {
      localMin = val;
      // printf("new min for [%i](%i):%f\n", blockIdx.x, threadIdx.x, localMin);
    }
  }

  blockReduceMinMax(localMin, localMax);

  if (threadIdx.x == 0) {
    max[blockIdx.x] = localMax;
    min[blockIdx.x] = localMin;
    // printf("block reduction stage [%i] :%f,%f\n", blockIdx.x, localMax,
    // localMin);
  }
}

template <typename T>
__global__ void
block0_min_max(T* mins, T* maxs, const int size, T* min, T* max)
{
  const int tid = threadIdx.x;

  T localMax = tid < size ? maxs[tid] : 0;
  T localMin = tid < size ? mins[tid] : std::numeric_limits<T>::max();

  blockReduceMinMax(localMin, localMax);

  if (threadIdx.x == 0) {
    max[blockIdx.x] = localMax;
    min[blockIdx.x] = localMin;
    // printf("reducing the block results [%i] :%f,%f\n", blockIdx.x, localMax,
    // localMin);
  }
}

template <typename T>
std::pair<T, T>
min_max(T* input, const int size)
{
  size_t num_threads = 1024;
  size_t max_num_blocks = 1024;
  size_t num_blocks =
    min((size + num_threads - 1) / num_threads, max_num_blocks);

  T* block_mins = quad::cuda_malloc<T>(num_blocks);
  T* block_maxs = quad::cuda_malloc<T>(num_blocks);
  T* d_min = quad::cuda_malloc<T>(1);
  T* d_max = quad::cuda_malloc<T>(1);

  blocks_min_max<T>
    <<<num_blocks, num_threads>>>(input, size, block_mins, block_maxs);
  block0_min_max<T><<<1, std::max(num_blocks, (size_t)32)>>>(
    block_mins, block_maxs, num_blocks, d_min, d_max);

  cudaDeviceSynchronize();

  T min = 0.;
  T max = 0.;

  quad::cuda_memcpy_to_host(&min, d_min, 1);
  quad::cuda_memcpy_to_host(&max, d_max, 1);

  cudaFree(block_mins);
  cudaFree(block_maxs);
  cudaFree(d_min);
  cudaFree(d_max);
  return {min, max};
}

template<typename T>
__global__ void
gpu_sum_scan_blelloch(T* const d_out,
                      const T* const d_in,
                      T* const d_block_sums,
                      const size_t numElems)
{
  extern __shared__ int s_out[];

  // Zero out shared memory
  // Especially important when padding shmem for
  //  non-power of 2 sized input
  // s_out[2 * threadIdx.x] = 0;
  // s_out[2 * threadIdx.x + 1] = 0;
  s_out[threadIdx.x] = 0;
  s_out[threadIdx.x + blockDim.x] = 0;

  __syncthreads();

  //}
  unsigned int cpy_idx = 2 * blockIdx.x * blockDim.x + threadIdx.x;
  if (cpy_idx < numElems) {
    s_out[threadIdx.x] = d_in[cpy_idx];
    if (cpy_idx + blockDim.x < numElems)
      s_out[threadIdx.x + blockDim.x] = d_in[cpy_idx + blockDim.x];
  }

  __syncthreads();

  // Reduce/Upsweep step

  // 2^11 = 2048, the max amount of data a block can blelloch scan
  unsigned int max_steps = 11;

  unsigned int r_idx = 0;
  unsigned int l_idx = 0;
  int sum = 0; // global sum can be passed to host if needed
  unsigned int t_active = 0;
  for (int s = 0; s < max_steps; ++s) {
    t_active = 0;

    // calculate necessary indexes
    // right index must be (t+1) * 2^(s+1)) - 1
    r_idx = ((threadIdx.x + 1) * (1 << (s + 1))) - 1;
    if (/*r_idx >= 0 &&*/ r_idx < 2048)
      t_active = 1;

    if (t_active) {
      // left index must be r_idx - 2^s
      l_idx = r_idx - (1 << s);

      // do the actual add operation
      sum = s_out[l_idx] + s_out[r_idx];
    }
    __syncthreads();

    if (t_active)
      s_out[r_idx] = sum;
    __syncthreads();
  }

  // Copy last element (total sum of block) to block sums array
  // Then, reset last element to operation's identity (sum, 0)
  if (threadIdx.x == 0) {
    d_block_sums[blockIdx.x] = s_out[r_idx];
    s_out[r_idx] = 0;
  }

  __syncthreads();

  // Downsweep step

  for (int s = max_steps - 1; s >= 0; --s) {
    // calculate necessary indexes
    // right index must be (t+1) * 2^(s+1)) - 1
    r_idx = ((threadIdx.x + 1) * (1 << (s + 1))) - 1;
    if (/*r_idx >= 0 &&*/ r_idx < 2048) {
      t_active = 1;
    }

    unsigned int r_cpy = 0;
    unsigned int lr_sum = 0;
    if (t_active) {
      // left index must be r_idx - 2^s
      l_idx = r_idx - (1 << s);

      // do the downsweep operation
      r_cpy = s_out[r_idx];
      lr_sum = s_out[l_idx] + s_out[r_idx];
    }
    __syncthreads();

    if (t_active) {
      s_out[l_idx] = r_cpy;
      s_out[r_idx] = lr_sum;
    }
    __syncthreads();
  }

  // Copy the results to global memory
  // if (2 * glbl_tid < numElems)
  //{
  //	d_out[2 * glbl_tid] = s_out[2 * threadIdx.x];
  //	if (2 * glbl_tid + 1 < numElems)
  //		d_out[2 * glbl_tid + 1] = s_out[2 * threadIdx.x + 1];
  //}
  if (cpy_idx < numElems) {
    d_out[cpy_idx] = s_out[threadIdx.x];
    if (cpy_idx + blockDim.x < numElems)
      d_out[cpy_idx + blockDim.x] = s_out[threadIdx.x + blockDim.x];
  }
}

template<typename T>
__global__ void
gpu_add_block_sums(T* const d_out,
                   const T* const d_in,
                   T* const d_block_sums,
                   const size_t numElems)
{
  // unsigned int glbl_t_idx = blockDim.x * blockIdx.x + threadIdx.x;
  unsigned int d_block_sum_val = d_block_sums[blockIdx.x];

  // unsigned int d_in_val_0 = 0;
  // unsigned int d_in_val_1 = 0;

  // Simple implementation's performance is not significantly (if at all)
  //  better than previous verbose implementation
  unsigned int cpy_idx = 2 * blockIdx.x * blockDim.x + threadIdx.x;
  if (cpy_idx < numElems) {
    d_out[cpy_idx] = d_in[cpy_idx] + d_block_sum_val;
    if (cpy_idx + blockDim.x < numElems)
      d_out[cpy_idx + blockDim.x] =
        d_in[cpy_idx + blockDim.x] + d_block_sum_val;
  }

  // if (2 * glbl_t_idx < numElems)
  //{
  //	d_out[2 * glbl_t_idx] = d_in[2 * glbl_t_idx] + d_block_sum_val;
  //	if (2 * glbl_t_idx + 1 < numElems)
  //		d_out[2 * glbl_t_idx + 1] = d_in[2 * glbl_t_idx + 1] +
  // d_block_sum_val;
  // }

  // if (2 * glbl_t_idx < numElems)
  //{
  //	d_in_val_0 = d_in[2 * glbl_t_idx];
  //	if (2 * glbl_t_idx + 1 < numElems)
  //		d_in_val_1 = d_in[2 * glbl_t_idx + 1];
  // }
  // else
  //	return;
  //__syncthreads();

  // d_out[2 * glbl_t_idx] = d_in_val_0 + d_block_sum_val;
  // if (2 * glbl_t_idx + 1 < numElems)
  //	d_out[2 * glbl_t_idx + 1] = d_in_val_1 + d_block_sum_val;
}

// Modified version of Mark Harris' implementation of the Blelloch scan
//  according to https://www.mimuw.edu.pl/~ps209291/kgkp/slides/scan.pdf
// this macro is only used for prefix scan

#ifdef ZERO_BANK_CONFLICTS
#define CONFLICT_FREE_OFFSET(n) ((n) >> NUM_BANKS + (n) >> (2 * LOG_NUM_BANKS))
#else
#define CONFLICT_FREE_OFFSET(n) ((n) >> LOG_NUM_BANKS)
#endif

#define MAX_BLOCK_SZ 1024
#define NUM_BANKS 32
#define LOG_NUM_BANKS 5

template<typename T>
__global__ void
gpu_prescan(T* const d_out,
            const T* const d_in,
            T* const d_block_sums,
            const unsigned int len,
            const unsigned int shmem_sz,
            const unsigned int max_elems_per_block)
{
  // Allocated on invocation
  extern __shared__ T s_out[];

  int thid = threadIdx.x;
  int ai = thid;
  int bi = thid + blockDim.x;

  // Zero out the shared memory
  // Helpful especially when input size is not power of two
  s_out[thid] = 0;
  s_out[thid + blockDim.x] = 0;
  // If CONFLICT_FREE_OFFSET is used, shared memory
  //  must be a few more than 2 * blockDim.x
  if (thid + max_elems_per_block < shmem_sz)
    s_out[thid + max_elems_per_block] = 0;

  __syncthreads();

  // Copy d_in to shared memory
  // Note that d_in's elements are scattered into shared memory
  //  in light of avoiding bank conflicts
  unsigned int cpy_idx = max_elems_per_block * blockIdx.x + threadIdx.x;
  if (cpy_idx < len) {
    s_out[ai + CONFLICT_FREE_OFFSET(ai)] = d_in[cpy_idx];
    if (cpy_idx + blockDim.x < len)
      s_out[bi + CONFLICT_FREE_OFFSET(bi)] = d_in[cpy_idx + blockDim.x];
  }

  // For both upsweep and downsweep:
  // Sequential indices with conflict free padding
  //  Amount of padding = target index / num banks
  //  This "shifts" the target indices by one every multiple
  //   of the num banks
  // offset controls the stride and starting index of
  //  target elems at every iteration
  // d just controls which threads are active
  // Sweeps are pivoted on the last element of shared memory

  // Upsweep/Reduce step
  int offset = 1;
  for (int d = max_elems_per_block >> 1; d > 0; d >>= 1) {
    __syncthreads();

    if (thid < d) {
      int ai = offset * ((thid << 1) + 1) - 1;
      int bi = offset * ((thid << 1) + 2) - 1;
      ai += CONFLICT_FREE_OFFSET(ai);
      bi += CONFLICT_FREE_OFFSET(bi);

      s_out[bi] += s_out[ai];
    }
    offset <<= 1;
  }

  // Save the total sum on the global block sums array
  // Then clear the last element on the shared memory
  if (thid == 0) {
    d_block_sums[blockIdx.x] =
      s_out[max_elems_per_block - 1 +
            CONFLICT_FREE_OFFSET(max_elems_per_block - 1)];
    s_out[max_elems_per_block - 1 +
          CONFLICT_FREE_OFFSET(max_elems_per_block - 1)] = 0;
  }

  // Downsweep step
  for (int d = 1; d < max_elems_per_block; d <<= 1) {
    offset >>= 1;
    __syncthreads();

    if (thid < d) {
      int ai = offset * ((thid << 1) + 1) - 1;
      int bi = offset * ((thid << 1) + 2) - 1;
      ai += CONFLICT_FREE_OFFSET(ai);
      bi += CONFLICT_FREE_OFFSET(bi);

      int temp = s_out[ai];
      s_out[ai] = s_out[bi];
      s_out[bi] += temp;
    }
  }
  __syncthreads();

  // Copy contents of shared memory to global memory
  if (cpy_idx < len) {
    d_out[cpy_idx] = s_out[ai + CONFLICT_FREE_OFFSET(ai)];
    if (cpy_idx + blockDim.x < len)
      d_out[cpy_idx + blockDim.x] = s_out[bi + CONFLICT_FREE_OFFSET(bi)];
  }
}

template<typename T>
void
sum_scan_blelloch(T* const d_out,
                  const T* const d_in,
                  const size_t numElems)
{
  // Zero out d_out
  (cudaMemset(d_out, 0, numElems * sizeof(T)));

  // Set up number of threads and blocks

  unsigned int block_sz = MAX_BLOCK_SZ / 2;
  unsigned int max_elems_per_block =
    2 * block_sz; // due to binary tree nature of algorithm

  // If input size is not power of two, the remainder will still need a whole
  // block Thus, number of blocks must be the ceiling of input size / max elems
  // that a block can handle
  // unsigned int grid_sz = (unsigned int) std::ceil((double) numElems /
  // (double) max_elems_per_block);
  // UPDATE: Instead of using ceiling and risking miscalculation due to
  // precision, just automatically
  //  add 1 to the grid size when the input size cannot be divided cleanly by
  //  the block's capacity
  unsigned int grid_sz = numElems / max_elems_per_block;
  // Take advantage of the fact that integer division drops the decimals
  if (numElems % max_elems_per_block != 0)
    grid_sz += 1;

  // Conflict free padding requires that shared memory be more than 2 * block_sz
  unsigned int shmem_sz =
    max_elems_per_block + ((max_elems_per_block - 1) >> LOG_NUM_BANKS);

  // Allocate memory for array of total sums produced by each block
  // Array length must be the same as number of blocks
  T* d_block_sums;
  (cudaMalloc(&d_block_sums, sizeof(T) * grid_sz));
  (cudaMemset(d_block_sums, 0, sizeof(T) * grid_sz));

  // Sum scan data allocated to each block
  // gpu_sum_scan_blelloch<<<grid_sz, block_sz, sizeof(unsigned int) *
  // max_elems_per_block >>>(d_out, d_in, d_block_sums, numElems);
  gpu_prescan<<<grid_sz, block_sz, sizeof(T) * shmem_sz>>>(
    d_out, d_in, d_block_sums, numElems, shmem_sz, max_elems_per_block);

  // Sum scan total sums produced by each block
  // Use basic implementation if number of total sums is <= 2 * block_sz
  //  (This requires only one block to do the scan)
  if (grid_sz <= max_elems_per_block) {
    T* d_dummy_blocks_sums;
    (cudaMalloc(&d_dummy_blocks_sums, sizeof(T)));
    (cudaMemset(d_dummy_blocks_sums, 0, sizeof(T)));
    // gpu_sum_scan_blelloch<<<1, block_sz, sizeof(unsigned int) *
    // max_elems_per_block>>>(d_block_sums, d_block_sums, d_dummy_blocks_sums,
    // grid_sz);
    gpu_prescan<<<1, block_sz, sizeof(T) * shmem_sz>>>(d_block_sums,
                                                         d_block_sums,
                                                         d_dummy_blocks_sums,
                                                         grid_sz,
                                                         shmem_sz,
                                                         max_elems_per_block);
    (cudaFree(d_dummy_blocks_sums));
  }
  // Else, recurse on this same function as you'll need the full-blown scan
  //  for the block sums
  else {
    T* d_in_block_sums;
    (cudaMalloc(&d_in_block_sums, sizeof(T) * grid_sz));
    (cudaMemcpy(d_in_block_sums,
                d_block_sums,
                sizeof(T) * grid_sz,
                cudaMemcpyDeviceToDevice));
    sum_scan_blelloch(d_block_sums, d_in_block_sums, grid_sz);
    (cudaFree(d_in_block_sums));
  }

  //// Uncomment to examine block sums
  // unsigned int* h_block_sums = new unsigned int[grid_sz];
  //(cudaMemcpy(h_block_sums, d_block_sums, sizeof(unsigned int) * grid_sz,
  // cudaMemcpyDeviceToHost)); std::cout << "Block sums: "; for (int i = 0; i <
  // grid_sz; ++i)
  //{
  //	std::cout << h_block_sums[i] << ", ";
  // }
  // std::cout << std::endl;
  // std::cout << "Block sums length: " << grid_sz << std::endl;
  // delete[] h_block_sums;

  // Add each block's total sum to its scan output
  // in order to get the final, global scanned array
  gpu_add_block_sums<<<grid_sz, block_sz>>>(
    d_out, d_out, d_block_sums, numElems);

  (cudaFree(d_block_sums));
}

#endif
