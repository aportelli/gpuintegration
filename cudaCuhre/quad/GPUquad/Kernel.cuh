#ifndef CUDACUHRE_QUAD_GPUQUAD_KERNEL_CUH
#define CUDACUHRE_QUAD_GPUQUAD_KERNEL_CUH

#include "../util/Volume.cuh"
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>

#include "Phases.cuh"
#include "Rule.cuh"

#include <cuda.h>
#include <fstream>
#include <iomanip>
#include <sstream>
#include <stdio.h>
#include <string.h>
#include <thrust/transform_reduce.h>

//#define startRegions 256 //for 8D
#define startRegions 1 // if starting with 1 region
namespace quad {
  using namespace cooperative_groups;

  //===========
  // FOR DEBUGGINGG
  void
  PrintToFile(std::string outString, std::string filename, bool appendMode = 0)
  {
    if (appendMode) {
      std::ofstream outfile(filename, std::ios::app);
      outfile << outString << std::endl;
      outfile.close();
    } else {
	  std::cout<<"Outputing file "<<filename<<"\n";
      std::ofstream outfile(filename);
      outfile << outString << std::endl;
      outfile.close();
    }
  }

  //==========
  __constant__ size_t dFEvalPerRegion;

  template <typename T>
  __global__ void
  PrintcuArray(T* array, int size)
  {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
      for (int i = 0; i < size; i++) {
        // if(i<10)
        printf("array[%i]:%.12f\n", i, array[i]);
        printf("array[%i]:%.12f\n", i, array[i]);
      }
    }
  }

  template <typename T>
  __global__ void
  PrintcuArray(T* array, T* array2, int size)
  {
    if (threadIdx.x == 0 && blockIdx.x == 0) {
      for (int i = 0; i < size; i++)
        printf("array[%i]:%.12f - %.12f\n", i, array[i], array[i] + array2[i]);
    }
  }

  void
  FinalDataPrint(std::stringstream& outfile,
                 std::string id,
                 double true_value,
                 double epsrel,
                 double epsabs,
                 double value,
                 double error,
                 double nregions,
                 double status,
                 int _final,
                 double time,
                 std::string filename,
                 bool appendMode = 0)
  {

    std::ostringstream streamObj;
    std::ostringstream streamObj2;
    streamObj << value;
    streamObj2 << error;

    if (appendMode == 0)
      outfile << "id, value, epsrel, epsabs, estimate, errorest, regions, "
                 "converge, final, total_time"
              << std::endl;
    outfile << std::setprecision(18);
    outfile << id << ",\t" << std::to_string(true_value) << ",\t" << epsrel
            << ",\t" << epsabs << ",\t" << value << ",\t" << error << ",\t"
            << nregions << ",\t" << status << ",\t" << _final << ",\t" << time
            << std::endl;

    // std::cout<<outfile.str()<<std::endl;
    PrintToFile(outfile.str(), filename, appendMode);
  }

  template <typename T>
  __global__ void
  generateInitialRegions(T* dRegions,
                         T* dRegionsLength,
                         size_t numRegions,
                         T* newRegions,
                         T* newRegionsLength,
                         size_t newNumOfRegions,
                         int numOfDivisionsPerRegionPerDimension,
                         int NDIM)
  {

    extern __shared__ T slength[];
    size_t threadId = blockIdx.x * blockDim.x + threadIdx.x;

    if (threadIdx.x < NDIM) {
      slength[threadIdx.x] =
        dRegionsLength[threadIdx.x] / numOfDivisionsPerRegionPerDimension;
    }
    __syncthreads();

    if (threadId < newNumOfRegions) {
      size_t interval_index =
        threadId / pow((T)numOfDivisionsPerRegionPerDimension, (T)NDIM);
      size_t local_id =
        threadId % (size_t)pow((T)numOfDivisionsPerRegionPerDimension, (T)NDIM);
      for (int dim = 0; dim < NDIM; ++dim) {
        size_t id =
          (size_t)(local_id /
                   pow((T)numOfDivisionsPerRegionPerDimension, (T)dim)) %
          numOfDivisionsPerRegionPerDimension;
        newRegions[newNumOfRegions * dim + threadId] =
          dRegions[numRegions * dim + interval_index] + id * slength[dim];
        newRegionsLength[newNumOfRegions * dim + threadId] = slength[dim];
      }
    }
  }

  template <typename T, int NDIM>
  __global__ void
  alignRegions(T* dRegions,
               T* dRegionsLength,
               int* activeRegions,
               T* dRegionsIntegral,
               T* dRegionsError,
               T* dRegionsParentIntegral,
               T* dRegionsParentError,
               int* subDividingDimension,
               int* scannedArray,
               T* newActiveRegions,
               T* newActiveRegionsLength,
               int* newActiveRegionsBisectDim,
               size_t numRegions,
               size_t newNumRegions,
               int numOfDivisionOnDimension)
  {

    size_t tid = blockIdx.x * blockDim.x + threadIdx.x;

    if (tid < numRegions && activeRegions[tid] == 1) {
      size_t interval_index = scannedArray[tid];

      for (int i = 0; i < NDIM; ++i) {
        newActiveRegions[i * newNumRegions + interval_index] =
          dRegions[i * numRegions + tid];
        newActiveRegionsLength[i * newNumRegions + interval_index] =
          dRegionsLength[i * numRegions + tid];
      }

      dRegionsParentIntegral[interval_index] =
        dRegionsIntegral[tid + numRegions];
      dRegionsParentError[interval_index] = dRegionsError[tid + numRegions];

      dRegionsParentIntegral[interval_index + newNumRegions] =
        dRegionsIntegral[tid + numRegions];
      dRegionsParentError[interval_index + newNumRegions] =
        dRegionsError[tid + numRegions];

      for (int i = 0; i < numOfDivisionOnDimension; ++i) {
        newActiveRegionsBisectDim[i * newNumRegions + interval_index] =
          subDividingDimension[tid];
      }
    }
  }

  template <typename T, int NDIM>
  __global__ void
  divideIntervalsGPU(T* genRegions,
                     T* genRegionsLength,
                     T* activeRegions,
                     T* activeRegionsLength,
                     int* activeRegionsBisectDim,
                     size_t numActiveRegions,
                     int numOfDivisionOnDimension)
  {

    size_t tid = blockIdx.x * blockDim.x + threadIdx.x;
    if (tid < numActiveRegions) {

      int bisectdim = activeRegionsBisectDim[tid];
      size_t data_size = numActiveRegions * numOfDivisionOnDimension;

      for (int i = 0; i < numOfDivisionOnDimension; ++i) {
        for (int dim = 0; dim < NDIM; ++dim) {
          genRegions[i * numActiveRegions + dim * data_size + tid] = activeRegions[dim * numActiveRegions + tid];
          genRegionsLength[i * numActiveRegions + dim * data_size + tid] = activeRegionsLength[dim * numActiveRegions + tid];
        }
      }

      for (int i = 0; i < numOfDivisionOnDimension; ++i) {

        T interval_length = activeRegionsLength[bisectdim * numActiveRegions + tid] /numOfDivisionOnDimension;
        genRegions[bisectdim * data_size + i * numActiveRegions + tid] = activeRegions[bisectdim * numActiveRegions + tid] + i * interval_length;
        genRegionsLength[i * numActiveRegions + bisectdim * data_size + tid] = interval_length;
      }
    }
  }

  bool
  cudaMemoryTest()
  {
    // TODO: Doesn't this leak both h_a and d_a on every call?
    const unsigned int N = 1048576;
    const unsigned int bytes = N * sizeof(int);
    int* h_a = (int*)malloc(bytes);
    int* d_a;
    cudaMalloc((int**)&d_a, bytes);

    memset(h_a, 0, bytes);
    cudaMemcpy(d_a, h_a, bytes, cudaMemcpyHostToDevice);
    cudaMemcpy(h_a, d_a, bytes, cudaMemcpyDeviceToHost);
    return true;
  }

  template <typename T, int NDIM>
  class Kernel {
    T* dRegions;
    T* dRegionsLength;
    T* hRegions;
    T* hRegionsLength;

    T* dParentsError;
    T* dParentsIntegral;

    T* highs;
    T* lows;

    Region<NDIM>* gRegionPool;
    T* dRegionsError;
    T* dRegionsIntegral;

    std::stringstream out1;
    std::stringstream out2;
    std::stringstream out3;
    std::stringstream out4;
    std::stringstream out5;

    int Final; // dictates the update rules in Sequential Cuhre & as a result
               // it's conditionally applied in Phase 2
    int phase_I_type;
    int fail; // 0 for satisfying ratio, 1 for not satisfying ratio, 2 for
              // running out of bad regions
    int phase2_failedblocks;
    T lastErr;
    T lastAvg;
    T* dlastErr;
    T* dlastAvg;
    int KEY, VERBOSE, outLevel;
    size_t numRegions, numFunctionEvaluations;
    size_t fEvalPerRegion;
	int first_phase_maxregions;
	int max_globalpool_size;
	
    HostMemory<T> Host;
    DeviceMemory<T> Device;
    Rule<T> rule;
    Structures<T> constMem;
    int NUM_DEVICES;
    // Debug Msg
    char msg[256];

    std::ostream& log;

  public:
    T weightsum, avgsum, guess, chisq, chisum, chisqsum;

    int
    GetPhase2_failedblocks()
    {
      return phase2_failedblocks;
    }

    int
    GetPhase_I_type()
    {
      return phase_I_type;
    }

    double
    GetIntegral()
    {
      return lastAvg;
    }

    double
    GetError()
    {
      return lastErr;
    }

    int
    GetErrorFlag()
    {
      return fail;
    }

    double
    GetRatio(double epsrel, double epsabs)
    {
      return lastErr / MaxErr(lastAvg, epsrel, epsabs);
    }

    void
    SetPhase_I_type(int type)
    {
      phase_I_type = type;
    }

    void
    SetVerbosity(const int verb)
    {
      outLevel = verb;
    }

    void
    SetFinal(const int _Final)
    {
      Final = _Final;
    }

    void
    ExpandcuArray(T*& array, int currentSize, int newSize)
    {
      T* temp = 0;
      int copy_size = std::min(currentSize, newSize);
      QuadDebug(Device.AllocateMemory((void**)&temp, sizeof(T) * newSize));
      QuadDebug(cudaMemcpy(
        temp, array, sizeof(T) * copy_size, cudaMemcpyDeviceToDevice));
      QuadDebug(Device.ReleaseMemory(array));
      array = temp;
    }
	
	size_t PredictSize(const int kernel_width, const int kernel_max_height, const size_t free_physmem, const size_t total_physmem){
		
		size_t maxDeviceHeap 		= 	sizeof(T)*kernel_width *2* kernel_max_height;
		size_t regionsSize   		=  	sizeof(Region<NDIM>) * kernel_width *2 * kernel_max_height;
		size_t reductionArrays 		=   kernel_width *2*(sizeof(int)*3+sizeof(T)*4);
		size_t setupSize			=   total_physmem - free_physmem;
		return maxDeviceHeap+regionsSize+reductionArrays+setupSize;
	}
	
	void ConfigureMemoryUtilization(){
		
		size_t free_physmem, total_physmem;
		QuadDebugExit(cudaMemGetInfo(&free_physmem, &total_physmem));
		
		first_phase_maxregions = FIRST_PHASE_MAXREGIONS;
		max_globalpool_size = MAX_GLOBALPOOL_SIZE;
		
		/*while(PredictSize(first_phase_maxregions, max_globalpool_size + SM_REGION_POOL_SIZE, free_physmem, total_physmem) < total_physmem){
			//printf("max_globalpool_size:%i can be increased\n", max_globalpool_size);
			max_globalpool_size += SM_REGION_POOL_SIZE;
		}*/
		
		while(PredictSize(2*first_phase_maxregions, max_globalpool_size, free_physmem, total_physmem) < total_physmem){
			//printf("first_phase_maxregions:%i can be increased\n", first_phase_maxregions);d
			first_phase_maxregions += first_phase_maxregions;
		}
		
		
		
		
		
		
		
		
		
		
		
	
		
		
		//std::cout<<max_globalpool_size<<","<<first_phase_maxregions<<std::endl;
		
		//std::cout<<"first_phase_maxregions:"<<first_phase_maxregions<<std::endl;	
	
		
		//printf("Suggesting numBlocks:%i and max_global_size:%i vs numBlocks:%i and max_global_size:%i\n", first_phase_maxregions, max_globalpool_size, FIRST_PHASE_MAXREGIONS, MAX_GLOBALPOOL_SIZE);
	}

    Kernel(std::ostream& logerr = std::cout) : log(logerr)
    {
      dParentsError = nullptr;
      dParentsIntegral = nullptr;
      gRegionPool = nullptr;
		
	  ConfigureMemoryUtilization();
	  
      QuadDebug(Device.AllocateMemory((void**)&gRegionPool,
                                      sizeof(Region<NDIM>) * first_phase_maxregions *2 *
                                        max_globalpool_size));
										
      phase2_failedblocks = 0;
      lastErr = 0;
      lastAvg = 0;
      Final = 0;
      fail = 1;
      weightsum = 0, avgsum = 0, guess = 0, chisq = 0, chisum = 0,
      chisqsum = 0; // only used when FINAL = 0 in Rcuhre
      numRegions = 0;
      numFunctionEvaluations = 0;
      // NDIM = 0;
      KEY = 0;
      phase_I_type =
        0; // breadth-first sub-region generation with good region fitler
    }
	
    ~Kernel()
    {
	  
      CudaCheckError();
      QuadDebug(Device.ReleaseMemory(dRegions));
      QuadDebug(Device.ReleaseMemory(dRegionsLength));

      QuadDebug(Device.ReleaseMemory(dParentsIntegral));
      QuadDebug(Device.ReleaseMemory(dParentsError));

      QuadDebug(Device.ReleaseMemory(lows));
      QuadDebug(Device.ReleaseMemory(highs));

      QuadDebug(Device.ReleaseMemory(gRegionPool));
      Host.ReleaseMemory(hRegions);
      Host.ReleaseMemory(hRegionsLength);

      QuadDebug(cudaFree(constMem._gpuG));
      QuadDebug(cudaFree(constMem._cRuleWt));
      QuadDebug(cudaFree(constMem._GPUScale));
      QuadDebug(cudaFree(constMem._GPUNorm));
      QuadDebug(cudaFree(constMem._gpuGenPos));
      QuadDebug(cudaFree(constMem._gpuGenPermGIndex));
      QuadDebug(cudaFree(constMem._gpuGenPermVarStart));
      QuadDebug(cudaFree(constMem._gpuGenPermVarCount));
      QuadDebug(cudaFree(constMem._cGeneratorCount));

      CudaCheckError();
      QuadDebug(cudaDeviceSynchronize());
	  
    }

    size_t
    getNumActiveRegions()
    {
      return numRegions;
    }

    void
    setRegionsData(T* data, size_t size)
    {
      hRegions = &data[0];
      hRegionsLength = &data[size * NDIM];
      numRegions = size;
    }

    T*
    getRegions(size_t size, int startIndex)
    {
      T* newhRegionsAndLength = 0;
      newhRegionsAndLength = (T*)Host.AllocateMemory(
        &newhRegionsAndLength, 2 * sizeof(T) * size * NDIM);
      T *newhRegions = &newhRegionsAndLength[0],
        *newhRegionsLength = &newhRegionsAndLength[size * NDIM];
      // NOTE:Copy order is important
      for (int dim = 0; dim < NDIM; ++dim) {
        QuadDebug(cudaMemcpy(newhRegions + dim * size,
                             dRegions + dim * numRegions + startIndex,
                             sizeof(T) * size,
                             cudaMemcpyDeviceToHost));
        QuadDebug(cudaMemcpy(newhRegionsLength + dim * size,
                             dRegionsLength + dim * numRegions + startIndex,
                             sizeof(T) * size,
                             cudaMemcpyDeviceToHost));
      }
      return newhRegionsAndLength;
    }

    void
    InitKernel(int key, int verbose, int numDevices = 1)
    {
      // QuadDebug(cudaDeviceReset());
      // NDIM = dim;
      KEY = key;
      VERBOSE = verbose;
      NUM_DEVICES = numDevices;
      fEvalPerRegion = (1 + 2 * NDIM + 2 * NDIM + 2 * NDIM + 2 * NDIM +
                        2 * NDIM * (NDIM - 1) + 4 * NDIM * (NDIM - 1) +
                        4 * NDIM * (NDIM - 1) * (NDIM - 2) / 3 + (1 << NDIM));
      QuadDebug(cudaMemcpyToSymbol(dFEvalPerRegion,
                                   &fEvalPerRegion,
                                   sizeof(size_t),
                                   0,
                                   cudaMemcpyHostToDevice));
      rule.Init(NDIM, fEvalPerRegion, KEY, VERBOSE, &constMem);
      // QuadDebug(Device.SetHeapSize());
    }

    template <class K>
    void
    display(K* array, size_t size)
    {
      K* tmp = (K*)malloc(sizeof(K) * size);
      cudaMemcpy(tmp, array, sizeof(K) * size, cudaMemcpyDeviceToHost);
      for (int i = 0; i < size; ++i) {
        //std::cout << tmp[i] << std::endl;
         printf("%.20f \n", (T)tmp[i]);
      }
    }

    void
    PrintOutfileHeaders()
    {
      if (outLevel >= 1) {
        out1 << "result, error, nregions" << std::endl;
      }
      if (outLevel >= 4) {
        out4 << "badregions, regions" << std::endl;
      }
    }

	void 
	Phase_I_PrintFile(size_t size){
		std::stringstream outfile;
		double* hRegionsIntegral = new double[size];
		double* hRegionsError 	 = nullptr;
		hRegionsIntegral = (double*)malloc(sizeof(double) * size);
		hRegionsError = (double*)malloc(sizeof(double) * size);
		QuadDebug(cudaMemcpy(hRegionsIntegral,  dRegionsIntegral, 	sizeof(double) * size , cudaMemcpyDeviceToHost));
		QuadDebug(cudaMemcpy(hRegionsError, 	dRegionsError,  	sizeof(double) * size , cudaMemcpyDeviceToHost));
		display(dRegionsIntegral, size);
		printf("end of display\n");
		for(int i=0; i<size; i++){
			printf("%.15f, %.15f, ", hRegionsIntegral[i], hRegionsError[i]);
			
			for(int dim=0; dim<NDIM; dim++){
				double low = ScaleValue(hRegions[dim * size + i], lows[dim], highs[dim]);
				double high = low + ScaleValue(hRegionsLength[dim * size + i], lows[dim], highs[dim]);
				printf("%.15f, %.15f,", low, high);
			}
			printf("\n");
		}
	}

    // void Phase_IΙ_Print_File(double integral, double error, double epsrel,
    // double epsabs, int regionCnt, int* dRegionsNumRegion, size_t size){
    void
    Phase_II_PrintFile(T integral,
                       T error,
                       T epsrel,
                       T epsabs,
                       int regionCnt,
                       int* dRegionsNumRegion,
                       Region<NDIM>* hgRegionsPhase1,
                       size_t size)
    {

      if (outLevel >= 1) {
        out1 << integral << "," << error << "," << (regionCnt - size)
             << std::endl;
        PrintToFile(out1.str(), "Level_1.csv");
      }

      if (outLevel >= 2) {
        auto callback = [](T integral, T error, T rel) {
          return fabs(error / (rel * integral));
        };

        using func_pointer = double (*)(T integral, T error, T rel);
        func_pointer lambda_fp = callback;

        display(dRegionsIntegral,
                dRegionsError,
                epsrel,
                size,
                lambda_fp,
                "end_ratio.csv",
                "result, error, end_ratio");
        display(dRegionsNumRegion, size, "numRegions.csv", "nregions");
      }
		
      if (outLevel >= 4) {
		//this outLevel will only work for phasetype = 1
        Region<NDIM>* cgRegionPool = 0;
        int* RegionsNumRegion = 0;
        cgRegionPool = (Region<NDIM>*)malloc(sizeof(Region<NDIM>) * size *
                                             max_globalpool_size);
        RegionsNumRegion = (int*)malloc(sizeof(int) * size);

        QuadDebug(cudaMemcpy(cgRegionPool,
                             gRegionPool,
                             sizeof(Region<NDIM>) * size * max_globalpool_size,
                             cudaMemcpyDeviceToHost));

        // printf("Inside print file for phase 2 cgRegionPool[4096]\n");

        CudaCheckError();
        QuadDebug(cudaMemcpy(RegionsNumRegion,
                             dRegionsNumRegion,
                             sizeof(int) * size,
                             cudaMemcpyDeviceToHost));

        if (phase_I_type == 0) {
          OutputPhase2Regions(cgRegionPool,
                              hRegions,
                              hRegionsLength,
                              RegionsNumRegion,
                              size,
                              size * max_globalpool_size);
        } else {
          OutputPhase2Regions(
            cgRegionPool, hgRegionsPhase1, RegionsNumRegion, size, 0);
        }
      }
    }

    void
    Phase_I_PrintFile(T epsrel, T epsabs)
    {

      if (outLevel >= 1 && phase_I_type == 0) {
        PrintToFile(out1.str(), "Level_1.csv");
      }

      if (outLevel >= 3 && phase_I_type == 0) {
        auto callback = [](T integral, T error, T rel) {
          return fabs(error / (rel * integral));
        };

        using func_pointer = double (*)(T integral, T error, T rel);
        func_pointer lambda_fp = callback;

        display(dRegionsIntegral + numRegions,
                dRegionsError + numRegions,
                epsrel,
                numRegions,
                lambda_fp,
                "start_ratio.csv",
                "result, error, initratio");
      } else if (outLevel >= 3) {
        out3 << "result, error, initratio" << std::endl;
        Region<NDIM>* tmp =
          (Region<NDIM>*)malloc(sizeof(Region<NDIM>) * numRegions);
        cudaMemcpy(tmp,
                   gRegionPool,
                   sizeof(Region<NDIM>) * numRegions,
                   cudaMemcpyDeviceToHost);

        for (int i = 0; i < numRegions; ++i) {
          double val = tmp[i].result.avg;
          double err = tmp[i].result.err;
          out3 << val << "," << err << "," << err / MaxErr(val, epsrel, epsabs)
               << std::endl;
        }
        PrintToFile(out3.str(), "start_ratio.csv");
        free(tmp);
      }

      if (outLevel >= 4 && phase_I_type == 0) {
        PrintToFile(out4.str(), "Level_4.csv");
      }
    }

    template <class K>
    void
    display(K* array, size_t size, std::string filename, std::string header)
    {
      std::stringstream outfile;
      outfile << header << std::endl;
      K* tmp = (K*)malloc(sizeof(K) * size);
      cudaMemcpy(tmp, array, sizeof(K) * size, cudaMemcpyDeviceToHost);
      for (int i = 0; i < size; ++i) {
        outfile << tmp[i] << std::endl;
        // printf("%.20lf \n", (T)tmp[i]);
      }
      PrintToFile(outfile.str(), filename);
    }

    template <class K>
    void
    display(K* array1,
            K* array2,
            T optional,
            size_t size,
            K (*func)(K, K, T),
            std::string filename,
            std::string header)
    {
      std::stringstream outfile;
      K* tmp1 = (K*)malloc(sizeof(K) * size);
      K* tmp2 = (K*)malloc(sizeof(K) * size);

      cudaMemcpy(tmp1, array1, sizeof(K) * size, cudaMemcpyDeviceToHost);
      cudaMemcpy(tmp2, array2, sizeof(K) * size, cudaMemcpyDeviceToHost);

      outfile << header << std::endl;

      for (int i = 0; i < size; ++i)
        outfile << tmp1[i] << "," << tmp2[i] << ","
                << func(tmp1[i], tmp2[i], optional) << std::endl;

      std::string outputS = outfile.str();
      PrintToFile(outputS, filename);
    }

    void
    GenerateInitialRegions()
    {
      hRegions = (T*)Host.AllocateMemory(&hRegions, sizeof(T) * NDIM);
      hRegionsLength = (T*)Host.AllocateMemory(&hRegionsLength, sizeof(T) * NDIM);

      for (int dim = 0; dim < NDIM; ++dim) {
        hRegions[dim] = 0;
#if GENZ_TEST == 1
        hRegionsLength[dim] = b[dim];
#else
        hRegionsLength[dim] = 1;
#endif
      }

      QuadDebug(Device.AllocateMemory((void**)&dRegions, sizeof(T) * NDIM));
      QuadDebug(
        Device.AllocateMemory((void**)&dRegionsLength, sizeof(T) * NDIM));

      QuadDebug(cudaMemcpy(
        dRegions, hRegions, sizeof(T) * NDIM, cudaMemcpyHostToDevice));
      QuadDebug(cudaMemcpy(dRegionsLength,
                           hRegionsLength,
                           sizeof(T) * NDIM,
                           cudaMemcpyHostToDevice));

      size_t numThreads = 512;
      // this has been changed temporarily, do not remove
      // size_t numOfDivisionPerRegionPerDimension = 4;
      // if(NDIM == 5 )numOfDivisionPerRegionPerDimension = 2;
      // if(NDIM == 6 )numOfDivisionPerRegionPerDimension = 2;
      // if(NDIM == 7 )numOfDivisionPerRegionPerDimension = 2;
      // if(NDIM > 7 )numOfDivisionPerRegionPerDimension = 2;
      // if(NDIM > 10 )numOfDivisionPerRegionPerDimension = 1;

      size_t numOfDivisionPerRegionPerDimension = 1;

      size_t numBlocks = (size_t)ceil(
        pow((T)numOfDivisionPerRegionPerDimension, (T)NDIM) / numThreads);
      numRegions = (size_t)pow((T)numOfDivisionPerRegionPerDimension, (T)NDIM);

      T* newRegions = 0;
      T* newRegionsLength = 0;
      QuadDebug(Device.AllocateMemory((void**)&newRegions,
                                      sizeof(T) * numRegions * NDIM));
      QuadDebug(Device.AllocateMemory((void**)&newRegionsLength,
                                      sizeof(T) * numRegions * NDIM));

      generateInitialRegions<T><<<numBlocks, numThreads, NDIM * sizeof(T)>>>(
        dRegions,
        dRegionsLength,
        1,
        newRegions,
        newRegionsLength,
        numRegions,
        numOfDivisionPerRegionPerDimension,
        NDIM);

      QuadDebug(Device.ReleaseMemory((void*)dRegions));
      QuadDebug(Device.ReleaseMemory((void*)dRegionsLength));

      dRegions = newRegions;
      dRegionsLength = newRegionsLength;
      QuadDebug(cudaMemcpy(dRegions,
                           newRegions,
                           sizeof(T) * numRegions * NDIM,
                           cudaMemcpyDeviceToDevice));
      QuadDebug(cudaMemcpy(dRegionsLength,
                           newRegionsLength,
                           sizeof(T) * numRegions * NDIM,
                           cudaMemcpyDeviceToDevice));
    }

    void
    GenerateActiveIntervals(int* activeRegions,
                            int* subDividingDimension,
                            T* dRegionsIntegral,
                            T* dRegionsError,
                            T*& dParentsIntegral,
                            T*& dParentsError)
    {

      int* scannedArray = 0; // de-allocated at the end of this function
      QuadDebug(
        Device.AllocateMemory((void**)&scannedArray, sizeof(int) * numRegions));

      thrust::device_ptr<int> d_ptr =
        thrust::device_pointer_cast(activeRegions);
      thrust::device_ptr<int> scan_ptr =
        thrust::device_pointer_cast(scannedArray);
      thrust::exclusive_scan(d_ptr, d_ptr + numRegions, scan_ptr);

      int last_element;
      size_t numActiveRegions = 0;

      QuadDebug(cudaMemcpy(&last_element,
                           activeRegions + numRegions - 1,
                           sizeof(int),
                           cudaMemcpyDeviceToHost));
      QuadDebug(cudaMemcpy(&numActiveRegions,
                           scannedArray + numRegions - 1,
                           sizeof(int),
                           cudaMemcpyDeviceToHost));

      if (last_element == 1)
        numActiveRegions++;

      //printf("Bad Regions:%lu/%lu\n",numActiveRegions,  numRegions);
      if (outLevel >= 4)
        out4 << numActiveRegions << "," << numRegions << std::endl;

      if (numActiveRegions > 0) {

        int numOfDivisionOnDimension = 2;

        int* newActiveRegionsBisectDim = 0;
        T *newActiveRegions = 0, *newActiveRegionsLength =
                                   0; // de-allocated at the end of the function

        cudaMalloc((void**)&newActiveRegions,
                   sizeof(T) * numActiveRegions * NDIM);
        cudaMalloc((void**)&newActiveRegionsLength,
                   sizeof(T) * numActiveRegions * NDIM);
        cudaMalloc((void**)&newActiveRegionsBisectDim,
                   sizeof(int) * numActiveRegions * numOfDivisionOnDimension);

        ExpandcuArray(dParentsIntegral, numRegions * 2, numActiveRegions * 4);
        ExpandcuArray(dParentsError, numRegions * 2, numActiveRegions * 4);

        size_t numThreads = BLOCK_SIZE;
        size_t numBlocks =
          numRegions / numThreads + ((numRegions % numThreads) ? 1 : 0);

        cudaDeviceSynchronize();

        // printf("marking %lu regions as parents\n", numRegions);
        alignRegions<T, NDIM>
          <<<numBlocks, numThreads>>>(dRegions,
                                      dRegionsLength,
                                      activeRegions,
                                      dRegionsIntegral,
                                      dRegionsError,
                                      dParentsIntegral,
                                      dParentsError,
                                      subDividingDimension,
                                      scannedArray,
                                      newActiveRegions,
                                      newActiveRegionsLength,
                                      newActiveRegionsBisectDim,
                                      numRegions,
                                      numActiveRegions,
                                      numOfDivisionOnDimension);

        T *genRegions = 0, *genRegionsLength = 0;
        numBlocks = numActiveRegions / numThreads +
                    ((numActiveRegions % numThreads) ? 1 : 0);

        // IDEA can use expandcuArray(
        QuadDebug(cudaMalloc((void**)&genRegions,
                             sizeof(T) * numActiveRegions * NDIM *
                               numOfDivisionOnDimension));
        QuadDebug(cudaMalloc((void**)&genRegionsLength,
                             sizeof(T) * numActiveRegions * NDIM *
                               numOfDivisionOnDimension));

        divideIntervalsGPU<T, NDIM>
          <<<numBlocks, numThreads>>>(genRegions,
                                      genRegionsLength,
                                      newActiveRegions,
                                      newActiveRegionsLength,
                                      newActiveRegionsBisectDim,
                                      numActiveRegions,
                                      numOfDivisionOnDimension);

        QuadDebug(Device.ReleaseMemory(newActiveRegions));
        QuadDebug(Device.ReleaseMemory(newActiveRegionsLength));
        QuadDebug(Device.ReleaseMemory(newActiveRegionsBisectDim));

        numRegions = numActiveRegions * numOfDivisionOnDimension;

        // taken care of by destructor alternatively
        QuadDebug(Device.ReleaseMemory(dRegions));
        QuadDebug(Device.ReleaseMemory(dRegionsLength));

        QuadDebug(Device.ReleaseMemory(scannedArray));

        dRegions = genRegions;
        dRegionsLength = genRegionsLength;
        cudaDeviceSynchronize();

      } else {
        numRegions = 0;
      }
    }

    __inline__ void
    SetVolume(Volume<T, NDIM>* vol)
    {}
    // idea, allocate maximum dParentsIntegral, will it improve performance?

    template <typename IntegT>
    void
    FirstPhaseIteration(IntegT* d_integrand,
                        T epsrel,
                        T epsabs,
                        T& integral,
                        T& error,
                        size_t& nregions,
                        size_t& neval,
                        T*& dParentsIntegral,
                        T*& dParentsError,
						int iteration,
                        int last_iteration = 0)
    {

      size_t numThreads = BLOCK_SIZE;
      size_t numBlocks = numRegions;

      dRegionsError = nullptr, dRegionsIntegral = nullptr;
      T* newErrs = 0;

      QuadDebug(Device.AllocateMemory((void**)&dRegionsIntegral,
                                      sizeof(T) * numRegions * 2));
      QuadDebug(Device.AllocateMemory((void**)&dRegionsError,
                                      sizeof(T) * numRegions * 2));

      if (numRegions == startRegions && error == 0) {
        QuadDebug(Device.AllocateMemory((void**)&dParentsIntegral,
                                        sizeof(T) * numRegions * 2));
        QuadDebug(Device.AllocateMemory((void**)&dParentsError,
                                        sizeof(T) * numRegions * 2));
      }

      int *activeRegions = 0, *subDividingDimension = 0;

      QuadDebug(Device.AllocateMemory((void**)&activeRegions,
                                      sizeof(int) * numRegions));
      QuadDebug(Device.AllocateMemory((void**)&subDividingDimension,
                                      sizeof(int) * numRegions));
      QuadDebug(Device.AllocateMemory((void**)&newErrs, sizeof(T) * numRegions * 2));
	 // printf("INTEGRATE_GPU_PHASE 1 kernel about to be called\n");
      INTEGRATE_GPU_PHASE1<IntegT, T, NDIM>
        <<<numBlocks, numThreads, NDIM * sizeof(GlobalBounds)>>>(
          d_integrand,
          dRegions,
          dRegionsLength,
          numRegions,
          dRegionsIntegral,
          dRegionsError,
          activeRegions,
          subDividingDimension,
          epsrel,
          epsabs,
          constMem,
          rule.GET_FEVAL(),
          rule.GET_NSETS(),
          lows,
          highs,
		  iteration);

      cudaDeviceSynchronize();

      if (numRegions != startRegions) {

        RefineError<T><<<numBlocks, numThreads>>>(dRegionsIntegral,
                                                  dRegionsError,
                                                  dParentsIntegral,
                                                  dParentsError,
                                                  newErrs,
                                                  activeRegions,
                                                  numRegions,
                                                  epsrel,
                                                  epsabs);

        cudaDeviceSynchronize();
        QuadDebug(cudaMemcpy(dRegionsError,
                             newErrs,
                             sizeof(T) * numRegions * 2,
                             cudaMemcpyDeviceToDevice));

        cudaDeviceSynchronize();
      }

      T temp_integral = 0;
      T temp_error = 0;

      if (last_iteration == 1) {
        temp_integral = integral;
        temp_error = error;
      }

      // printf("Computing integral from %lu regions\n", numRegions);
      nregions += numRegions;
      neval += numRegions * fEvalPerRegion;

      thrust::device_ptr<T> wrapped_ptr;

      wrapped_ptr = thrust::device_pointer_cast(dRegionsIntegral + numRegions);
      T rG = integral + thrust::reduce(wrapped_ptr, wrapped_ptr + numRegions);

      wrapped_ptr = thrust::device_pointer_cast(dRegionsError + numRegions);
      T errG = error + thrust::reduce(wrapped_ptr, wrapped_ptr + numRegions);

      wrapped_ptr = thrust::device_pointer_cast(dRegionsIntegral);
      integral =
        integral + thrust::reduce(wrapped_ptr, wrapped_ptr + numRegions);

      wrapped_ptr = thrust::device_pointer_cast(dRegionsError);
      error = error + thrust::reduce(wrapped_ptr, wrapped_ptr + numRegions);

      if (Final == 0) {
        double w = numRegions * 1 / fmax(errG * errG, ldexp(1., -104));
        weightsum += w; // adapted by Ioannis
        avgsum += w * rG;
        double sigsq = 1 / weightsum;
        lastAvg = sigsq * avgsum;
        lastErr = sqrt(sigsq);
        //printf("F0 lastAvg:%.17f\t lastErr:%.17f\t rg:%.17f\terrG:%.17f\tnumRegions:%lu w:%.17f weightsum:%.17f\n", lastAvg,
        //lastErr,  rG, errG, numRegions, w, weightsum);
      } else {
        lastAvg = rG;
        lastErr = errG;
         //printf("F1 rG:%f\t errG:%f\t global: %f +- %f numRegions:%lu\n", lastAvg, lastErr,  numRegions, integral, error);
      }

      if (outLevel >= 1)
        out1 << lastAvg << "," << lastErr << "," << nregions << std::endl;

      if ((lastErr <= MaxErr(lastAvg, epsrel, epsabs)) && GLOBAL_ERROR) {
        if (outLevel >= 1)
          PrintToFile(out1.str(), "Level_1.csv");

        fail = 0;
        numRegions = 0;
        integral = lastAvg;
        error = lastErr;

        QuadDebug(cudaFree(activeRegions));
        QuadDebug(cudaFree(subDividingDimension));
        QuadDebug(cudaFree(newErrs));
        return;
      } else if (last_iteration == 1) {
        integral = temp_integral;
        error = temp_error;
      }

      // printf("integral:%f\n", integral);
      if (numRegions <= first_phase_maxregions && fail == 1) {
        GenerateActiveIntervals(activeRegions,
                                subDividingDimension,
                                dRegionsIntegral,
                                dRegionsError,
                                dParentsIntegral,
                                dParentsError);
      }
	  else{
		  //printf("displaying %lu regions\n", numRegions);
		  //display<double>(dRegionsIntegral + numRegions, numRegions);
	  }
      QuadDebug(cudaFree(activeRegions));
      QuadDebug(cudaFree(subDividingDimension));
      QuadDebug(cudaFree(newErrs));
    }
	
    template <typename IntegT>
    bool
    IntegrateFirstPhase(IntegT* d_integrand,
                        T epsrel,
                        T epsabs,
                        T& integral,
                        T& error,
                        size_t& nregions,
                        size_t& neval,
                        Volume<T, NDIM>* vol = nullptr)
    {
      // REDUCE CYCLOMATIC COMPLEXITY
	  //printf("Allocating volume\n");
      cudaMalloc((void**)&lows, sizeof(T) * NDIM);
      cudaMalloc((void**)&highs, sizeof(T) * NDIM);

      if (vol) {
        cudaMemcpy(lows, vol->lows, sizeof(T) * NDIM, cudaMemcpyHostToDevice);
        cudaMemcpy(highs, vol->highs, sizeof(T) * NDIM, cudaMemcpyHostToDevice);
      } else {
        Volume<T, NDIM> tempVol;
        cudaMemcpy(
          lows, tempVol.lows, sizeof(T) * NDIM, cudaMemcpyHostToDevice);
        cudaMemcpy(
          highs, tempVol.highs, sizeof(T) * NDIM, cudaMemcpyHostToDevice);
      }
		
      CudaCheckError();
      PrintOutfileHeaders();
	  int lastIteration = 0;
	  int iteration = 0;
      for (iteration = 0; iteration < 100; iteration++) {
        FirstPhaseIteration<IntegT>(d_integrand,
                                    epsrel,
                                    epsabs,
                                    integral,
                                    error,
                                    nregions,
                                    neval,
                                    dParentsIntegral,
                                    dParentsError,
									iteration,
									lastIteration);
		
        if (numRegions < 1) {
          fail = 2;
          Phase_I_PrintFile(epsrel, epsabs);
          break;
        } else if (numRegions > first_phase_maxregions && fail == 1) {
          int last_iteration = 1;
          QuadDebug(cudaFree(dRegionsError));
          QuadDebug(cudaFree(dRegionsIntegral));
          FirstPhaseIteration<IntegT>(d_integrand,
                                      epsrel,
                                      epsabs,
                                      integral,
                                      error,
                                      nregions,
                                      neval,
                                      dParentsIntegral,
                                      dParentsError,
									  iteration,
                                      last_iteration);
          break;
        } else {
          QuadDebug(cudaFree(dRegionsError));
          QuadDebug(cudaFree(dRegionsIntegral));
        }
		//printf("iteration %i finished\n", iteration);
      }

      Phase_I_PrintFile(epsrel, epsabs);

      Host.ReleaseMemory(hRegions);
      Host.ReleaseMemory(hRegionsLength);

      hRegions =
        (T*)Host.AllocateMemory(&hRegions, sizeof(T) * numRegions * NDIM);
      hRegionsLength =
        (T*)Host.AllocateMemory(&hRegionsLength, sizeof(T) * numRegions * NDIM);

      QuadDebug(cudaMemcpy(hRegions,
                           dRegions,
                           sizeof(T) * numRegions * NDIM,
                           cudaMemcpyDeviceToHost));
      QuadDebug(cudaMemcpy(hRegionsLength,
                           dRegionsLength,
                           sizeof(T) * numRegions * NDIM,
                           cudaMemcpyDeviceToHost));
      CudaCheckError();
	  
      if (fail == 0 || fail == 2) {
        integral = lastAvg;
        error = lastErr;
        QuadDebug(cudaFree(dRegionsError));
        QuadDebug(cudaFree(dRegionsIntegral));
        return true;
      } else {
        return false;
      }
    }

    void
    OutputPhase2Regions(Region<NDIM>* cgRegionPool,
                        T* Regions,
                        T* RegionsLength,
                        int* numRegions,
                        size_t start_size,
                        size_t size)
    {

      std::stringstream outfile;
      std::string filename = "phase2.csv";

      outfile << "value, error, ";
      for (int dim = 0; dim < NDIM; ++dim)
        outfile << "dim" + std::to_string(dim) << ",";
      outfile << "div" << std::endl;

      // outer loop iterates phase 2 block array segments
      for (size_t i = 0; i < start_size; ++i) {

        size_t startIndex = i * max_globalpool_size;
        size_t endIndex = startIndex + numRegions[i];

        for (size_t j = startIndex; j < endIndex; ++j) {

          outfile << cgRegionPool[j].result.avg << ","
                  << cgRegionPool[j].result.err << ",";

          for (int dim = 0; dim < NDIM; ++dim) {
            T lower = Regions[dim * start_size + i];
            T upper = lower + RegionsLength[dim * start_size + i];

            T scaledL =
              lower + cgRegionPool[j].bounds[dim].lower * (upper - lower);
            T scaledU =
              lower + cgRegionPool[j].bounds[dim].upper * (upper - lower);
            outfile << scaledU - scaledL << ",";
            if ((scaledU - scaledL) <= 0. || (scaledU - scaledL) >= 1.)
              printf("block:%lu, id:%lu scaled bounds:(%e %e) unscaled:(%e, "
                     "%e) div:%i nregions:%i diff:%e\n",
                     i,
                     j,
                     scaledL,
                     scaledU,
                     cgRegionPool[j].bounds[dim].lower,
                     cgRegionPool[j].bounds[dim].upper,
                     cgRegionPool[j].div,
                     numRegions[i],
                     scaledU - scaledL);
          }
          outfile << cgRegionPool[j].div << std::endl;
        }
        if (i % 1000 == 0)
          printf("%lu\n", i);
      }

      PrintToFile(outfile.str(), filename);
    }

    void
    OutputPhase2Regions(Region<NDIM>* cgRegionPool,
                        Region<NDIM>* hgRegionsPhase1,
                        int* numRegions,
                        size_t start_size,
                        size_t size)
    {

      std::stringstream outfile;
      std::string filename = "phase2.csv";

      outfile << "value, error, ";
      for (int dim = 0; dim < NDIM; ++dim)
        outfile << "dim" + std::to_string(dim) << ",";
      outfile << "div" << std::endl;

      // outer loop iterates phase 2 block array segments
      double total_vol = 0;
      // double unscaled_total_vol = 0;
	  printf("About to output\n");
      for (size_t i = 0; i < start_size; ++i) {

        size_t startIndex = i * max_globalpool_size;
        size_t endIndex = startIndex + numRegions[i];

        double block_vol = 0;
        // double block_unscaled_vol = 0;

        for (size_t j = startIndex; j < endIndex; ++j) {

          double vol = 1;
          // double unscaled_vol = 1;

          outfile << cgRegionPool[j].result.avg << ","
                  << cgRegionPool[j].result.err << ",";

          for (int dim = 0; dim < NDIM; ++dim) {
            T lower = hgRegionsPhase1[i].bounds[dim].lower;
            T upper = hgRegionsPhase1[i].bounds[dim].upper;

            // unscaled_vol *= upper - lower;

            T scaledL =
              lower + cgRegionPool[j].bounds[dim].lower * (upper - lower);
            T scaledU =
              lower + cgRegionPool[j].bounds[dim].upper * (upper - lower);

            vol *= scaledU - scaledL;

            outfile << scaledU - scaledL << ",";
            if ((scaledU - scaledL) <= 0 || (scaledU - scaledL) >= 1 ||
                scaledU - scaledL == 0)
              printf(
                "block:%lu, id:%lu dim:%i scaled bounds:(%f %f) unscaled:(%f, "
                "%f) global bounds:(%f,%f) div:%i nregions:%i diff:%e\n",
                i,
                j,
                dim,
                scaledL,
                scaledU,
                cgRegionPool[j].bounds[dim].lower,
                cgRegionPool[j].bounds[dim].upper,
                lower,
                upper,
                cgRegionPool[j].div,
                numRegions[i],
                scaledU - scaledL);
          }

          block_vol += vol;
          // block_unscaled_vol += unscaled_vol;
          outfile << cgRegionPool[j].div + hgRegionsPhase1[i].div << std::endl;
        }
        total_vol += block_vol;
        // unscaled_total_vol += block_unscaled_vol;
      }

      printf("Phase 2 scaled volume:%f\n", total_vol);
      printf("Starting to actually print\n");
      PrintToFile(outfile.str(), filename);
      printf("Finished printing\n");
    }

    template <typename IntegT>
    bool
    IntegrateFirstPhaseDCUHRE(IntegT* d_integrand,
                              T epsrel,
                              T epsabs,
                              T& integral,
                              T& error,
                              size_t& nregions,
                              size_t& neval,
                              Volume<T, NDIM>* vol = nullptr)
    {
      //==============================================================
      // PHASE 1 SETUP
      cudaMalloc((void**)&lows, sizeof(T) * NDIM);
      cudaMalloc((void**)&highs, sizeof(T) * NDIM);

      if (vol) {
        cudaMemcpy(lows, vol->lows, sizeof(T) * NDIM, cudaMemcpyHostToDevice);
        cudaMemcpy(highs, vol->highs, sizeof(T) * NDIM, cudaMemcpyHostToDevice);
      } else {
        Volume<T, NDIM> tempVol;
        cudaMemcpy(
          lows, tempVol.lows, sizeof(T) * NDIM, cudaMemcpyHostToDevice);
        cudaMemcpy(
          highs, tempVol.highs, sizeof(T) * NDIM, cudaMemcpyHostToDevice);
      }

      size_t numBlocks = 1;
      size_t numThreads = BLOCK_SIZE;
      // size_t numThreads			= 1;
      size_t numCurrentRegions = 0;

      T* phase1_value = nullptr;
      T* phase1_err = nullptr;

      int* regions_generated = 0;
      int* converged = 0;
      int gpu_id = 0;

      double* dPh1res = nullptr;
		
      int snapshots[5] = {3968, 4021, 4022, 4023, 4096};
      Snapshot<NDIM> snap(snapshots, 5);
      /*int num = 5;
      QuadDebug(cudaMemcpy(&snap.num,
                   &num,
                   sizeof(int),
                   cudaMemcpyHostToDevice));*/
      CudaCheckError();
      QuadDebug(Device.AllocateMemory((void**)&dPh1res, sizeof(double) * 2));

      cudaMalloc((void**)&converged, sizeof(int));
      cudaMalloc((void**)&regions_generated, sizeof(int));
      CudaCheckError();
      //==============================================================
      int max_regions = 32734; // worked great for 4e-5 finished in 730 ms
      // int max_regions  = 16367;
	  //printf("About to call alternative phase 1 kernel\n");
      BLOCK_INTEGRATE_GPU_PHASE2<IntegT, T, NDIM>
        <<<numBlocks, numThreads, NDIM * sizeof(GlobalBounds)>>>(
          d_integrand,
          lows,
          highs,
          numCurrentRegions,
          dPh1res,
          dPh1res + 1,
          regions_generated,
          converged,
          nullptr,
          epsrel,
          epsabs,
          gpu_id,
          constMem,
          rule.GET_FEVAL(),
          rule.GET_NSETS(),
          0,
          lows,
          highs,
          Final,
          gRegionPool,
          nullptr,
          nullptr,
          0,
          0,
          0,
          0,
          dPh1res,
          max_regions,
          phase_I_type,
          0,
          snap);

      PrintOutfileHeaders();
      numRegions = max_regions;
      CudaCheckError();
      cudaDeviceSynchronize();

      // snap.Save("pdc256_snapshot");
      /*Region<NDIM>* tempGregions = (Region<NDIM>*)malloc(sizeof(Region<NDIM>)
      * max_regions);


      QuadDebug(cudaMemcpy(tempGregions,
                   gRegionPool,
                   sizeof(Region<NDIM>) * max_regions,
                   cudaMemcpyDeviceToHost));

      std::ofstream outfile("dc_phase1.csv");
      outfile.precision(20);
      for(int i=0; i< max_regions; i++){
              outfile<<tempGregions[i].result.avg<<","<<tempGregions[i].result.err<<",";
              for(int dim = 0; dim < NDIM; dim++){
                      outfile<<tempGregions[i].bounds[dim].upper -
      tempGregions[i].bounds[dim].lower<<",";
              }
              outfile<<tempGregions[i].result.bisectdim<<","<<tempGregions[i].div<<std::endl;
      }
      outfile.close();*/

      // if (outLevel >= 1)

      // T hphase1_value 		 = 0;//(T*)malloc(sizeof(T));
      // T hphase1_err 		 = 0;//(T*)malloc(sizeof(T));
      int hregions_generated = 0; //(int*)malloc(sizeof(int));

      QuadDebug(
        cudaMemcpy(&lastAvg, dPh1res, sizeof(T), cudaMemcpyDeviceToHost));

      QuadDebug(
        cudaMemcpy(&lastErr, dPh1res + 1, sizeof(T), cudaMemcpyDeviceToHost));

      QuadDebug(cudaMemcpy(&hregions_generated,
                           regions_generated,
                           sizeof(int),
                           cudaMemcpyDeviceToHost));

      if (outLevel == 4) {
        Region<NDIM>* tmp = 0;
        std::ofstream outfile("phase1.csv");
        tmp = (Region<NDIM>*)malloc(sizeof(Region<NDIM>) * max_regions);
        cudaMemcpy(tmp,
                   gRegionPool,
                   sizeof(Region<NDIM>) * max_regions,
                   cudaMemcpyDeviceToHost);
        double tot_vol = 0;
        outfile << "value, error, dim0,dim1,dim2,dim3,dim4,div" << std::endl;

        for (int i = 0; i < max_regions; ++i) {
          double vol = 1;
          outfile << tmp[i].result.avg << "," << tmp[i].result.err << ",";
          for (int dim = 0; dim < NDIM; dim++) {
            vol *= tmp[i].bounds[dim].upper - tmp[i].bounds[dim].lower;
            outfile << tmp[i].bounds[dim].upper - tmp[i].bounds[dim].lower
                    << ",";
          }
          outfile << tmp[i].div << std::endl;
          tot_vol += vol;
        }
        outfile.close();
        free(tmp);
      }

      if (outLevel >= 1)
        out1 << lastAvg << "," << lastErr << "," << hregions_generated
             << std::endl;

      CudaCheckError();
      // std::cout <<"Phase 1 Result:"<< lastAvg << ", " << lastErr << ", " <<
      // hregions_generated << "ratio:" << lastErr/MaxErr(lastAvg, epsrel,
      // epsabs) << std::endl;
      // printf("Phase 1 Result:%.20f +- %.20f regions:%i ratio:%f\n", lastAvg,
      // lastErr, hregions_generated, lastErr/MaxErr(lastAvg, epsrel, epsabs));
      nregions = hregions_generated;
      Phase_I_PrintFile(epsrel, epsabs);

      cudaFree(phase1_value);
      cudaFree(phase1_err);
      cudaFree(converged);
      cudaFree(regions_generated);

      CudaCheckError();

      // printf("Phase 1 %.15f +- %.15f ratio:%f\n", lastAvg,
      // lastErr,lastErr/MaxErr(lastAvg, epsrel, epsabs));
      if (lastErr / MaxErr(lastAvg, epsrel, epsabs) < 1) {
        fail = 0;
        integral = lastAvg;
        error = lastErr;
        return true;
      }

      CudaCheckError();
      // cudaFree(phase1_value);
      // cudaFree(phase1_err);
      // cudaFree(converged);
      // cudaFree(regions_generated);
      CudaCheckError();
      QuadDebug(Device.ReleaseMemory(dPh1res));
      QuadDebug(
        Device.AllocateMemory((void**)&dRegionsError, sizeof(T) * numRegions));
      CudaCheckError();
      QuadDebug(Device.AllocateMemory((void**)&dRegionsIntegral,
                                      sizeof(T) * numRegions));
      CudaCheckError();
      return false;
    }
	
    template <typename IntegT>
    int
    IntegrateSecondPhase(IntegT* d_integrand,
                         T epsrel,
                         T epsabs,
                         T& integral,
                         T& error,
                         size_t& nregions,
                         size_t& neval,
                         T* optionalInfo = 0)
    {
      int numFailedRegions = 0;
      int num_gpus = 0; // number of CUDA GPUs

      if (optionalInfo != 0) {
        optionalInfo[0] = -INFTY;
      }

      /////////////////////////////////////////////////////////////////
      // determine the number of CUDA capable GPUs
      //
      cudaGetDeviceCount(&num_gpus);
      if (num_gpus < 1) {
        fprintf(stderr, "no CUDA capable devices were detected\n");
        exit(1);
      }
      int num_cpu_procs = omp_get_num_procs();

      if (NUM_DEVICES > num_gpus)
        NUM_DEVICES = num_gpus;

      omp_set_num_threads(NUM_DEVICES);
      cudaStream_t stream[NUM_DEVICES];
      cudaEvent_t event[NUM_DEVICES];
      CudaCheckError();
#pragma omp parallel

      {
        unsigned int cpu_thread_id = omp_get_thread_num();
        unsigned int num_cpu_threads = omp_get_num_threads();

        // set and check the CUDA device for this CPU thread
        int gpu_id = -1;

        QuadDebug(cudaSetDevice(
          cpu_thread_id %
          num_gpus)); // "% num_gpus" allows more CPU threads than GPU devices
        QuadDebug(cudaGetDevice(&gpu_id));
        warmUpKernel<<<first_phase_maxregions, BLOCK_SIZE>>>();

        if (cpu_thread_id < num_cpu_threads) {

          size_t numRegionsThread = numRegions / num_cpu_threads;
          int startIndex = cpu_thread_id * numRegionsThread;
          int endIndex = (cpu_thread_id + 1) * numRegionsThread;

          if (cpu_thread_id == (num_cpu_threads - 1))
            endIndex = numRegions;

          numRegionsThread = endIndex - startIndex;

          CudaCheckError();

          // rule.loadDeviceConstantMemory(&constMem, cpu_thread_id);
          size_t numThreads = BLOCK_SIZE;
          size_t numBlocks = numRegionsThread;
			
          T *dRegionsThread = 0, *dRegionsLengthThread = 0;
			
          int *activeRegions = 0, *subDividingDimension = 0,
              *dRegionsNumRegion = 0;

          QuadDebug(Device.AllocateMemory((void**)&activeRegions,
                                          sizeof(int) * numRegionsThread));
          QuadDebug(Device.AllocateMemory((void**)&subDividingDimension,
                                          sizeof(int) * numRegionsThread));
          QuadDebug(Device.AllocateMemory((void**)&dRegionsNumRegion,
                                          sizeof(int) * numRegionsThread));

          if (phase_I_type == 0) {
            QuadDebug(Device.AllocateMemory(
              (void**)&dRegionsThread, sizeof(T) * numRegionsThread * NDIM));
            QuadDebug(
              Device.AllocateMemory((void**)&dRegionsLengthThread,
                                    sizeof(T) * numRegionsThread * NDIM));
          }
          CudaCheckError();
          // NOTE:Copy order is important

          if (phase_I_type == 0) {
            for (int dim = 0; dim < NDIM; ++dim) {
              QuadDebug(cudaMemcpy(dRegionsThread + dim * numRegionsThread,
                                   hRegions + dim * numRegions + startIndex,
                                   sizeof(T) * numRegionsThread,
                                   cudaMemcpyHostToDevice));

              QuadDebug(
                cudaMemcpy(dRegionsLengthThread + dim * numRegionsThread,
                           hRegionsLength + dim * numRegions + startIndex,
                           sizeof(T) * numRegionsThread,
                           cudaMemcpyHostToDevice));
            }
          }

          CudaCheckError();
		
          cudaEvent_t start;
          QuadDebug(cudaStreamCreate(&stream[gpu_id]));
          QuadDebug(cudaEventCreate(&start));
          QuadDebug(cudaEventCreate(&event[gpu_id]));
          QuadDebug(cudaEventRecord(start, stream[gpu_id]));
          CudaCheckError();
			
          //printf("Launching Phase 2 with %lu blocks\n", numBlocks);
          double* exitCondition = nullptr;
          double* dPh1res = nullptr;
			
          QuadDebug(
            Device.AllocateMemory((void**)&dPh1res, sizeof(double) * 2));
          // printf("Phase 2 lastAvg:%.17f lastErr:%.17f\n", lastAvg, lastErr);
          // lastAvg = 0;
          // lastErr = 0;
          QuadDebug(
            cudaMemcpy(dPh1res, &lastAvg, sizeof(T), cudaMemcpyHostToDevice));
          QuadDebug(cudaMemcpy(
            dPh1res + 1, &lastErr, sizeof(T), cudaMemcpyHostToDevice));

          // used to restructure 2048 array to 2048*size
          // int start_regions = 16367;
          int start_regions = 32734;
          Region<NDIM>* ph1_regions = 0;
          Region<NDIM>* tmp = nullptr;

          // double* global_errorest = nullptr;
          // int* numContributors = nullptr;
          //  int h_numContributors[2048];
          // double h_global_errorest[2048];

          // for(int i=0; i<2048; i++)
          //	  h_global_errorest[i] = 0.0;

          // QuadDebug(Device.AllocateMemory((void**)&global_errorest,
          // sizeof(double)*2048));
          // QuadDebug(Device.AllocateMemory((void**)&numContributors,
          // sizeof(int)*2048)); QuadDebug(cudaMemcpy(global_errorest,
          // &h_global_errorest, sizeof(double)*2048, cudaMemcpyHostToDevice));

          // cudaMemset(numContributors, 0, sizeof(int)*2048);
          if (phase_I_type == 1) {
            QuadDebug(Device.AllocateMemory(
              (void**)&ph1_regions, sizeof(Region<NDIM>) * start_regions));
            cudaMemcpy(ph1_regions,
                       gRegionPool,
                       sizeof(Region<NDIM>) * start_regions,
                       cudaMemcpyDeviceToDevice);
          }
		  
		  
          CudaCheckError();
		  
          if (outLevel >= 4 && phase_I_type == 1) {
            printf("Entered outlevel >=4\n");
            std::stringstream tempOut;
            tmp = (Region<NDIM>*)malloc(sizeof(Region<NDIM>) * start_regions);
            cudaMemcpy(tmp,
                       ph1_regions,
                       sizeof(Region<NDIM>) * start_regions,
                       cudaMemcpyDeviceToHost);
            double tot_vol = 0;
            tempOut << "value, error, dim0,dim1,dim2,dim3,dim4,div"
                    << std::endl;

            for (int i = 0; i < start_regions; ++i) {
              double vol = 1;
              tempOut << tmp[i].result.avg << "," << tmp[i].result.err << ",";
              if (i == 0)
                std::cout << tmp[i].result.avg << "," << tmp[i].result.err
                          << ",";
              for (int dim = 0; dim < NDIM; dim++) {
                vol *= tmp[i].bounds[dim].upper - tmp[i].bounds[dim].lower;
                tempOut << tmp[i].bounds[dim].upper - tmp[i].bounds[dim].lower
                        << ",";
                if (i == 0)
                  std::cout
                    << tmp[i].bounds[dim].upper - tmp[i].bounds[dim].lower
                    << ",";
              }
              tempOut << tmp[i].div << std::endl;
              if (i == 0)
                std::cout << tmp[i].div << std::endl;
              tot_vol += vol;
            }
            PrintToFile(tempOut.str(), "phase1.csv");
          }
		  else if(outLevel >= 4 && phase_I_type == 0){
			  //Phase_I_PrintFile(numRegionsThread);
		  }

          printf("Phase 1 temp results: %.17f +- %.17f ratio:%f nregions:%lu\n", lastAvg,
          lastErr, lastErr/MaxErr(lastAvg, epsrel, epsabs), numRegions); 
		   
           //printf("Phase 1 good region results:%.17f +- %.17f\n", integral, error);
          // printf("-------\n");
		  
          int max_regions = max_globalpool_size;
          CudaCheckError();
          BLOCK_INTEGRATE_GPU_PHASE2<IntegT, T, NDIM>
            <<<numBlocks,
               numThreads,
               NDIM * sizeof(GlobalBounds),
               stream[gpu_id]>>>(d_integrand,
                                 dRegionsThread,
                                 dRegionsLengthThread,
                                 numRegionsThread,
                                 dRegionsIntegral,
                                 dRegionsError,
                                 dRegionsNumRegion,
                                 activeRegions,
                                 subDividingDimension,
                                 epsrel,
                                 epsabs,
                                 gpu_id,
                                 constMem,
                                 rule.GET_FEVAL(),
                                 rule.GET_NSETS(),
                                 exitCondition,
                                 lows,
                                 highs,
                                 Final,
                                 gRegionPool,
                                 nullptr,
                                 nullptr,
                                 lastAvg,
                                 lastErr,
                                 weightsum,
                                 avgsum,
                                 dPh1res,
                                 max_regions,
                                 phase_I_type,
                                 ph1_regions,
                                 Snapshot<NDIM>(),
                                 nullptr,
                                 nullptr);

          cudaDeviceSynchronize();
          CudaCheckError();
          // QuadDebug(cudaMemcpy(&h_global_errorest, global_errorest,
          // sizeof(double)*2048, cudaMemcpyDeviceToHost));
          // QuadDebug(cudaMemcpy(&h_numContributors, numContributors,
          // sizeof(int)*2048, cudaMemcpyDeviceToHost));
          CudaCheckError();
          // printf("ABout to show data\n");
          // for(int i=0; i<2048; i++)
          //	printf("%i, %.20f, %i\n", i, h_global_errorest[i],
          //h_numContributors[i]); printf("Starting Phase 2 global
          // errorest:%.20f\n", h_global_errorest[0]);
          cudaEventRecord(event[gpu_id], stream[gpu_id]);
          cudaEventSynchronize(event[gpu_id]);

          float elapsed_time;
          cudaEventElapsedTime(&elapsed_time, start, event[gpu_id]);

          if (optionalInfo != 0 && elapsed_time > optionalInfo[0]) {
            optionalInfo[0] = elapsed_time;
          }

          cudaEventDestroy(start);
          cudaEventDestroy(event[gpu_id]);

          thrust::device_ptr<T> wrapped_ptr;

          wrapped_ptr = thrust::device_pointer_cast(dRegionsIntegral);
          T integResult =
            thrust::reduce(wrapped_ptr, wrapped_ptr + numRegionsThread);
          integral += integResult;

          wrapped_ptr = thrust::device_pointer_cast(dRegionsError);
          T errorResult =
            thrust::reduce(wrapped_ptr, wrapped_ptr + numRegionsThread);

          error += errorResult;
          thrust::device_ptr<int> int_ptr =
            thrust::device_pointer_cast(dRegionsNumRegion);
          int regionCnt = thrust::reduce(int_ptr, int_ptr + numRegionsThread);
		  
          if (Final == 0) {
            double w =
              numRegionsThread * 1 / fmax(error * error, ldexp(1., -104));
            weightsum += w; // adapted by Ioannis
            avgsum += w * integral;
            double sigsq = 1 / weightsum;
            integral = sigsq * avgsum;
            error = sqrt(sigsq);
          }

          Phase_II_PrintFile(integral,
                             error,
                             epsrel,
                             epsabs,
                             regionCnt,
                             dRegionsNumRegion,
                             tmp,
                             numRegionsThread);

          nregions = regionCnt;

          neval += (regionCnt - numRegionsThread) * fEvalPerRegion * 2 +
                   numRegionsThread * fEvalPerRegion;

          int_ptr = thrust::device_pointer_cast(activeRegions);
          numFailedRegions +=
            thrust::reduce(int_ptr, int_ptr + numRegionsThread);
          phase2_failedblocks = numFailedRegions;
          // delete structures allocated inside phase 2
          if (phase_I_type == 0) {
            QuadDebug(Device.ReleaseMemory(dRegionsThread));
            QuadDebug(Device.ReleaseMemory(dRegionsLengthThread));
          }
          QuadDebug(Device.ReleaseMemory(activeRegions));
          QuadDebug(Device.ReleaseMemory(subDividingDimension));
          QuadDebug(Device.ReleaseMemory(dRegionsNumRegion));

          QuadDebug(Device.ReleaseMemory(dRegionsIntegral));
          QuadDebug(Device.ReleaseMemory(dRegionsError));
          QuadDebug(Device.ReleaseMemory(dPh1res));
          CudaCheckError();
          //------------------------------------------------------
          QuadDebug(cudaDeviceSynchronize());
        }

        else
          printf("Rogue cpu thread\n");
      }

      // free conditional allocations

      return numFailedRegions;
    }
  };

}
#endif
