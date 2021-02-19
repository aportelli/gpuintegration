#include "cuba.h"
#include "cubacpp/cuhre.hh"
#include "demo_utils.h"

#include <cmath>
#include <iostream>

using std::cout;
using std::chrono::high_resolution_clock;
using std::chrono::duration;

#include <chrono>
#include <cmath>
#include <iomanip>
#include <iostream>

using std::cout;
using std::chrono::high_resolution_clock;
using std::chrono::duration;

template <typename ALG, typename F>
bool
time_and_call_alt(ALG const& a, F f, double epsrel, double correct_answer, std::string algname)
{
  using MilliSeconds = std::chrono::duration<double, std::chrono::milliseconds::period>;
  // We make epsabs so small that epsrel is always the stopping condition.
  double constexpr epsabs = 1.0e-20;
  auto t0 = std::chrono::high_resolution_clock::now();
  auto res = a.integrate(f, epsrel, epsabs);
  
  MilliSeconds dt = std::chrono::high_resolution_clock::now() - t0;
  int _final = 1;
  std::cout.precision(17); 
  std::cout<<algname<<","
		   <<correct_answer<<"," << std::scientific 
			<<epsrel<<","
			<<epsabs<<","
			<<res.value<<","
			<<res.error<<","
			<<res.nregions<<","
			<<res.status<<","
			<<_final<<","
			<<dt.count()<<std::endl;
  if(res.status == 0)
	return true;
  else
	return false;
}

double  GENZ_5_8D(double x, double y, double z, double k, double m, double n, double p, double q)
{
    double beta = .5;
    double t1 = -10.*fabs(x - beta) - 10.* fabs(y - beta) - 10.* fabs(z - beta) - 10.* fabs(k - beta) - 10.* fabs(m - beta) - 10.* fabs(n - beta) - 10.* fabs(p - beta) - 10.* fabs(q - beta);
    return exp(t1)/( 2.425217625641885e-06);
}

int main()
{
  cubacores(0, 0); // turn off the forking use in CUBA's CUHRE.
  unsigned long long constexpr maxeval = 2000 * 1000 * 1000 ;
  double const epsrel_min = 1.024e-10;
  cubacpp::Cuhre cuhre;
  cuhre.maxeval = maxeval;

  cout<<"id, value, epsrel, epsabs, estimate, errorest, regions, converge, final, total_time\n";
  
  double epsrel = 1.0e-3;
  double true_value = 1.;

  int _final = 4;
  cuhre.flags = _final;
  //time_and_call_alt<cubacpp::Cuhre, example>(cuhre, ex, epsrel, true_value, "dc_f1");
  epsrel = 1.0e-3;
  while(epsrel >= epsrel_min && time_and_call_alt(cuhre, GENZ_5_8D, epsrel, true_value, "GENZ5_8D") == true){
  
      epsrel /= 5.0;
      
  }
  return 0;
}