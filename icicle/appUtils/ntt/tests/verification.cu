
#define CURVE_ID BLS12_381

#include "primitives/field.cuh"
#include "primitives/projective.cuh"
#include "utils/cuda_utils.cuh"
#include <chrono>
#include <iostream>
#include <vector>

#include "curves/curve_config.cuh"
#include "ntt/ntt.cu"
#include "ntt/ntt_impl.cuh"
#include <memory>

typedef curve_config::scalar_t test_scalar;
typedef curve_config::scalar_t test_data;
#include "kernel_ntt.cu"

void random_samples(test_data* res, uint32_t count)
{
  for (int i = 0; i < count; i++)
    res[i] = i < 1000 ? test_data::rand_host() : res[i - 1000];
}

void incremental_values(test_scalar* res, uint32_t count)
{
  for (int i = 0; i < count; i++) {
    res[i] = i ? res[i - 1] + test_scalar::one() * test_scalar::omega(4) : test_scalar::zero();
  }
}

int main(int argc, char** argv)
{
  cudaEvent_t icicle_start, icicle_stop, new_start, new_stop;
  float icicle_time, new_time;

  int NTT_LOG_SIZE = (argc > 1) ? atoi(argv[1]) : 19; // assuming second input is the log-size
  int NTT_SIZE = 1 << NTT_LOG_SIZE;
  bool INPLACE = (argc > 2) ? atoi(argv[2]) : true;
  int INV = (argc > 3) ? atoi(argv[3]) : true;

  const ntt::Ordering ordering = ntt::Ordering::kNN;
  const char* ordering_str = ordering == ntt::Ordering::kNN   ? "NN"
                             : ordering == ntt::Ordering::kNR ? "NR"
                             : ordering == ntt::Ordering::kRN ? "RN"
                                                              : "RR";

  printf("running ntt 2^%d, ordering=%s, inplace=%d, inverse=%d\n", NTT_LOG_SIZE, ordering_str, INPLACE, INV);

  cudaFree(nullptr); // init GPU context (warmup)

  // init domain
  auto ntt_config = ntt::DefaultNTTConfig<test_scalar>();
  ntt_config.ordering = ordering;
  ntt_config.are_inputs_on_device = true;
  ntt_config.are_outputs_on_device = true;

  CHK_IF_RETURN(cudaEventCreate(&icicle_start));
  CHK_IF_RETURN(cudaEventCreate(&icicle_stop));
  CHK_IF_RETURN(cudaEventCreate(&new_start));
  CHK_IF_RETURN(cudaEventCreate(&new_stop));

  auto start = std::chrono::high_resolution_clock::now();
  const test_scalar basic_root = test_scalar::omega(NTT_LOG_SIZE);
  ntt::InitDomain(basic_root, ntt_config.ctx);
  auto stop = std::chrono::high_resolution_clock::now();
  auto duration = std::chrono::duration_cast<std::chrono::microseconds>(stop - start).count();
  std::cout << "initDomain took: " << duration / 1000 << " MS" << std::endl;

  // cpu allocation
  auto CpuScalars = std::make_unique<test_data[]>(NTT_SIZE);
  auto CpuOutputOld = std::make_unique<test_data[]>(NTT_SIZE);
  auto CpuOutputNew = std::make_unique<test_data[]>(NTT_SIZE);

  // gpu allocation
  test_data *GpuScalars, *GpuOutputOld, *GpuOutputNew;
  CHK_IF_RETURN(cudaMalloc(&GpuScalars, sizeof(test_data) * NTT_SIZE));
  CHK_IF_RETURN(cudaMalloc(&GpuOutputOld, sizeof(test_data) * NTT_SIZE));
  CHK_IF_RETURN(cudaMalloc(&GpuOutputNew, sizeof(test_data) * NTT_SIZE));

  // init inputs
  incremental_values(CpuScalars.get(), NTT_SIZE);
  CHK_IF_RETURN(cudaMemcpy(GpuScalars, CpuScalars.get(), NTT_SIZE, cudaMemcpyHostToDevice));

  // inplace
  if (INPLACE) {
    CHK_IF_RETURN(cudaMemcpy(GpuOutputNew, GpuScalars, NTT_SIZE * sizeof(test_data), cudaMemcpyDeviceToDevice));
  }

  // run ntt
  auto benchmark = [&](bool is_print, int iterations) -> cudaError_t {
    // NEW
    CHK_IF_RETURN(cudaEventRecord(new_start, ntt_config.ctx.stream));
    ntt_config.is_force_radix2 = false; // mixed-radix ntt (a.k.a new ntt)
    for (size_t i = 0; i < iterations; i++) {
      ntt::NTT(
        INPLACE ? GpuOutputNew : GpuScalars, NTT_SIZE, INV ? ntt::NTTDir::kInverse : ntt::NTTDir::kForward, ntt_config,
        GpuOutputNew);
    }
    CHK_IF_RETURN(cudaEventRecord(new_stop, ntt_config.ctx.stream));
    CHK_IF_RETURN(cudaStreamSynchronize(ntt_config.ctx.stream));
    CHK_IF_RETURN(cudaEventElapsedTime(&new_time, new_start, new_stop));
    if (is_print) { fprintf(stderr, "cuda err %d\n", cudaGetLastError()); }

    // OLD
    CHK_IF_RETURN(cudaEventRecord(icicle_start, ntt_config.ctx.stream));
    ntt_config.is_force_radix2 = true;
    for (size_t i = 0; i < iterations; i++) {
      ntt::NTT(GpuScalars, NTT_SIZE, INV ? ntt::NTTDir::kInverse : ntt::NTTDir::kForward, ntt_config, GpuOutputOld);
    }
    CHK_IF_RETURN(cudaEventRecord(icicle_stop, ntt_config.ctx.stream));
    CHK_IF_RETURN(cudaStreamSynchronize(ntt_config.ctx.stream));
    CHK_IF_RETURN(cudaEventElapsedTime(&icicle_time, icicle_start, icicle_stop));
    if (is_print) { fprintf(stderr, "cuda err %d\n", cudaGetLastError()); }

    if (is_print) {
      printf("Old Runtime=%0.3f MS\n", icicle_time / iterations);
      printf("New Runtime=%0.3f MS\n", new_time / iterations);
    }

    return CHK_LAST();
  };

  CHK_IF_RETURN(benchmark(false /*=print*/, 1)); // warmup
  int count = INPLACE ? 1 : 10;
  if (INPLACE) {
    CHK_IF_RETURN(cudaMemcpy(GpuOutputNew, GpuScalars, NTT_SIZE * sizeof(test_data), cudaMemcpyDeviceToDevice));
  }
  CHK_IF_RETURN(benchmark(true /*=print*/, count));

  // verify
  CHK_IF_RETURN(cudaMemcpy(CpuOutputNew.get(), GpuOutputNew, NTT_SIZE * sizeof(test_data), cudaMemcpyDeviceToHost));
  CHK_IF_RETURN(cudaMemcpy(CpuOutputOld.get(), GpuOutputOld, NTT_SIZE * sizeof(test_data), cudaMemcpyDeviceToHost));

  bool success = true;
  for (int i = 0; i < NTT_SIZE; i++) {
    if (CpuOutputNew[i] != CpuOutputOld[i]) {
      success = false;
      // std::cout << i << " ref " << CpuOutputOld[i] << " != " << CpuOutputNew[i] << std::endl;
      break;
    } else {
      // std::cout << i << " ref " << CpuOutputOld[i] << " == " << CpuOutputNew[i] << std::endl;
      // break;
    }
  }
  const char* success_str = success ? "SUCCESS!" : "FAIL!";
  printf("%s\n", success_str);

  CHK_IF_RETURN(cudaFree(GpuScalars));
  CHK_IF_RETURN(cudaFree(GpuOutputOld));
  CHK_IF_RETURN(cudaFree(GpuOutputNew));

  return CHK_LAST();
}