//#include <CL/sycl.hpp>
//#include <oneapi/dpl/execution>
//#include <oneapi/dpl/async>
#include <CL/sycl.hpp>
//#include <dpct/dpct.hpp>
#include "oneAPI/mcubes/demo_utils.dp.hpp"
#include "oneAPI/mcubes/vegasT.dp.hpp"
#include "common/oneAPI/integrands.hpp"

int
main(int argc, char** argv)
{
  int num_repeats = argc > 1 ? std::stoi(argv[1]) : 100;
  double epsrel = 1e-3;
  double epsrel_min = 1.e-9;
  constexpr int ndim = 8;

  double ncall = 1.0e8;
  int titer = 1;
  int itmax = 1;
  int skip = 0;
  VegasParams params(ncall, titer, itmax, skip);
  double true_value = 1.286889807581113e+13;
  
  double lows[] = {0., 0., 0., 0., 0., 0., 0., 0.};
  double highs[] = {1., 1., 1., 1., 1., 1., 1., 1.};
  quad::Volume<double, ndim> volume(lows, highs);
  
  F_2_8D integrand;
  std::array<double, 4> required_ncall = {1.e8, 1.e9, 2.e9, 3.e9};
   
  bool success = false;  
  size_t num_epsrels = 10;
  size_t run = 0;
  
  for(auto num_samples : required_ncall){
    params.ncall = num_samples;
    
	signle_invocation_time_and_call<F_2_8D, ndim>(
        integrand, epsrel, true_value, "f2, 8", params, &volume, num_repeats);
	run++;
	if(run > required_ncall.size())
		break;
  }

  return 0;
}
