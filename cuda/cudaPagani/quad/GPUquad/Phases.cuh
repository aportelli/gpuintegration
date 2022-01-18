#ifndef CUDACUHRE_QUAD_GPUQUAD_PHASES_CUH
#define CUDACUHRE_QUAD_GPUQUAD_PHASES_CUH

#include "cuda/cudaPagani/quad/GPUquad/Sample.cuh"
#include "cuda/cudaPagani/quad/util/Volume.cuh"
#include <cooperative_groups.h>

#define FINAL 0
// added for variadic cuprintf
#include <stdarg.h>
#include <stdio.h>
namespace quad {

  template <typename T>
  __device__ void
  cuprintf(const char* fmt, ...)
  {
    va_list args;
    va_start(args, fmt);

    if (threadIdx.x == 0) {
      while (*fmt != '\0') {
        if (*fmt == 'd') {
          int i = va_arg(args, int);
          printf("%d\n", i);
        } else if (*fmt == 'c') {
          int c = va_arg(args, int);
          printf("%c\n", c);
        } else if (*fmt == 'f') {
          T d = va_arg(args, T);
          printf("%f\n", d);
        }
        ++fmt;
      }
    }
    va_end(args);
  }

  template <typename T>
  __device__ __host__ T
  ScaleValue(T val, T min, T max)
  {
    // assert that max > min
    T range = fabs(max - min);
    return min + val * range;
  }

  template <typename T, int NDIM>
  __global__ void
  QuickMassSample(T* dRegions,
                  T* dRegionsLength,
                  size_t numRegions,
                  Region<NDIM> sRegionPool[],
                  T* dRegionsIntegral,
                  T* dRegionsError,
                  Structures<T> constMem,
                  int FEVAL,
                  int NSETS)
  {
    T ERR = 0, RESULT = 0;
    INIT_REGION_POOL(
      dRegions, dRegionsLength, numRegions, &constMem, FEVAL, NSETS);

    if (threadIdx.x == 0) {
      dRegionsIntegral[blockIdx.x] = sRegionPool[threadIdx.x].result.avg;
      dRegionsError[blockIdx.x] = sRegionPool[threadIdx.x].result.err;
      __syncthreads();
    }
  }

  template <typename T>
  __device__ bool
  ApplyHeuristic(int heuristicID,
                 T leaves_estimate,
                 T finished_estimate,
                 T queued_estimate,
                 T lastErr,
                 T finished_errorest,
                 T queued_errorest,
                 size_t currIterRegions,
                 size_t total_nregions,
                 bool minIterReached,
                 T parErr,
                 T parRes,
                 int depth,
                 T selfRes,
                 T selfErr,
                 T epsrel,
                 T epsabs)
  {

    T GlobalErrTarget = fabs(leaves_estimate) * epsrel;
    T remainGlobalErrRoom =
      GlobalErrTarget - finished_errorest - queued_errorest;
    bool selfErrTarget = fabs(selfRes) * epsrel;

    bool worstCaseScenarioGood;

    auto ErrBiggerThanEstimateCase = [selfRes,
                                      selfErr,
                                      parRes,
                                      parErr,
                                      remainGlobalErrRoom,
                                      currIterRegions]() {
      return selfErr > fabs(selfRes) &&
             selfErr / fabs(selfRes) >= .9 * parErr / fabs(parRes) &&
             selfErr < remainGlobalErrRoom / currIterRegions;
    };

    switch (heuristicID) {
      case 0:
        worstCaseScenarioGood = false;
        break;
      case 1:
        worstCaseScenarioGood = false;
        break;
      case 2: // useless right now, same as heuristic 1
        worstCaseScenarioGood =
          ErrBiggerThanEstimateCase() ||
          (selfRes < (leaves_estimate * epsrel * depth) / (total_nregions) &&
           selfErr * currIterRegions < remainGlobalErrRoom);
        break;
      case 4:
        worstCaseScenarioGood =
          ErrBiggerThanEstimateCase() ||
          (fabs(selfRes) <
             (fabs(leaves_estimate) * epsrel * depth) / (total_nregions) &&
           selfErr * currIterRegions < GlobalErrTarget);
        break;
      case 7:
        worstCaseScenarioGood =
          (selfRes * currIterRegions + queued_estimate + finished_estimate <
             leaves_estimate &&
           selfErr * currIterRegions < GlobalErrTarget);
        break;
      case 8:
        worstCaseScenarioGood =
          selfRes < leaves_estimate / total_nregions ||
          selfErr < epsrel * leaves_estimate / total_nregions;
        break;
      case 9:
        worstCaseScenarioGood =
          selfRes < leaves_estimate / total_nregions &&
          selfErr < epsrel * leaves_estimate / total_nregions;
        break;
      case 10:
        worstCaseScenarioGood =
          fabs(selfRes) < 2 * leaves_estimate / pow(2, depth) &&
          selfErr < 2 * leaves_estimate * epsrel / pow(2, depth);
    }

    bool verdict = (worstCaseScenarioGood && minIterReached) ||
                   (selfRes == 0. && selfErr <= epsabs && minIterReached);
    return verdict;
  }

