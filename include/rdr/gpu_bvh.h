#pragma once
#include <cstdint>
namespace renderer {
struct GpuBvhPrimitive {
  float lower[3]{};
  float upper[3]{};
  std::uint32_t original_index = -1;
};
struct GpuBvhNode {
  int parent_index;
  int left_index;
  int right_index;
  float lower[3]{};
  float upper[3]{};
};

bool buildGpuBvh(const GpuBvhPrimitive *host_primitives, std::uint32_t count,
    GpuBvhNode *host_nodes, std::uint32_t *host_primitives_indices);
}  // namespace renderer