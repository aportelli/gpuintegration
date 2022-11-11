#include "cuda/mcubes/demos/demo_utils.cuh"
#include "cuda/mcubes/vegasT.cuh"

class GENZ_6_6D {
public:
  __host__ __device__ double
  operator()(double u, double v, double w, double x, double y, double z)
  {
    if (z > .9 || y > .8 || x > .7 || w > .6 || v > .5 || u > .4)
      return 0.;
    else
      return exp(10. * z + 9. * y + 8. * x + 7. * w + 6. * v +
                 5. * u) /*/1.5477367885091207413e8*/;
  }
};

int
main(int argc, char** argv)
{
  double epsrel = 1e-3;
  constexpr int ndim = 6;

  double ncall = 1.0e8;
  int titer = 1;
  int itmax = 1;
  int skip = 0;
  VegasParams params(ncall, titer, itmax, skip);
  double true_value = 1.5477367885091207413e8;
  
  double lows[] = {0., 0., 0., 0., 0., 0.};
  double highs[] = {1., 1., 1., 1., 1., 1.};
  quad::Volume<double, ndim> volume(lows, highs);
  
  GENZ_6_6D integrand;
  std::array<double, 6> required_ncall = {1.e5, 1.e6, 1.e7, 1.e8, 1.e9, 2.e9};
  size_t run = 0;
  
  for(auto num_samples : required_ncall){
    params.ncall = num_samples;
    
	signle_invocation_time_and_call<GENZ_6_6D, ndim>(
        integrand, epsrel, true_value, "f6, 6", params, &volume);
	run++;
	if(run > required_ncall.size())
		break;
  }

  return 0;
}