  template <typename T, int NDIM>
  __device__ void
  ActualCompute(double* generators,
                T* g,
                const Structures<double>& constMem,
                size_t feval_index,
                size_t total_feval)
  {
    for (int dim = 0; dim < NDIM; ++dim) {
      g[dim] = 0;
    }
    int posCnt = __ldg(&constMem._gpuGenPermVarStart[feval_index + 1]) -
                 __ldg(&constMem._gpuGenPermVarStart[feval_index]);
    int gIndex = __ldg(&constMem._gpuGenPermGIndex[feval_index]);

    for (int posIter = 0; posIter < posCnt; ++posIter) {
      int pos =
        (constMem
           ._gpuGenPos[(constMem._gpuGenPermVarStart[feval_index]) + posIter]);
      int absPos = abs(pos);

      if (pos == absPos) {
        g[absPos - 1] = __ldg(&constMem._gpuG[gIndex * NDIM + posIter]);
      } else {
        g[absPos - 1] = -__ldg(&constMem._gpuG[gIndex * NDIM + posIter]);
      }
    }

    for (int dim = 0; dim < NDIM; dim++) {
      generators[total_feval * dim + feval_index] = g[dim];
    }
  }

  template <typename T, int NDIM>
  __global__ void
  ComputeGenerators(double* generators,
                    size_t FEVAL,
                    const Structures<double> constMem)
  {
    size_t perm = 0;
    T g[NDIM];
    for (size_t dim = 0; dim < NDIM; ++dim) {
      g[dim] = 0;
    }

    size_t feval_index = perm * BLOCK_SIZE + threadIdx.x;
    // printf("[%i] Processing feval_index:%i\n", threadIdx.x, feval_index);
    if (feval_index < FEVAL) {
      ActualCompute<T, NDIM>(generators, g, constMem, feval_index, FEVAL);
    }
    __syncthreads();
    for (perm = 1; perm < FEVAL / BLOCK_SIZE; ++perm) {
      int feval_index = perm * BLOCK_SIZE + threadIdx.x;
      ActualCompute<T, NDIM>(generators, g, constMem, feval_index, FEVAL);
    }
    __syncthreads();
    feval_index = perm * BLOCK_SIZE + threadIdx.x;
    if (feval_index < FEVAL) {
      int feval_index = perm * BLOCK_SIZE + threadIdx.x;
      ActualCompute<T, NDIM>(generators, g, constMem, feval_index, FEVAL);
    }
    __syncthreads();
  }

  template <typename T>
  __global__ void
  RefineError(T* dRegionsIntegral,
              T* dRegionsError,
              T* dParentsIntegral,
              T* dParentsError,
              T* newErrs,
              int* activeRegions,
              size_t currIterRegions,
              T epsrel,
              int heuristicID)
  {
    // can we do anythign with the rest of the threads? maybe launch more blocks
    // instead and a  single thread per block?
    size_t tid = blockIdx.x * blockDim.x + threadIdx.x;

    if (tid < currIterRegions) {
      T selfErr = dRegionsError[tid];
      T selfRes = dRegionsIntegral[tid];

      size_t inRightSide = (2 * tid >= currIterRegions);
      size_t inLeftSide = (0 >= inRightSide);
      size_t siblingIndex = tid + (inLeftSide * currIterRegions / 2) -
                            (inRightSide * currIterRegions / 2);
      size_t parIndex = tid - inRightSide * (currIterRegions * .5);

      T siblErr = dRegionsError[siblingIndex];
      T siblRes = dRegionsIntegral[siblingIndex];

      T parRes = dParentsIntegral[parIndex];
      // T parErr = dParentsError[parIndex];

      T diff = siblRes + selfRes - parRes;
      diff = fabs(.25 * diff);

      T err = selfErr + siblErr;

      if (err > 0.0) {
        T c = 1 + 2 * diff / err;
        selfErr *= c;
      }

      selfErr += diff;

      newErrs[tid] = selfErr;
      int PassRatioTest = heuristicID != 1 &&
                          selfErr < MaxErr(selfRes, epsrel, /*epsabs*/ 1e-200);
      activeRegions[tid] = !(/*polished ||*/ PassRatioTest);
    }
  }

