#ifndef KOKKOSCUHRE_CUH
#define KOKKOSCUHRE_CUH

#include "quad.h"
#include "Kernel.cuh"
#include "Rule.cuh"
#include <array>

template <typename T, int NDIM>
class Cuhre{
  public:
    //double epsrel, epsabs;
    double* OutputRegionsIntegral;
    double* OutputRegionsError;
    double* OutputRegions;
    double* OutputRegionsLength;
    size_t numOutputRegions;
    bool output = false;;
    
    Cuhre() = default;
    
    //reconsider this mechanism for generating output data
    Cuhre(double* hostRegionsIntegral, double* hostRegionsError, double* hostRegions, double* hostRegionsLength, size_t numToStore){
        output = true;
        OutputRegionsIntegral = hostRegionsIntegral;
        OutputRegionsError = hostRegionsError;
        OutputRegions = hostRegions;
        OutputRegionsLength = hostRegionsLength;
        numOutputRegions = numToStore;
    }
    
    void GenerateSubRegionOutput(ViewVectorDouble dRegionsIntegral, ViewVectorDouble dRegionsError, ViewVectorDouble dRegions, ViewVectorDouble dRegionsLength){
        if(output == false)
            return;
        
        ViewVectorDouble::HostMirror RegionsIntegral = Kokkos::create_mirror_view(dRegionsIntegral);
        ViewVectorDouble::HostMirror RegionsError = Kokkos::create_mirror_view(dRegionsError);
        ViewVectorDouble::HostMirror Regions = Kokkos::create_mirror_view(dRegions);
        ViewVectorDouble::HostMirror RegionsLength = Kokkos::create_mirror_view(dRegionsLength);
        
		Kokkos::deep_copy(RegionsIntegral, dRegionsIntegral);
		Kokkos::deep_copy(RegionsError, dRegionsError);
		Kokkos::deep_copy(Regions, dRegions);
		Kokkos::deep_copy(RegionsLength, dRegionsLength);
		
        for(int regID = 0; regID < numOutputRegions; regID++){
            OutputRegionsIntegral[regID] = RegionsIntegral(regID);
            OutputRegionsError[regID] = RegionsError(regID);       
            //printf("Storing at cpu side:%.15f +- %.15f\n", RegionsIntegral(regID), RegionsError(regID));
        }
        
        for(int index = 0; index < numOutputRegions * NDIM; index++){
            OutputRegions[index] = Regions(index);
            OutputRegionsLength[index] = RegionsLength(index);
            //printf("Storing at cpu side:%.15f +- %.15f\n", Regions(index), RegionsLength(index));
        }
    }
    
    template <typename IntegT>
    cuhreResult
    Integrate(IntegT _integrand, 
              double epsrel, 
              double epsabs, 
			  int heuristicID = 0,
			  size_t maxIters = 500,
              double* hRegs = nullptr, 
              double* hRegsLength = nullptr, 
              Volume<T, NDIM>* volume = nullptr){
        cuhreResult res; 
        
        Kernel<double, NDIM> kernel;      
        ViewVectorDouble dRegions("dRegions", NDIM);
        ViewVectorDouble dRegionsLength("dRegionsLength", NDIM);
            
        ViewVectorDouble dRegionsIntegral;
        ViewVectorDouble dRegionsError;
        
        ViewVectorDouble dParentsIntegral;
        ViewVectorDouble dParentsError;
        
        //Kokkos::Profiling::pushRegion("GenerateInitialRegions");
        kernel.GenerateInitialRegions(dRegions, dRegionsLength);
        //Kokkos::Profiling::popRegion();
        
        kernel.IntegrateFirstPhase(_integrand, 
                                    epsrel, 
                                    epsabs, 
									heuristicID,
                                    res.estimate,
                                    res.errorest,
                                    res.nregions,
									res.nFinishedRegions,
                                    res.status,
									maxIters,
                                    dRegions, 
                                    dRegionsLength, 
                                    dRegionsIntegral, 
                                    dRegionsError,
                                    dParentsIntegral,
                                    dParentsError);
                                    
        //printf("Result.status:%i\n", res.status);                       
        GenerateSubRegionOutput(dRegionsIntegral, dRegionsError, dRegions, dRegionsLength);
		return res;
    }
    
};

#endif