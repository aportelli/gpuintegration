#include "../../cuba/include/cuba.h"
#include "../../cubacpp/cubacpp/cuhre.hh"

#include "demo_utils.h"

//#include "../cudaCuhre/quad/quad.h"

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
time_and_call_alt(ALG const& a, F f, double epsrel, double correct_answer, char const* algname)
{
  using MilliSeconds = std::chrono::duration<double, std::chrono::milliseconds::period>;
  // We make epsabs so small that epsrel is always the stopping condition.
  double constexpr epsabs = 1.0e-16;
  auto t0 = std::chrono::high_resolution_clock::now();
  auto res = a.integrate(f, epsrel, epsabs);
  MilliSeconds dt = std::chrono::high_resolution_clock::now() - t0;
  double absolute_error = std::abs(res.value - correct_answer);
  bool const good = (res.status == 0);
  int converge = !good;
  int _final = 0;
  std::cout.precision(17);
  std::cout<<"dcuhre"<<",\t"
		   <<correct_answer<<",\t"
			<<epsrel<<",\t"
			<<epsabs<<",\t"
			<<res.value<<",\t"
			<<res.error<<",\t"
			<<res.nregions<<",\t"
			<<res.status<<",\t"
			<<_final<<",\t"
			<<dt.count()<<std::endl;
  if(res.status == 0)
	return true;
  else
	return false;
}

double absCosSum5DWithoutKPlus1(double v, double w, double x, double y, double z)
  {
    return fabs(cos(4. * v + 5. * w + 6. * x + 7. * y + 8. * z) + 1.0);
  }

int main()
{
  cubacores(0, 0); // turn off the forking use in CUBA's CUHRE.
  unsigned long long constexpr maxeval = 1000 * 1000 * 1000;

  cubacpp::Cuhre cuhre;
  cuhre.maxeval = maxeval;

  cout<<"id,\t value,\t epsrel,\t epsabs,\t estimate,\t errorest,\t regions,\t converge,\t final,\t total_time\n";

  double epsrel = 1.0e-3;
  double true_value = 0.9999262476619335 ;
   while(time_and_call_alt(cuhre, absCosSum5DWithoutKPlus1, epsrel, true_value, "cuhre") == true && epsrel >= 2.56e-09)
  {
     epsrel = epsrel>=1e-6 ? epsrel / 5.0 : epsrel / 2.0;
  }
  return 0;
}