#ifndef ALTERNATIVE_TIME_AND_CALL_CUH
#define ALTERNATIVE_TIME_AND_CALL_CUH

#include <CL/sycl.hpp>
#include <dpct/dpct.hpp>
#include <chrono>
#include "oneAPI/pagani/quad/GPUquad/PaganiUtils.dp.hpp"
#include "oneAPI/pagani/quad/GPUquad/Workspace.dp.hpp"
#include "oneAPI/pagani/quad/util/cuhreResult.dp.hpp"
#include "oneAPI/pagani/quad/util/Volume.dp.hpp"

/*
    we are not keeping track of nFinished regions
    id, ndim, true_val, epsrel, epsabs, estimate, errorest, nregions, nFinishedRegions, status, time
*/

template <typename F, int ndim, bool use_custom = false, int debug = 0>
bool
clean_time_and_call(std::string id,
                 F integrand,
                 double epsrel,
                 double true_value,
                 char const* algname,
                 std::ostream& outfile,
                 bool relerr_classification = true)
{
    
    auto print_custom = [=](bool use_custom_flag){
	  std::string to_print = use_custom_flag == true ? "custom" : "library";
	  return to_print;
  };  
    
  using MilliSeconds =
    std::chrono::duration<double, std::chrono::milliseconds::period>;
    
  double constexpr epsabs = 1.0e-40;
  bool good = false;
  Workspace<ndim, use_custom> workspace;
  quad::Volume<double, ndim> vol;
  
  for(int i=0; i < 11; i++){
	auto const t0 = std::chrono::high_resolution_clock::now();
	size_t partitions_per_axis = 2;   
	if(ndim < 5)
		partitions_per_axis = 4;
	else if(ndim <= 10)
		partitions_per_axis = 2;
	else
		partitions_per_axis = 1;
	Sub_regions<ndim> sub_regions(partitions_per_axis);
	//sub_regions.uniform_split(partitions_per_axis);
    constexpr bool collect_iters = false;
    constexpr bool collect_sub_regions = false;
    constexpr bool predict_split = false;
	cuhreResult<double> result = workspace.template integrate< F, predict_split, collect_iters, collect_sub_regions, debug>(integrand, sub_regions, epsrel, epsabs, vol, relerr_classification);
	MilliSeconds dt = std::chrono::high_resolution_clock::now() - t0;
	double const absolute_error = std::abs(result.estimate - true_value);
  
	if (result.status == 0) {
		good = true;
	}

	outfile.precision(17);
    if(i != 0.)
        outfile << std::fixed << std::scientific 
          << "pagani" << ","
          << id  << ","
          << ndim << ","
          << print_custom(use_custom) << ","
          << true_value  << "," << epsrel  << ","
          << epsabs << ","
          << result.estimate << ","
          << result.errorest << ","
          << result.nregions << ","
          << result.nFinishedRegions << ","
          << result.status << ","
          << dt.count() << std::endl;
	
  }
  return good;
}

void
print_header(){
    std::cout<<"id, ndim, integral, epsrel, epsabs, estimate, errorest, nregions, status, time\n";
}



#endif