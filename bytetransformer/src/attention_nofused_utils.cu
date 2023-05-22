// Copyright 2023 Bytedance Ltd. and/or its affiliates.
/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
#include "bytetransformer/include/attention_nofused_utils.h"

namespace bytetransformer {
template <>
__global__ void add_QKV_bias<float>(float *QKV, const float *bias_QKV, float *q_buf,
                                    float *k_buf, float *v_buf, const int batch_size,
                                    const int seq_len, const int head_num,
                                    const int half_size_per_head, const bool is_roformer) {
  int batch_id = blockIdx.y;
  int seq_id = blockIdx.x;
  int head_id = threadIdx.x / half_size_per_head;
  int id = threadIdx.x % half_size_per_head;
  int src_id = (blockIdx.y * gridDim.x + blockIdx.x) * (blockDim.x * 3) + threadIdx.x;
  int trt_id = ((head_id * batch_size + batch_id) * seq_len + seq_id) * half_size_per_head + id;

  float2 q_value = ((float2 *)QKV)[src_id], q_bias = __ldg(&((float2 *)bias_QKV)[threadIdx.x]);
  float2 k_value = ((float2 *)QKV)[src_id + blockDim.x],
         k_bias = __ldg(&((float2 *)bias_QKV)[threadIdx.x + blockDim.x]);
  float2 v_value = ((float2 *)QKV)[src_id + blockDim.x * 2],
         v_bias = __ldg(&((float2 *)bias_QKV)[threadIdx.x + blockDim.x * 2]);
  q_value.x += q_bias.x, q_value.y += q_bias.y;
  k_value.x += k_bias.x, k_value.y += k_bias.y;
  v_value.x += v_bias.x, v_value.y += v_bias.y;
  // [hk:] copy out
  ((float2 *)QKV)[src_id] = q_value;
  ((float2 *)QKV)[src_id + blockDim.x] = k_value;
  ((float2 *)QKV)[src_id + blockDim.x * 2] = v_value; 

  if (is_roformer) {
    float2 ro_q = make_float2(-q_value.y, q_value.x);
    float2 ro_k = make_float2(-k_value.y, k_value.x);
    float position_enc = __fdividef(seq_id, __powf(10000.0f, __fdividef(id, half_size_per_head)));
    float sin_pos = __sinf(position_enc);
    float cos_pos = __cosf(position_enc);
    q_value.x = q_value.x * cos_pos + ro_q.x * sin_pos,
    q_value.y = q_value.y * cos_pos + ro_q.y * sin_pos;
    k_value.x = k_value.x * cos_pos + ro_k.x * sin_pos,
    k_value.y = k_value.y * cos_pos + ro_k.y * sin_pos;
  }

  ((float2 *)q_buf)[trt_id] = q_value;
  ((float2 *)k_buf)[trt_id] = k_value;
  ((float2 *)v_buf)[trt_id] = v_value;
}

template <>
__global__ void add_QKV_bias<__half>(__half *QKV, const __half *bias_QKV, __half *q_buf,
                                     __half *k_buf, __half *v_buf, const int batch_size,
                                     const int seq_len, const int head_num,
                                     const int half_size_per_head, const bool is_roformer) {
  int batch_id = blockIdx.y;
  int seq_id = blockIdx.x;
  int head_id = threadIdx.x / half_size_per_head;
  int id = threadIdx.x % half_size_per_head;
  int src_id = (blockIdx.y * gridDim.x + blockIdx.x) * (blockDim.x * 3) + threadIdx.x;
  int trt_id = ((head_id * batch_size + batch_id) * seq_len + seq_id) * half_size_per_head + id;
  half2 q_value =
      __hadd2(((half2 *)QKV)[src_id], __ldg(&((const half2 *)bias_QKV)[threadIdx.x]));
  half2 k_value = __hadd2(((half2 *)QKV)[src_id + blockDim.x],
                          __ldg(&((const half2 *)bias_QKV)[threadIdx.x + blockDim.x]));
  half2 v_value = __hadd2(((half2 *)QKV)[src_id + blockDim.x * 2],
                          __ldg(&((const half2 *)bias_QKV)[threadIdx.x + blockDim.x * 2]));
  // [hk:] copy out
  ((half2 *)QKV)[src_id] = q_value;
  ((half2 *)QKV)[src_id + blockDim.x] = k_value;
  ((half2 *)QKV)[src_id + blockDim.x * 2] = v_value;     

  if (is_roformer) {
    half2 ro_q = half2(-q_value.y, q_value.x);
    half2 ro_k = half2(-k_value.y, k_value.x);
    float position_enc = __fdividef(seq_id, __powf(10000.0f, __fdividef(id, half_size_per_head)));
    half2 sin_pos = __float2half2_rn(__sinf(position_enc));
    half2 cos_pos = __float2half2_rn(__cosf(position_enc));
    q_value = __hadd2(__hmul2(q_value, cos_pos), __hmul2(ro_q, sin_pos));
    k_value = __hadd2(__hmul2(k_value, cos_pos), __hmul2(ro_k, sin_pos));
  }

  ((half2 *)q_buf)[trt_id] = q_value;
  ((half2 *)k_buf)[trt_id] = k_value;
  ((half2 *)v_buf)[trt_id] = v_value;
}

/*
[hk:] only add kernels for bs = 1 and large dim in GLM.
*/
template <>
__global__ void add_QKV_bias_large_dim<float>(float *QKV, const float *bias_QKV, float *q_buf,
                                    float *k_buf, float *v_buf, const int batch_size,
                                    const int seq_len, const int head_num,
                                    const int half_size_per_head, const bool is_roformer) {
  int batch_id = blockIdx.y;
  int seq_id = blockIdx.x;
  int dim_bound = head_num * half_size_per_head;
#pragma unroll
  for (int i = threadIdx.x; i < dim_bound; i += blockDim.x){
    int head_id = i / half_size_per_head;
    int id = i % half_size_per_head;
    int src_id = (blockIdx.y * gridDim.x + blockIdx.x) * (dim_bound * 3) + i;
    int trt_id = ((head_id * batch_size + batch_id) * seq_len + seq_id) * half_size_per_head + id;

    float2 q_value = ((float2 *)QKV)[src_id], q_bias = __ldg(&((float2 *)bias_QKV)[i]);
    float2 k_value = ((float2 *)QKV)[src_id + dim_bound],
         k_bias = __ldg(&((float2 *)bias_QKV)[i + dim_bound]);
    float2 v_value = ((float2 *)QKV)[src_id + dim_bound * 2],
         v_bias = __ldg(&((float2 *)bias_QKV)[i + dim_bound * 2]);
    q_value.x += q_bias.x, q_value.y += q_bias.y;
    k_value.x += k_bias.x, k_value.y += k_bias.y;
    v_value.x += v_bias.x, v_value.y += v_bias.y;
  
    if (is_roformer) {
      float2 ro_q = make_float2(-q_value.y, q_value.x);
      float2 ro_k = make_float2(-k_value.y, k_value.x);
      float position_enc = __fdividef(seq_id, __powf(10000.0f, __fdividef(id, half_size_per_head)));
      float sin_pos = __sinf(position_enc);
      float cos_pos = __cosf(position_enc);
      q_value.x = q_value.x * cos_pos + ro_q.x * sin_pos,
      q_value.y = q_value.y * cos_pos + ro_q.y * sin_pos;
      k_value.x = k_value.x * cos_pos + ro_k.x * sin_pos,
      k_value.y = k_value.y * cos_pos + ro_k.y * sin_pos;
    }
    // [hk:] copy out
    ((float2 *)QKV)[src_id] = q_value;
    ((float2 *)QKV)[src_id + dim_bound] = k_value;
    ((float2 *)QKV)[src_id + dim_bound * 2] = v_value; 

    ((float2 *)q_buf)[trt_id] = q_value;
    ((float2 *)k_buf)[trt_id] = k_value;
    ((float2 *)v_buf)[trt_id] = v_value;
  }
}

template <>
__global__ void add_QKV_bias_large_dim<__half>(__half *QKV, const __half *bias_QKV, __half *q_buf,
                                     __half *k_buf, __half *v_buf, const int batch_size,
                                     const int seq_len, const int head_num,
                                     const int half_size_per_head, const bool is_roformer) {
  int batch_id = blockIdx.y;
  int seq_id = blockIdx.x;
  // half_size_per_head = 64 with hs = 128
  int dim_bound = head_num * half_size_per_head;
  // partition_size = 32;
  int partition_size = half_size_per_head / 2;
  // rotate_size = 16;
  int rotate_size = partition_size / 2;
  int hidden_size = 2 * half_size_per_head;
  half scaling_factor = __float2half(sqrtf((float)hidden_size));
  // [hk:] shmem allocated for a block to store q and k
  half2 __shared__ qk[4][64][2];
#pragma unroll
  for (int i = threadIdx.x; i < dim_bound; i += blockDim.x){
    int head_id = i / half_size_per_head;
    int id = i % half_size_per_head;
    // [hk:] data layout changed for GLM
    int j = head_id * 3 * half_size_per_head + id;
    int src_id = (blockIdx.y * gridDim.x + blockIdx.x) * (dim_bound * 3) + j;
    // int bias_id = j % dim_bound;
    // int src_id = (blockIdx.y * gridDim.x + blockIdx.x) * (dim_bound * 3) + i;
    int trt_id = ((head_id * batch_size + batch_id) * seq_len + seq_id) * half_size_per_head + id;
    half2 q_value = 
      __hadd2(((half2 *)QKV)[src_id], __ldg(&((const half2 *)bias_QKV)[j]));
    // half2 k_value = __hadd2(((half2 *)QKV)[src_id + dim_bound],
    //                       __ldg(&((const half2 *)bias_QKV)[i + dim_bound]));
    qk[head_id % 4][id][0] = q_value;
    half2 k_value = __hadd2(((half2 *)QKV)[src_id + half_size_per_head],
                          __ldg(&((const half2 *)bias_QKV)[j + half_size_per_head]));
    // half2 v_value = __hadd2(((half2 *)QKV)[src_id + dim_bound * 2],
    //                       __ldg(&((const half2 *)bias_QKV)[i + dim_bound * 2]));
    qk[head_id % 4][id][1] = k_value;
    half2 v_value = __hadd2(((half2 *)QKV)[src_id + half_size_per_head * 2],
                          __ldg(&((const half2 *)bias_QKV)[j + half_size_per_head * 2]));

    // [hk:] rotary embedding needs qk from other thread
    __syncthreads();
    // [hk:] rotary embedding for GLM 
    if (is_roformer) {
      half2 ro_q = (id % partition_size) < rotate_size ? 
        __hneg2(qk[head_id % 4][id + rotate_size][0]) : qk[head_id % 4][id - rotate_size][0];
      half2 ro_k = (id % partition_size) < rotate_size ? 
        __hneg2(qk[head_id % 4][id + rotate_size][1]) : qk[head_id % 4][id - rotate_size][1];
      int encoding_id = (id < partition_size) ? 
        ((seq_id == seq_len - 1) ? seq_id - 1 : seq_id) :
        ((seq_id == seq_len - 1) ? 1 : 0);
      float position_enc_x = 
        __fdividef(encoding_id, __powf(10000.0f, __fdividef(4 * (id % rotate_size), half_size_per_head)));
      float position_enc_y = 
        __fdividef(encoding_id, __powf(10000.0f, __fdividef(4 * (id % rotate_size) + 2, half_size_per_head)));
      half sin_pos_x = __float2half_rn(__sinf(position_enc_x));
      half cos_pos_x = __float2half_rn(__cosf(position_enc_x));
      half sin_pos_y = __float2half_rn(__sinf(position_enc_y));
      half cos_pos_y = __float2half_rn(__cosf(position_enc_y));
      q_value.x = __hadd(__hmul(q_value.x, cos_pos_x), __hmul(ro_q.x, sin_pos_x));
      q_value.y = __hadd(__hmul(q_value.y, cos_pos_y), __hmul(ro_q.y, sin_pos_y));
      k_value.x = __hadd(__hmul(k_value.x, cos_pos_x), __hmul(ro_k.x, sin_pos_x));
      k_value.y = __hadd(__hmul(k_value.y, cos_pos_y), __hmul(ro_k.y, sin_pos_y));
      // half2 ro_q = half2(-q_value.y, q_value.x);
      // half2 ro_k = half2(-k_value.y, k_value.x);
      // float position_enc = __fdividef(seq_id, __powf(10000.0f, __fdividef(id, half_size_per_head)));
      // half2 sin_pos = __float2half2_rn(__sinf(position_enc));
      // half2 cos_pos = __float2half2_rn(__cosf(position_enc));
      // q_value = __hadd2(__hmul2(q_value, cos_pos), __hmul2(ro_q, sin_pos));
      // k_value = __hadd2(__hmul2(k_value, cos_pos), __hmul2(ro_k, sin_pos));
    }
  
    // [hk:] query scaling in GLM
    half2 query_to_extract;
    query_to_extract.x = __hdiv(q_value.x, scaling_factor);
    query_to_extract.y = __hdiv(q_value.y, scaling_factor);
    // q_value.x = __hdiv(q_value.x, scaling_factor);
    // q_value.y = __hdiv(q_value.y, scaling_factor);

    // [hk:] copy out
    // ((half2 *)QKV)[src_id] = q_value;
    // ((half2 *)QKV)[src_id + dim_bound] = k_value;
    // ((half2 *)QKV)[src_id + dim_bound * 2] = v_value; 
    // can not be changed here to avoid RAW conflicts
    ((half2 *)QKV)[src_id] = query_to_extract;
    ((half2 *)QKV)[src_id + half_size_per_head] = k_value;
    ((half2 *)QKV)[src_id + half_size_per_head * 2] = v_value;  

    ((half2 *)q_buf)[trt_id] = q_value;
    ((half2 *)k_buf)[trt_id] = k_value;
    ((half2 *)v_buf)[trt_id] = v_value;
  }
}


template <>
__global__ void add_QKV_bias_padding<float>(float *QKV, const float *bias_QKV, float *q_buf,
                                            float *k_buf, float *v_buf, const int batch_size,
                                            const int seq_len, const int head_num,
                                            const int half_size_per_head, const bool is_roformer,
                                            const int *batch_idx, const int *word_idx) {
  const int batch_id = blockIdx.y;
  const int seq_id = blockIdx.x;
  int head_id = threadIdx.x / half_size_per_head;
  int id = threadIdx.x % half_size_per_head;
  int trt_id = ((head_id * batch_size + batch_id) * seq_len + seq_id) * half_size_per_head + id;
  const int batch_offset = __ldg(&batch_idx[blockIdx.y]);
  const int batch_seq_len = __ldg(&batch_idx[blockIdx.y + 1]) - batch_offset;
  if (seq_id < batch_seq_len) {
    int src_id = (batch_offset + seq_id) * (blockDim.x * 3) + threadIdx.x;
    float2 q_value = ((float2 *)QKV)[src_id], q_bias = __ldg(&((float2 *)bias_QKV)[threadIdx.x]);
    float2 k_value = ((float2 *)QKV)[src_id + blockDim.x],
           k_bias = __ldg(&((float2 *)bias_QKV)[threadIdx.x + blockDim.x]);
    float2 v_value = ((float2 *)QKV)[src_id + blockDim.x * 2],
           v_bias = __ldg(&((float2 *)bias_QKV)[threadIdx.x + blockDim.x * 2]);
    q_value.x += q_bias.x, q_value.y += q_bias.y;
    k_value.x += k_bias.x, k_value.y += k_bias.y;
    v_value.x += v_bias.x, v_value.y += v_bias.y;
    // [hk:] copy out
    ((float2 *)QKV)[src_id] = q_value;
    ((float2 *)QKV)[src_id + blockDim.x] = k_value;
    ((float2 *)QKV)[src_id + blockDim.x * 2] = v_value; 

    if (is_roformer) {
      float2 ro_q = make_float2(-q_value.y, q_value.x);
      float2 ro_k = make_float2(-k_value.y, k_value.x);
      float position_enc =
          __fdividef(seq_id, __powf(10000.0f, __fdividef(id, half_size_per_head)));
      float sin_pos = __sinf(position_enc);
      float cos_pos = __cosf(position_enc);
      q_value.x = q_value.x * cos_pos + ro_q.x * sin_pos,
      q_value.y = q_value.y * cos_pos + ro_q.y * sin_pos;
      k_value.x = k_value.x * cos_pos + ro_k.x * sin_pos,
      k_value.y = k_value.y * cos_pos + ro_k.y * sin_pos;
    }

    ((float2 *)q_buf)[trt_id] = q_value;
    ((float2 *)k_buf)[trt_id] = k_value;
    ((float2 *)v_buf)[trt_id] = v_value;
  } else {
    float2 zero = make_float2(0.0f, 0.0f);
    ((float2 *)q_buf)[trt_id] = zero;
    ((float2 *)k_buf)[trt_id] = zero;
    ((float2 *)v_buf)[trt_id] = zero;
  }
}

template <>
__global__ void add_QKV_bias_padding<__half>(__half *QKV, const __half *bias_QKV,
                                             __half *q_buf, __half *k_buf, __half *v_buf,
                                             const int batch_size, const int seq_len,
                                             const int head_num, const int half_size_per_head,
                                             const bool is_roformer, const int *batch_idx,
                                             const int *word_idx) {
  const int batch_id = blockIdx.y;
  const int seq_id = blockIdx.x;
  int head_id = threadIdx.x / half_size_per_head;
  int id = threadIdx.x % half_size_per_head;
  int trt_id = ((head_id * batch_size + batch_id) * seq_len + seq_id) * half_size_per_head + id;
  const int batch_offset = __ldg(&batch_idx[blockIdx.y]);
  const int batch_seq_len = __ldg(&batch_idx[blockIdx.y + 1]) - batch_offset;
  if (seq_id < batch_seq_len) {
    int src_id = (batch_offset + seq_id) * (blockDim.x * 3) + threadIdx.x;
    half2 q_value =
        __hadd2(((half2 *)QKV)[src_id], __ldg(&((const half2 *)bias_QKV)[threadIdx.x]));
    half2 k_value = __hadd2(((half2 *)QKV)[src_id + blockDim.x],
                            __ldg(&((const half2 *)bias_QKV)[threadIdx.x + blockDim.x]));
    half2 v_value = __hadd2(((half2 *)QKV)[src_id + blockDim.x * 2],
                            __ldg(&((const half2 *)bias_QKV)[threadIdx.x + blockDim.x * 2]));
    // [hk:] copy out
  ((half2 *)QKV)[src_id] = q_value;
  ((half2 *)QKV)[src_id + blockDim.x] = k_value;
  ((half2 *)QKV)[src_id + blockDim.x * 2] = v_value;     

    if (is_roformer) {
      half2 ro_q = half2(-q_value.y, q_value.x);
      half2 ro_k = half2(-k_value.y, k_value.x);
      float position_enc =
          __fdividef(seq_id, __powf(10000.0f, __fdividef(id, half_size_per_head)));
      half2 sin_pos = __float2half2_rn(__sinf(position_enc));
      half2 cos_pos = __float2half2_rn(__cosf(position_enc));
      q_value = __hadd2(__hmul2(q_value, cos_pos), __hmul2(ro_q, sin_pos));
      k_value = __hadd2(__hmul2(k_value, cos_pos), __hmul2(ro_k, sin_pos));
    }

    ((half2 *)q_buf)[trt_id] = q_value;
    ((half2 *)k_buf)[trt_id] = k_value;
    ((half2 *)v_buf)[trt_id] = v_value;
  } else {
    ((float *)q_buf)[trt_id] = 0.0f;
    ((float *)k_buf)[trt_id] = 0.0f;
    ((float *)v_buf)[trt_id] = 0.0f;
  }
}

template <>
__global__ void transpose<float>(const float *src, float *dst, const int batch_size,
                                 const int seq_len, const int head_num, const int size_per_head) {
  int batch_id = blockIdx.x / seq_len;
  int seq_id = blockIdx.x % seq_len;
  int head_id = threadIdx.y;
  int src_offset =
      ((head_id * batch_size + batch_id) * seq_len + seq_id) * size_per_head + threadIdx.x;
  int dst_offset = (blockIdx.x * head_num + head_id) * size_per_head + threadIdx.x;
  dst[dst_offset] = src[src_offset];
}

template <>
__global__ void transpose<__half>(const __half *src, __half *dst, const int batch_size,
                                  const int seq_len, const int head_num, const int size_per_head) {
  int batch_id = blockIdx.x / seq_len;
  int seq_id = blockIdx.x % seq_len;
  int head_id = threadIdx.y;
  int src_offset =
      ((head_id * batch_size + batch_id) * seq_len + seq_id) * size_per_head + threadIdx.x;
  int dst_offset = (blockIdx.x * head_num + head_id) * size_per_head + threadIdx.x;
  ((half2 *)dst)[dst_offset] = ((const half2 *)src)[src_offset];
}

template <>
__global__ void transpose_large_dim<float>(const float *src, float *dst, const int batch_size,
                                 const int seq_len, const int head_num, const int size_per_head) {
  int batch_id = blockIdx.x / seq_len;
  int seq_id = blockIdx.x % seq_len;
  int head_id = threadIdx.y;
#pragma unroll
  for (int i = threadIdx.x; i < size_per_head; i += blockDim.x){
    int src_offset =
      ((head_id * batch_size + batch_id) * seq_len + seq_id) * size_per_head + i;
    int dst_offset = (blockIdx.x * head_num + head_id) * size_per_head + i;
    dst[dst_offset] = src[src_offset];
  }
}

template <>
__global__ void transpose_large_dim<__half>(const __half *src, __half *dst, const int batch_size,
                                  const int seq_len, const int head_num, const int size_per_head) {
  int batch_id = blockIdx.x / seq_len;
  int seq_id = blockIdx.x % seq_len;
  int head_id = threadIdx.y;
#pragma unroll
  for (int i = threadIdx.x; i < size_per_head; i += blockDim.x){
    int src_offset =
      ((head_id * batch_size + batch_id) * seq_len + seq_id) * size_per_head + i;
    int dst_offset = (blockIdx.x * head_num + head_id) * size_per_head + i;
    ((half2 *)dst)[dst_offset] = ((const half2 *)src)[src_offset];
  }
}

template <>
__global__ void transpose_rm_padding<float>(const float *src, float *dst, const int batch_size,
                                            const int seq_len, const int head_num,
                                            const int size_per_head, const int *batch_idx,
                                            const int *word_idx) {
  int offset = word_idx[blockIdx.x];
  int batch_id = offset / seq_len;  // batch_idx[blockIdx.x]
  int seq_id = offset % seq_len;    // word_idx[blockIdx.x]
  int head_id = threadIdx.y;
  int src_offset =
      ((head_id * batch_size + batch_id) * seq_len + seq_id) * size_per_head + threadIdx.x;
  int dst_offset = (blockIdx.x * head_num + head_id) * size_per_head + threadIdx.x;
  dst[dst_offset] = src[src_offset];
}

template <>
__global__ void transpose_rm_padding<__half>(const __half *src, __half *dst, const int batch_size,
                                             const int seq_len, const int head_num,
                                             const int size_per_head, const int *batch_idx,
                                             const int *word_idx) {
  int offset = word_idx[blockIdx.x];
  int batch_id = offset / seq_len;  // batch_idx[blockIdx.x]
  int seq_id = offset % seq_len;    // word_idx[blockIdx.x]
  int head_id = threadIdx.y;
  int src_offset =
      ((head_id * batch_size + batch_id) * seq_len + seq_id) * size_per_head + threadIdx.x;
  int dst_offset = (blockIdx.x * head_num + head_id) * size_per_head + threadIdx.x;
  ((half2 *)dst)[dst_offset] = ((const half2 *)src)[src_offset];
}
}  // namespace bytetransformer
