/*
Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "RELAX_Config.hlsli"

#define NRD_DECLARE_INPUT_TEXTURES \
    NRD_INPUT_TEXTURE( Texture2D<float4>, gDiffuseIlluminationAndVariance, t, 0 ) \
    NRD_INPUT_TEXTURE( Texture2D<float>, gHistoryLength, t, 1 ) \
    NRD_INPUT_TEXTURE( Texture2D<float4>, gNormalRoughness, t, 2 ) \
    NRD_INPUT_TEXTURE(Texture2D<float>, gViewZFP16, t, 3)

#define NRD_DECLARE_OUTPUT_TEXTURES \
    NRD_OUTPUT_TEXTURE( RWTexture2D<float4>, gOutDiffuseIlluminationAndVariance, u, 0 )

#define NRD_DECLARE_CONSTANTS \
    NRD_CONSTANTS_START \
        NRD_CONSTANT( float4, gFrustumRight ) \
        NRD_CONSTANT( float4, gFrustumUp ) \
        NRD_CONSTANT( float4, gFrustumForward ) \
        NRD_CONSTANT( int2, gResolution ) \
        NRD_CONSTANT( float2, gInvRectSize ) \
        NRD_CONSTANT( float, gDiffusePhiLuminance ) \
        NRD_CONSTANT( float, gMaxLuminanceRelativeDifference ) \
        NRD_CONSTANT( float, gPhiDepth ) \
        NRD_CONSTANT( float, gPhiNormal ) \
        NRD_CONSTANT( uint, gStepSize ) \
        NRD_CONSTANT( float, gDenoisingRange ) \
        NRD_CONSTANT( uint, gFrameIndex ) \
    NRD_CONSTANTS_END

#define NRD_DECLARE_SAMPLERS \
    NRD_COMMON_SAMPLERS