  __global__ void
  RevertFinishedStatus(int* activeRegions, size_t numRegions)
  {
    size_t const tid = blockIdx.x * blockDim.x + threadIdx.x;

    if (tid < numRegions) {
      activeRegions[tid] = 1;
    }
  }

  template <typename T>
  __global__ void
  Filter(T const* dRegionsError,
         int* unpolishedRegions,
         int const* activeRegions,
         size_t numRegions,
         T errThreshold)
  {
    size_t const tid = blockIdx.x * blockDim.x + threadIdx.x;

    // consider not having the ones passing the previous test
    //    (id<numRegions && activeRegions[tid] != 1)
    if (tid < numRegions) {
      T const selfErr = dRegionsError[tid];
      int const factor = (selfErr > errThreshold);
      // only "real active" regions can be polished (rename activeRegions in
      // this context to polishedRegions)
      unpolishedRegions[tid] = factor * activeRegions[tid];
    }
  }

  template <typename IntegT, typename T, int NDIM, int blockDim>
  __device__ void
  verboseINIT_REGION_POOL(IntegT* d_integrand,
                          T* dRegions,
                          T* dRegionsLength,
                          size_t numRegions,
                          const Structures<double>& constMem,
                          int FEVAL,
                          int NSETS,
                          Region<NDIM> sRegionPool[],
                          GlobalBounds sBound[],
                          T* lows,
                          T* highs,
                          int iteration,
                          int depth,
                          double* generators,
                          double* results,
                          double* funcEvals)
  {
    size_t index = blockIdx.x;
    __shared__ T Jacobian;
    __shared__ int maxDim;
    __shared__ T vol;

    __shared__ T ranges[NDIM];

    if (threadIdx.x == 0) {

      Jacobian = 1.;
      T maxRange = 0;
      for (int dim = 0; dim < NDIM; ++dim) {
        T lower = dRegions[dim * numRegions + index];
        sRegionPool[0].bounds[dim].lower = lower;
        sRegionPool[0].bounds[dim].upper =
          lower + dRegionsLength[dim * numRegions + index];

        sBound[dim].unScaledLower = lows[dim];
        sBound[dim].unScaledUpper = highs[dim];
        ranges[dim] = sBound[dim].unScaledUpper - sBound[dim].unScaledLower;
        sRegionPool[0].div = depth;

        T range = sRegionPool[0].bounds[dim].upper - lower;
        Jacobian = Jacobian * ranges[dim];
        if (range > maxRange) {
          maxDim = dim;
          maxRange = range;
        }
      }

      vol = ldexp(1., -depth);
    }

    __syncthreads();
    verboseSampleRegionBlock<IntegT, T, NDIM, blockDim>(d_integrand,
                                                        0,
                                                        constMem,
                                                        FEVAL,
                                                        NSETS,
                                                        sRegionPool,
                                                        sBound,
                                                        &vol,
                                                        &maxDim,
                                                        ranges,
                                                        &Jacobian,
                                                        generators,
                                                        iteration,
                                                        results,
                                                        funcEvals);
    __syncthreads();
  }

