#ifndef CUDACUHRE_QUAD_UTIL_CUDA_UTIL_H
#define CUDACUHRE_QUAD_UTIL_CUDA_UTIL_H

#include <CL/sycl.hpp>
#include <dpct/dpct.hpp>
#include "dpct-exp/cuda/pagani/quad/quad.h"
#include "dpct-exp/common/cuda/cudaDebugUtil.h"

#include <float.h>
#include <stdio.h>

#include "dpct-exp/cuda/pagani/quad/deviceProp.h"
#include <cmath>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

void
warmUpKernel()
{}

#define INFTY DBL_MAX
#define Zap(d) memset(d, 0, sizeof(d))

inline double
MaxErr(double avg, double epsrel, double epsabs)
{
  return sycl::max(epsrel * sycl::fabs(avg), epsabs);
}

#endif
