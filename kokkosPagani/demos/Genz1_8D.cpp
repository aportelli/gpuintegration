#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "func.cuh"
#include "Cuhre.cuh"
#include "Rule.cuh"
#include "demo_utils.cuh"

class GENZ_1_8D{
    public:
  __device__ __host__ double
  operator()(double s,
             double t,
             double u,
             double v,
             double w,
             double x,
             double y,
             double z)
  {
    return cos(s + 2. * t + 3. * u + 4. * v + 5. * w + 6. * x +
                               7. * y + 8. * z);
  }
};

int main(int argc, char **argv)
{   
    Kokkos::initialize(); 
    {
        GENZ_1_8D integrand;
        int heuristicID = 1;
		double epsrel = 1.0e-3;
		double epsabs = 1.0e-12;
		double epsrel_min = 1.0e-10;
		double true_value = (1. / 315.) * sin(1.) * sin(3. / 2.) * sin(2.) * sin(5. / 2.) *
               sin(3.) * sin(7. / 2.) * sin(4.) *
               (sin(37. / 2.) - sin(35. / 2.));
        const int ndim = 8;
        while (time_and_call<GENZ_1_8D, ndim>("GENZ_1_8D", integrand,
            epsrel, true_value, std::cout, heuristicID) == true && epsrel >= epsrel_min) {
            epsrel /= 5.0;
        }
    }
    Kokkos::finalize();  
	return 0;
}