  template <typename IntegT, typename T, int NDIM, int blockDim>
  __device__ void
  INIT_REGION_POOL(IntegT* d_integrand,
                   T* dRegions,
                   T* dRegionsLength,
                   size_t numRegions,
                   const Structures<double>& constMem,
                   int FEVAL,
                   int NSETS,
                   Region<NDIM> sRegionPool[],
                   GlobalBounds sBound[],
                   T* lows,
                   T* highs,
                   int iteration,
                   int depth,
                   double* generators)
  {
    size_t index = blockIdx.x;
    // may not be worth pre-computing
    __shared__ T Jacobian;
    __shared__ int maxDim;
    __shared__ T vol;

    __shared__ T ranges[NDIM];

    if (threadIdx.x == 0) {

      Jacobian = 1.;
      T maxRange = 0;
      for (int dim = 0; dim < NDIM; ++dim) {
        T lower = dRegions[dim * numRegions + index];
        sRegionPool[0].bounds[dim].lower = lower;
        sRegionPool[0].bounds[dim].upper =
          lower + dRegionsLength[dim * numRegions + index];

        sBound[dim].unScaledLower = lows[dim];
        sBound[dim].unScaledUpper = highs[dim];
        ranges[dim] = sBound[dim].unScaledUpper - sBound[dim].unScaledLower;
        sRegionPool[0].div = depth;

        T range = sRegionPool[0].bounds[dim].upper - lower;
        Jacobian = Jacobian * ranges[dim];
        if (range > maxRange) {
          maxDim = dim;
          maxRange = range;
        }
      }

      vol = ldexp(1., -depth);
    }

    __syncthreads();
    SampleRegionBlock<IntegT, T, NDIM, blockDim>(d_integrand,
                                                 0,
                                                 constMem,
                                                 FEVAL,
                                                 NSETS,
                                                 sRegionPool,
                                                 sBound,
                                                 &vol,
                                                 &maxDim,
                                                 ranges,
                                                 &Jacobian,
                                                 generators,
                                                 iteration);
    __syncthreads();
  }

  template <typename IntegT, typename T, int NDIM, int blockDim>
  __global__ void
  INTEGRATE_GPU_PHASE1(IntegT* d_integrand,
                       T* dRegions,
                       T* dRegionsLength,
                       size_t numRegions,
                       T* dRegionsIntegral,
                       T* dRegionsError,
                       int* activeRegions,
                       int* subDividingDimension,
                       T epsrel,
                       T epsabs,
                       Structures<double> constMem,
                       int FEVAL,
                       int NSETS,
                       T* lows,
                       T* highs,
                       int iteration,
                       int depth,
                       double* generators)
  {
    __shared__ Region<NDIM> sRegionPool[1];
    __shared__ GlobalBounds sBound[NDIM];

    INIT_REGION_POOL<IntegT, T, NDIM, blockDim>(d_integrand,
                                                dRegions,
                                                dRegionsLength,
                                                numRegions,
                                                constMem,
                                                FEVAL,
                                                NSETS,
                                                sRegionPool,
                                                sBound,
                                                lows,
                                                highs,
                                                iteration,
                                                depth,
                                                generators);

    if (threadIdx.x == 0) {
      activeRegions[blockIdx.x] = 1;
      subDividingDimension[blockIdx.x] = sRegionPool[0].result.bisectdim;
      dRegionsIntegral[blockIdx.x] = sRegionPool[0].result.avg;
      dRegionsError[blockIdx.x] = sRegionPool[0].result.err;
    }
  }

  template <typename IntegT, typename T, int NDIM, int blockDim>
  __global__ void
  gEvaluateAtCuhrePoints(IntegT* d_integrand,
                         T* dRegions,
                         T* dRegionsLength,
                         size_t numRegions,
                         T* dRegionsIntegral,
                         T* dRegionsError,
                         int* activeRegions,
                         int* subDividingDimension,
                         T epsrel,
                         T epsabs,
                         Structures<double> constMem,
                         int FEVAL,
                         int NSETS,
                         T* lows,
                         T* highs,
                         int iteration,
                         int depth,
                         double* generators,
                         double* results,
                         double* funcEvals)
  {
    __shared__ Region<NDIM> sRegionPool[1];
    __shared__ GlobalBounds sBound[NDIM];

    verboseINIT_REGION_POOL<IntegT, T, NDIM, blockDim>(d_integrand,
                                                       dRegions,
                                                       dRegionsLength,
                                                       numRegions,
                                                       constMem,
                                                       FEVAL,
                                                       NSETS,
                                                       sRegionPool,
                                                       sBound,
                                                       lows,
                                                       highs,
                                                       iteration,
                                                       depth,
                                                       generators,
                                                       results,
                                                       funcEvals);
  }

  __device__ size_t
  GetSiblingIndex(size_t numRegions)
  {
    return (2 * blockIdx.x / numRegions) < 1 ? blockIdx.x + numRegions :
                                               blockIdx.x - numRegions;
  }
}

#endif
