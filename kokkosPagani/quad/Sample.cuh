#ifndef KOKKOSCUHRE_SAMPLE_CUH
#define KOKKOSCUHRE_SAMPLE_CUH

#include "quad.h"
#include "util/cudaApply.cuh"

template <typename T>
__device__ double
Sq(T x){
	return x * x;
}

template <typename T>
__device__ T
computeReduce(ScratchViewDouble sdata, T sum, const member_type team_member)
{    
    sdata(team_member.team_rank()) = sum;
    team_member.team_barrier();
    for (size_t offset = BLOCK_SIZE / 2; offset > 0; offset >>= 1) {
		if (team_member.team_rank() < offset) {
			sdata(team_member.team_rank()) += sdata(team_member.team_rank() + offset);
		}
		team_member.team_barrier();
    }
    return sdata(0);
}

template <typename IntegT, typename T, int NDIM>
__device__ void
computePermutation(IntegT d_integrand,
                   int pIndex,
                   Bounds* b,
                   double* g,
                   gpu::cudaArray<T, NDIM>& x,
                   double* sum,
                   Structures<T> constMem,
                   ScratchViewDouble range,
                   ScratchViewDouble jacobian,
                   constViewVectorDouble generators,
				   ScratchViewDouble sdata,
				   ScratchViewGlobalBounds sBound,
                   int FEVAL,
				   const member_type team_member){
	int threadIdx = team_member.team_rank();
    int blockIdx = team_member.league_rank();  
					   
    for (int dim = 0; dim < NDIM; ++dim) {
      x[dim] = 0;
    }
    
    int gIndex = __ldg(&constMem._gpuGenPermGIndex(pIndex));
    
    for (int dim = 0; dim < NDIM; ++dim) {
      double generator = __ldg(&generators(FEVAL*dim + pIndex));
      x[dim] = sBound(dim).unScaledLower +((.5 + generator) * b[dim].lower + (.5 - generator) * b[dim].upper)*range[dim];
    }
     
    double fun = gpu::apply(d_integrand(0), x)* (jacobian(0));
    sdata(threadIdx) = fun; // target for reduction
    
    for (int rul = 0; rul < NRULES; ++rul) {
      sum[rul] += fun * __ldg(&constMem._cRuleWt(gIndex * NRULES + rul));
    }
}
    
template<typename IntegT, int NDIM>
__device__ void
    Sample(IntegT d_integrand, 
		   int sIndex, 
		   Structures<double> constMem, 
		   int FEVAL, 
		   int NSETS, 
		   Kokkos::View<Region<NDIM>*, Kokkos::DefaultExecutionSpace::scratch_memory_space, Kokkos::MemoryTraits<Kokkos::Unmanaged> > sRegionPool,
		   ScratchViewDouble vol ,
		   ScratchViewInt maxdim,
		   ScratchViewDouble range,
		   ScratchViewDouble jacobian,
		   constViewVectorDouble generators,
		   //ScratchViewDouble sdata,
		   ScratchViewGlobalBounds sBound,
		   const member_type team_member){
	
	int threadIdx = team_member.team_rank();
    int blockIdx = team_member.league_rank();      
	    
    ScratchViewDouble sdata(team_member.team_scratch(0), BLOCK_SIZE);
	Region<NDIM>* const region = (Region<NDIM>*)&sRegionPool(sIndex);
    double errcoeff[] = {5, 1, 5};
    double g[NDIM];
    gpu::cudaArray<double, NDIM> x;
    int perm = 0;
    
    //should probably move this outside of Sample, no need for all threads to compute it
    double ratio = Sq(__ldg(&constMem._gpuG(2 * NDIM)) / __ldg(&constMem._gpuG(1 * NDIM)));
    int offset = 2 * NDIM;

    double sum[NRULES];
    Zap(sum);

    // Compute first set of permutation outside for loop to extract the Function
    // values for the permutation used to compute
    // fourth dimension
    int pIndex = perm * BLOCK_SIZE + threadIdx;

    if (pIndex < FEVAL) {
      computePermutation<IntegT, double, NDIM>(d_integrand, pIndex, region->bounds, g, x, sum, constMem, range, jacobian, generators, sdata, sBound, FEVAL, team_member);
    }

    team_member.team_barrier();
    
    if (threadIdx == 0) {
      double* f = &sdata(0);
      Result* r = &region->result; 
     
      double* f1 = f;
      double base = *f1 * 2 * (1 - ratio);
      double maxdiff = 0.;
      int bisectdim = maxdim(0);
      for (int dim = 0; dim < NDIM; ++dim) {
        double* fp = f1 + 1;
        double* fm = fp + 1;
        double fourthdiff =
          fabs(base + ratio * (fp[0] + fm[0]) - (fp[offset] + fm[offset]));
       
        f1 = fm;
        
        if (fourthdiff > maxdiff) {
          maxdiff = fourthdiff;
          bisectdim = dim;
        }
      }

      r->bisectdim = bisectdim;
    }
    team_member.team_barrier();

    for (perm = 1; perm < FEVAL / BLOCK_SIZE; ++perm) {
      int pIndex = perm * BLOCK_SIZE + threadIdx;
      computePermutation<IntegT, double, NDIM>(d_integrand, pIndex, region->bounds, g, x, sum, constMem, range, jacobian, generators, sdata, sBound, FEVAL, team_member);
    }

    pIndex = perm * BLOCK_SIZE + threadIdx;
    if (pIndex < FEVAL) {
      int pIndex = perm * BLOCK_SIZE + threadIdx;
      computePermutation<IntegT, double, NDIM>(d_integrand, pIndex, region->bounds, g, x, sum, constMem, range, jacobian, generators, sdata, sBound, FEVAL, team_member);
    }

    for (int i = 0; i < NRULES; ++i) {
		sum[i] = computeReduce(sdata, sum[i], team_member);
    }
    
    if (threadIdx == 0) {
      Result* r = &region->result;
      for (int rul = 1; rul < NRULES - 1; ++rul) {
        double maxerr = 0;
        for (int s = 0; s < NSETS; ++s) {
          maxerr = max(maxerr,
                       fabs(sum[rul + 1] +
                            __ldg(&constMem._GPUScale(s * NRULES + rul)) * sum[rul]) *
                         __ldg(&constMem._GPUNorm(s * NRULES + rul)));						
        }
        sum[rul] = maxerr;
      }
	  
      r->avg = (vol(0)) * sum[0];
      r->err = (vol(0)) * ((errcoeff[0] * sum[1] <= sum[2] &&
                       errcoeff[0] * sum[2] <= sum[3]) ?
                        errcoeff[1] * sum[1] :
                        errcoeff[2] * max(max(sum[1], sum[2]), sum[3]));
    }

}

#endif
