#ifndef HYBRID_CUH
#define HYBRID_CUH

#include <CL/sycl.hpp>
#include <dpct/dpct.hpp>
#include <iostream>

// #include "cuda/pagani/quad/GPUquad/Sub_regions.cuh"
#include "dpct-exp/cuda/pagani/quad/GPUquad/Region_characteristics.dp.hpp"
#include "dpct-exp/cuda/pagani/quad/GPUquad/Region_estimates.dp.hpp"
#include "dpct-exp/cuda/pagani/quad/GPUquad/Phases.dp.hpp"

template <typename T, size_t ndim>
void
two_level_errorest_and_relerr_classify(
  Region_estimates<T, ndim>* current_iter_raw_estimates,
  const Region_estimates<T, ndim>* prev_iter_two_level_estimates,
  const Region_characteristics<ndim>* reg_classifiers,
  T epsrel,
  bool relerr_classification = true)
{
  dpct::device_ext& dev_ct1 = dpct::get_current_device();
  sycl::queue& q_ct1 = dev_ct1.default_queue();

  size_t num_regions = current_iter_raw_estimates->size;
  size_t block_size = 64;
  size_t numBlocks =
    num_regions / block_size + ((num_regions % block_size) ? 1 : 0);
  bool forbid_relerr_classification = !relerr_classification;
  if (prev_iter_two_level_estimates->size == 0) {
    return;
  }

  T* new_two_level_errorestimates = quad::cuda_malloc<T>(num_regions);
  /*
  DPCT1049:111: The workgroup size passed to the SYCL kernel may exceed the
  limit. To get the device limit, query info::device::max_work_group_size.
  Adjust the workgroup size if needed.
  */
  q_ct1.parallel_for(
    sycl::nd_range(sycl::range(1, 1, numBlocks) * sycl::range(1, 1, block_size),
                   sycl::range(1, 1, block_size)),
    [=](sycl::nd_item<3> item_ct1) {
      quad::RefineError<T>(current_iter_raw_estimates->integral_estimates,
                     current_iter_raw_estimates->error_estimates,
                     prev_iter_two_level_estimates->integral_estimates,
                     prev_iter_two_level_estimates->error_estimates,
                     new_two_level_errorestimates,
                     reg_classifiers->active_regions,
                     num_regions,
                     epsrel,
                     forbid_relerr_classification,
                     item_ct1);
    });

  dev_ct1.queues_wait_and_throw();
  sycl::free(current_iter_raw_estimates->error_estimates, q_ct1);
  current_iter_raw_estimates->error_estimates = new_two_level_errorestimates;
}

template <typename T, size_t ndim>
void
computute_two_level_errorest(
  Region_estimates<T, ndim>& current_iter_raw_estimates,
  const Region_estimates<T, ndim>& prev_iter_two_level_estimates,
  Region_characteristics<ndim>& reg_classifiers,
  bool relerr_classification = true)
{
  dpct::device_ext& dev_ct1 = dpct::get_current_device();
  sycl::queue& q_ct1 = dev_ct1.default_queue();

  size_t num_regions = current_iter_raw_estimates.size;
  T epsrel = 1.e-3;
  size_t block_size = 64;
  size_t numBlocks =
    num_regions / block_size + ((num_regions % block_size) ? 1 : 0);
  bool forbid_relerr_classification = !relerr_classification;
  if (prev_iter_two_level_estimates.size == 0) {
    return;
  }

  T* new_two_level_errorestimates = quad::cuda_malloc<T>(num_regions);
  /*
  DPCT1049:112: The workgroup size passed to the SYCL kernel may exceed the
  limit. To get the device limit, query info::device::max_work_group_size.
  Adjust the workgroup size if needed.
  */
  q_ct1.parallel_for(
    sycl::nd_range(sycl::range(1, 1, numBlocks) * sycl::range(1, 1, block_size),
                   sycl::range(1, 1, block_size)),
    [=](sycl::nd_item<3> item_ct1) {
      RefineError<T>(current_iter_raw_estimates.integral_estimates,
                     current_iter_raw_estimates.error_estimates,
                     prev_iter_two_level_estimates.integral_estimates,
                     prev_iter_two_level_estimates.error_estimates,
                     new_two_level_errorestimates,
                     reg_classifiers.active_regions,
                     num_regions,
                     epsrel,
                     forbid_relerr_classification,
                     item_ct1);
    });

  dev_ct1.queues_wait_and_throw();
  sycl::free(current_iter_raw_estimates.error_estimates, q_ct1);
  current_iter_raw_estimates.error_estimates = new_two_level_errorestimates;
}
#endif