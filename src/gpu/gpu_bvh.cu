#include <cuda_runtime.h>
#include <thrust/execution_policy.h>
#include <thrust/sort.h>

#include <algorithm>

#include "rdr/gpu_bvh.h"
#include "rdr/math_aliases.h"

namespace renderer {
struct CentroidBounds {
  float lower[3]{};
  float upper[3]{};
};
void computeCentroidBounds(const GpuBvhPrimitive *primitives,
    std::uint32_t count, float lower[3], float upper[3]) {
  for (int i = 0; i < 3; ++i) {
    auto center = (primitives[0].lower[i] + primitives[0].upper[i]) * 0.5f;
    lower[i]    = center;
    upper[i]    = center;
  }
  for (int i = 1; i < count; ++i) {
    for (int dim = 0; dim < 3; ++dim) {
      float center =
          (primitives[i].lower[dim] + primitives[i].upper[dim]) * 0.5f;
      lower[dim] = center < lower[dim] ? center : lower[dim];
      upper[dim] = center > upper[dim] ? center : upper[dim];
    }
  }
}

__device__ std::uint32_t quantizeCoordinate(
    float center, float center_min, float center_max) {
  if (center_min == center_max) return 0;
  auto s = (center - center_min) / (center_max - center_min);
  if (s == 1) return 1023;
  return static_cast<std::uint32_t>(s * 1024.0f);
}

__device__ std::uint32_t morton3D(
    std::uint32_t qx, std::uint32_t qy, std::uint32_t qz) {
  std::uint32_t bit = 0;
  for (int i = 0; i < 10; ++i) {
    auto x_pos      = (qx >> i) & 1u;
    auto y_pos      = (qy >> i) & 1u;
    auto z_pos      = (qz >> i) & 1u;
    auto x_position = (i + 1) * 3 - 1;
    bit |= x_pos << x_position;
    bit |= y_pos << x_position - 1;
    bit |= z_pos << x_position - 2;
  }
  return bit;
}
// 注意，sorted_codes里面一共会有count个不同的对象
// 每个对象会有30个0/1结构，因为之前构建的是x，y，z是10+10+10的结构
// 对于处理两个对象morton编码相同的排序情况
// 是通过前32位记录morton编码，后32位记录位置编码
__device__ int commonPrefixLength(
    const std::uint32_t *sorted_codes, std::uint32_t count, int i, int j) {
  if (i < 0 || j < 0 || i >= count || j >= count) {
    return -1;
  }
  auto code_i     = sorted_codes[i];
  auto code_j     = sorted_codes[j];
  auto difference = code_i ^ code_j;
  auto num        = __clz(difference);
  if (num == 32) {
    std::uint32_t position_difference = i ^ j;
    num += __clz(position_difference);
  }
  return num;
}
__global__ void initializeBvhLeaves(const GpuBvhPrimitive *primitives,
    const std::uint32_t *primitive_indices, std::uint32_t count,
    GpuBvhNode *out_nodes) {
  std::uint32_t thread_index = blockIdx.x * blockDim.x + threadIdx.x;
  if (thread_index >= count) return;
  auto primitive_index = primitive_indices[thread_index];
  auto leaf_index      = thread_index + count - 1;
  for (int dim = 0; dim < 3; ++dim) {
    out_nodes[leaf_index].lower[dim] = primitives[primitive_index].lower[dim];
    out_nodes[leaf_index].upper[dim] = primitives[primitive_index].upper[dim];
  }
  out_nodes[leaf_index].left_index  = -1;
  out_nodes[leaf_index].right_index = -1;
}
__device__ void mergeNodeBounds(GpuBvhNode *out_nodes, int parent_index) {
  auto left_index      = out_nodes[parent_index].left_index;
  auto right_index     = out_nodes[parent_index].right_index;
  auto box_left_lower  = out_nodes[left_index].lower;
  auto box_left_upper  = out_nodes[left_index].upper;
  auto box_right_lower = out_nodes[right_index].lower;
  auto box_right_upper = out_nodes[right_index].upper;
  for (int dim = 0; dim < 3; ++dim) {
    out_nodes[parent_index].lower[dim] =
        box_left_lower[dim] < box_right_lower[dim] ? box_left_lower[dim]
                                                   : box_right_lower[dim];
    out_nodes[parent_index].upper[dim] =
        box_left_upper[dim] < box_right_upper[dim] ? box_right_upper[dim]
                                                   : box_left_upper[dim];
  }
}

__global__ void reduceBvhBounds(
    GpuBvhNode *out_nodes, std::uint32_t count, int *arrival_counts) {
  std::uint32_t thread_index = blockIdx.x * blockDim.x + threadIdx.x;
  if (thread_index >= count) return;
  auto node_index = count - 1 + thread_index;
  while (node_index != 0) {
    auto parent_index = out_nodes[node_index].parent_index;
    if (parent_index == -1) return;
    // 四个参数依次是计数地址，增量1，内存顺序，同步范围，返回加1前的int值
    //__NV_ATOMIC_ACQ_REL让第二个打到的线程能够读取第一个线程此前写好的盒
    //__NV_THREAD_SCOPE_DEVICE让这个保证覆盖不同线程块
    const int old_count = __nv_atomic_fetch_add(&arrival_counts[parent_index],
        1, __NV_ATOMIC_ACQ_REL, __NV_THREAD_SCOPE_DEVICE);
    if (old_count == 0) return;
    if (old_count == 1) mergeNodeBounds(out_nodes, parent_index);
    node_index = parent_index;
  }
  return;
}
__device__ int binarySearch(const std::uint32_t *sorted_codes,
    std::uint32_t count, int i, int direction, int target, int left,
    int right) {
  int mid = (left + right) / 2;
  if (right - left <= 1) return left;
  if (commonPrefixLength(sorted_codes, count, i, i + mid * direction) >
      target) {
    return binarySearch(sorted_codes, count, i, direction, target, mid, right);
  }
  return binarySearch(sorted_codes, count, i, direction, target, left, mid);
}

__global__ void buildBvhTopology(const std::uint32_t *sorted_codes,
    std::uint32_t count, GpuBvhNode *out_nodes) {
  std::uint32_t thread_index = blockIdx.x * blockDim.x + threadIdx.x;
  if (thread_index == 0 && count > 0) {
    out_nodes[0].parent_index = -1;  // 没有父节点
  }
  if (count < 2 || thread_index >= count - 1) return;
  const int i              = static_cast<int>(thread_index);
  auto left                = commonPrefixLength(sorted_codes, count, i, i - 1);
  auto right               = commonPrefixLength(sorted_codes, count, i, i + 1);
  auto direction           = left > right ? -1 : 1;
  const int outside_prefix = direction == -1 ? right : left;
  int lo                   = 0;
  int hi                   = 1;
  // Karras的搜索方法是先用倍增探测圈出端点所在的范围，再用二分查找定位端点
  while (commonPrefixLength(sorted_codes, count, i, i + direction * hi) >
         outside_prefix) {
    lo = hi;
    hi *= 2;
  }
  auto distance =
      binarySearch(sorted_codes, count, i, direction, outside_prefix, lo, hi);
  const int j = i + distance * direction;
  auto first  = i > j ? j : i;
  auto last   = i > j ? i : j;
  auto target = commonPrefixLength(sorted_codes, count, first, last);
  auto split  = first + binarySearch(sorted_codes, count, first, 1, target, 0,
                            last - first);
  auto leaf_base = count - 1;
  // 叶节点
  if (first == split)
    out_nodes[i].left_index = leaf_base + split;
  else  // 内部节点
    out_nodes[i].left_index = split;
  if (split + 1 == last)
    out_nodes[i].right_index = leaf_base + split + 1;
  else
    out_nodes[i].right_index = split + 1;
  out_nodes[out_nodes[i].left_index].parent_index  = i;
  out_nodes[out_nodes[i].right_index].parent_index = i;
}
// global表示这是gpu执行的入口函数，之后由CPU启动一批线程执行它，计算结果写入两个数组
__global__ void computeMortonCodes(const GpuBvhPrimitive *primitives,
    std::uint32_t count, CentroidBounds center_bounds,
    std::uint32_t *morton_codes, std::uint32_t *primitive_indices) {
  // blockIdx.x是当前线程块的编号
  // blockDim.x是每个线程块包含了多少线程
  // threadIdx.x是当前线程在块内的编号
  // 等价于[blockIdx,threadIdx]
  std::uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i >= count) return;
  auto center_x   = (primitives[i].lower[0] + primitives[i].upper[0]) / 2.0f;
  auto center_y   = (primitives[i].lower[1] + primitives[i].upper[1]) / 2.0f;
  auto center_z   = (primitives[i].lower[2] + primitives[i].upper[2]) / 2.0f;
  auto quantize_x = quantizeCoordinate(
      center_x, center_bounds.lower[0], center_bounds.upper[0]);
  auto quantize_y = quantizeCoordinate(
      center_y, center_bounds.lower[1], center_bounds.upper[1]);
  auto quantize_z = quantizeCoordinate(
      center_z, center_bounds.lower[2], center_bounds.upper[2]);
  auto morton          = morton3D(quantize_x, quantize_y, quantize_z);
  morton_codes[i]      = morton;
  primitive_indices[i] = primitives[i].original_index;
}
// 第一个参数是CPU输入数组，包含count个对象记录
// 第，四三个参数是CPU输出地址
cudaError_t buildGpuBvhImpl(const GpuBvhPrimitive *host_primitives,
    std::uint32_t count, GpuBvhNode *host_nodes,
    std::uint32_t *host_primitive_indices) {
  if (count == 0) return cudaSuccess;
  CentroidBounds center_bounds;
  computeCentroidBounds(
      host_primitives, count, center_bounds.lower, center_bounds.upper);
  GpuBvhPrimitive *d_primitives = nullptr;
  std::uint32_t *d_morton_codes = nullptr;
  std::uint32_t *d_primitives_indices =
      nullptr;  // 保存每个排序位置对应的原始对象下标
  int *d_arrival_counts = nullptr;
  cudaError_t status =
      cudaMalloc(&d_morton_codes, count * sizeof(std::uint32_t));
  if (status != cudaSuccess) return status;
  status = cudaMalloc(&d_primitives, count * sizeof(GpuBvhPrimitive));
  if (status != cudaSuccess) {
    cudaFree(d_morton_codes);
    return status;
  }
  status = cudaMalloc(&d_primitives_indices, count * sizeof(std::uint32_t));
  if (status != cudaSuccess) {
    cudaFree(d_morton_codes);
    cudaFree(d_primitives);
    return status;
  }
  // 到这里说明三次分配显存都成功了
  status = cudaMemcpy(d_primitives, host_primitives,
      count * sizeof(GpuBvhPrimitive), cudaMemcpyHostToDevice);
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    return status;
  }
  const std::uint32_t threads_per_block = 128;
  const std::uint32_t block_count =
      (count + threads_per_block - 1) / threads_per_block;
  computeMortonCodes<<<block_count, threads_per_block>>>(
      d_primitives, count, center_bounds, d_morton_codes, d_primitives_indices);
  status = cudaGetLastError();  // 用于读取启动后错误的状态
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    return status;
  }
  // 这个函数会等待此前GPU函数工作完成后，报告执行期间的错误
  status = cudaDeviceSynchronize();
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    return status;
  }
  // 这里用到了其他库的thrust
  try {
    thrust::stable_sort_by_key(thrust::device, d_morton_codes,
        d_morton_codes + count, d_primitives_indices);
  } catch (...) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    return cudaErrorUnknown;
  }
  GpuBvhNode *d_nodes = nullptr;  // 保存节点的连接盒包围盒
  const std::size_t node_count =
      2 * static_cast<std::size_t>(count) - 1;  // 节点数量
  status = cudaMalloc(&d_nodes, node_count * sizeof(GpuBvhNode));
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    return status;
  }
  buildBvhTopology<<<block_count, threads_per_block>>>(
      d_morton_codes, count, d_nodes);
  status = cudaGetLastError();  // 用于读取启动后错误的状态
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    cudaFree(d_nodes);
    return status;
  }
  // 这个函数会等待此前GPU函数工作完成后，报告执行期间的错误
  status = cudaDeviceSynchronize();
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    cudaFree(d_nodes);
    return status;
  }
  initializeBvhLeaves<<<block_count, threads_per_block>>>(
      d_primitives, d_primitives_indices, count, d_nodes);
  status = cudaGetLastError();  // 用于读取启动后错误的状态
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    cudaFree(d_nodes);
    return status;
  }
  // 这个函数会等待此前GPU函数工作完成后，报告执行期间的错误
  status = cudaDeviceSynchronize();
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    cudaFree(d_nodes);
    return status;
  }
  if (count > 1) {
    auto arrival_bytes = (count - 1) * sizeof(int);
    status             = cudaMalloc(&d_arrival_counts, arrival_bytes);
    if (status != cudaSuccess) {
      cudaFree(d_primitives_indices);
      cudaFree(d_primitives);
      cudaFree(d_morton_codes);
      cudaFree(d_nodes);
      return status;
    }
    // 三个参数分别是设备地址，填充值，字节数，用于初始化arrival_bytes
    status = cudaMemset(d_arrival_counts, 0, arrival_bytes);
    if (status != cudaSuccess) {
      cudaFree(d_primitives_indices);
      cudaFree(d_primitives);
      cudaFree(d_morton_codes);
      cudaFree(d_nodes);
      cudaFree(d_arrival_counts);
      return status;
    }
    reduceBvhBounds<<<block_count, threads_per_block>>>(
        d_nodes, count, d_arrival_counts);
    status = cudaGetLastError();  // 用于读取启动后错误的状态
    if (status != cudaSuccess) {
      cudaFree(d_primitives_indices);
      cudaFree(d_primitives);
      cudaFree(d_morton_codes);
      cudaFree(d_nodes);
      cudaFree(d_arrival_counts);
      return status;
    }
    // 这个函数会等待此前GPU函数工作完成后，报告执行期间的错误
    status = cudaDeviceSynchronize();
    if (status != cudaSuccess) {
      cudaFree(d_primitives_indices);
      cudaFree(d_primitives);
      cudaFree(d_morton_codes);
      cudaFree(d_nodes);
      cudaFree(d_arrival_counts);
      return status;
    }
  }
  // 每次cudaMemcpy的四个参数都是CPU目标地址，GPU来源地址，字节数，复制方向
  status = cudaMemcpy(host_nodes, d_nodes, node_count * sizeof(GpuBvhNode),
      cudaMemcpyDeviceToHost);
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    cudaFree(d_nodes);
    cudaFree(d_arrival_counts);
    return status;
  }
  status = cudaMemcpy(host_primitive_indices, d_primitives_indices,
      count * sizeof(std::uint32_t), cudaMemcpyDeviceToHost);
  if (status != cudaSuccess) {
    cudaFree(d_primitives_indices);
    cudaFree(d_primitives);
    cudaFree(d_morton_codes);
    cudaFree(d_nodes);
    cudaFree(d_arrival_counts);
    return status;
  }
  cudaFree(d_primitives_indices);
  cudaFree(d_primitives);
  cudaFree(d_morton_codes);
  cudaFree(d_nodes);
  cudaFree(d_arrival_counts);
  return cudaSuccess;
}
bool buildGpuBvh(const GpuBvhPrimitive *host_primitives, std::uint32_t count,
    GpuBvhNode *host_nodes, std::uint32_t *host_primitive_indices) {
  return buildGpuBvhImpl(host_primitives, count, host_nodes,
             host_primitive_indices) == cudaSuccess;
}
}  // namespace renderer