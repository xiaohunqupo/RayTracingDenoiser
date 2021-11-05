/*
Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "NRD.hlsli"
#include "STL.hlsli"
#include "RELAX_Diffuse_Prepass.resources.hlsli"

NRD_DECLARE_CONSTANTS

#include "NRD_Common.hlsli"
NRD_DECLARE_SAMPLERS
#include "RELAX_Common.hlsli"

NRD_DECLARE_INPUT_TEXTURES
NRD_DECLARE_OUTPUT_TEXTURES

#define POISSON_SAMPLE_NUM                      8
#define POISSON_SAMPLES                         g_Poisson8

#define THREAD_GROUP_SIZE 8

float GetNormHitDist(float hitDist, float viewZ, float4 hitDistParams = float4(3.0, 0.1, 10.0, -25.0), float linearRoughness = 1.0)
{
    float f = _REBLUR_GetHitDistanceNormalization(viewZ, hitDistParams, gMeterToUnitsMultiplier, linearRoughness);
    return saturate(hitDist / f);
}

float GetBlurRadius(float radius, float hitDist, float viewZ, float nonLinearAccumSpeed, float boost, float error, float radiusBias, float radiusScale)
{
    // Modify by hit distance
    float hitDistFactor = hitDist / (hitDist + viewZ);
    float s = hitDistFactor;

    // A non zero addition is needed to avoid under-blurring:
    float addon = 9.0;
    addon = min(addon, radius * 0.333);
    addon *= hitDistFactor;

    // Final blur radius
    float r = s * radius + addon;
    r = r * (radiusScale + radiusBias) + radiusBias;
    return r;
}

float2x3 GetKernelBasis(float3 X, float3 N, float worldRadius, float roughness = 1.0, float anisoFade = 1.0)
{
    float3x3 basis = STL::Geometry::GetBasis(N);
    float3 T = basis[0];
    float3 B = basis[1];

    float3 V = -normalize(X);
    float4 D = STL::ImportanceSampling::GetSpecularDominantDirection(N, V, roughness, RELAX_SPEC_DOMINANT_DIRECTION);
    float NoD = abs(dot(N, D.xyz));

    if (NoD < 0.999 && roughness < RELAX_SPEC_BASIS_ROUGHNESS_THRESHOLD)
    {
        float3 R = reflect(-D.xyz, N);
        T = normalize(cross(N, R));
        B = cross(R, T);

#if( RELAX_USE_ANISOTROPIC_KERNEL == 1 )
        float NoV = abs(dot(N, V));
        float acos01sq = saturate(1.0 - NoV); // see AcosApprox()

        float skewFactor = lerp(1.0, roughness, D.w);
        skewFactor = lerp(1.0, skewFactor, STL::Math::Sqrt01(acos01sq));

        T *= lerp(skewFactor, 1.0, anisoFade);
#endif
    }

    T *= worldRadius;
    B *= worldRadius;

    return float2x3(T, B);
}

float2 GetHitDistanceWeightParams(float normHitDist, float nonLinearAccumSpeed, float roughness = 1.0)
{
    float threshold = exp2(-17.0 * roughness * roughness); // TODO: not in line with other weights
    float scale = lerp(threshold, 1.0, nonLinearAccumSpeed);

    float a = rcp(normHitDist * scale * 0.99 + 0.01);
    float b = normHitDist * a;

    return float2(a, -b);
}

float GetNormalWeightParams(float nonLinearAccumSpeed, float edge, float error, float roughness = 1.0, float strictness = 1.0)
{
    float angle = STL::ImportanceSampling::GetSpecularLobeHalfAngle(roughness);

    // TODO: 0.15 can be different for blur passes
    // TODO: curvature is needed to estimate initial scale
    float s = lerp(0.04, 0.15, error);
    s *= strictness;

    s = lerp(s, 1.0, edge);
    s = lerp(s, 1.0, nonLinearAccumSpeed);
    angle *= s;

    angle += STL::Math::DegToRad(0.625);

    return rcp(angle);
}

int2 DiffCheckerboard(int2 pos)
{
    int2 result = pos;
    if (gDiffCheckerboard != 2)
    {
        result.x >>= 1;
    }
    return result;
}

float3 getCurrentWorldPos(int2 pixelPos, float depth)
{
    float2 clipSpaceXY = ((float2)pixelPos + float2(0.5, 0.5)) * gInvRectSize * 2.0 - 1.0;
    return depth * (gFrustumForward.xyz + gFrustumRight.xyz * clipSpaceXY.x - gFrustumUp.xyz * clipSpaceXY.y);
}

float3 getCurrentWorldPos(float2 uv, float depth)
{
    float2 clipSpaceXY = uv * 2.0 - 1.0;
    return depth * (gFrustumForward.xyz + gFrustumRight.xyz * clipSpaceXY.x - gFrustumUp.xyz * clipSpaceXY.y);
}

float GetGaussianWeight(float r)
{
    // radius is normalized to 1
    return exp(-0.66 * r * r);
}

float GetNormalWeight(float params0, float3 n0, float3 n)
{
    float cosa = saturate(dot(n0, n));
    float angle = STL::Math::AcosApprox(cosa);

    return _ComputeWeight(float2(params0, -0.001), angle);
}

#define GetHitDistanceWeight(p, value) _ComputeWeight(p, value)

float2 GetRoughnessWeightParams(float roughness0)
{
    float a = rcp(roughness0 * 0.05 * 0.99 + 0.01);
    float b = roughness0 * a;

    return float2(a, -b);
}

float GetRoughnessWeight(float2 params0, float roughness)
{
    return STL::Math::SmoothStep01(1.0 - abs(roughness * params0.x + params0.y));
}

[numthreads(THREAD_GROUP_SIZE, THREAD_GROUP_SIZE, 1)]
NRD_EXPORT void NRD_CS_MAIN(int2 ipos : SV_DispatchThreadID, uint3 groupThreadId : SV_GroupThreadID, uint3 groupId : SV_GroupID)
{
    // Calculating checkerboard fields
    bool diffHasData = true;
    uint checkerboard = STL::Sequence::CheckerBoard(ipos, gFrameIndex);

    if (gDiffCheckerboard != 2)
    {
        diffHasData = checkerboard == gDiffCheckerboard;
    }

    // Reading center GBuffer data
    float centerViewZ = gViewZ[ipos + gRectOrigin];
    float3 centerNormal = NRD_FrontEnd_UnpackNormalAndRoughness(gNormalRoughness[ipos + gRectOrigin]).rgb;

    // Outputting ViewZ and scaled ViewZ
    gOutViewZ[ipos] = centerViewZ;
    gOutScaledViewZ[ipos] = min(centerViewZ * NRD_FP16_VIEWZ_SCALE, NRD_FP16_MAX);

    // Early out if linearZ is beyond denoising range
    [branch]
    if (centerViewZ > gDenoisingRange)
    {
        return;
    }

    float3 centerWorldPos = getCurrentWorldPos(ipos, centerViewZ);
    float4 rotator = GetBlurKernelRotation(NRD_FRAME, ipos, gRotator, gFrameIndex);

    // Checkerboard resolve weights
    float2 checkerboardResolveWeights = 1.0;
    if (gDiffCheckerboard != 2)
    {
        float viewZ0 = gViewZ[ipos + int2(-1, 0) + gRectOrigin];
        float viewZ1 = gViewZ[ipos + int2(1, 0) + gRectOrigin];

        checkerboardResolveWeights = GetBilateralWeight(float2(viewZ0, viewZ1), centerViewZ);
        checkerboardResolveWeights *= STL::Math::PositiveRcp(checkerboardResolveWeights.x + checkerboardResolveWeights.y);
    }

    // Reading diffuse & resolving diffuse checkerboard
    float4 diffuseIllumination = gDiffuseIllumination[DiffCheckerboard(ipos + gRectOrigin)];

    if (!diffHasData)
    {
        float4 d0 = gDiffuseIllumination[DiffCheckerboard(ipos + int2(-1, 0) + gRectOrigin)];
        float4 d1 = gDiffuseIllumination[DiffCheckerboard(ipos + int2(1, 0) + gRectOrigin)];
        diffuseIllumination *= saturate(1.0 - checkerboardResolveWeights.x - checkerboardResolveWeights.y);
        diffuseIllumination += d0 * checkerboardResolveWeights.x + d1 * checkerboardResolveWeights.y;
    }

    // Pre-blur for diffuse
    if (gDiffuseBlurRadius > 0)
    {
        // Diffuse blur radius
        float hitDist = GetNormHitDist(diffuseIllumination.w, centerViewZ);
        float blurRadius = GetBlurRadius(gDiffuseBlurRadius, diffuseIllumination.w, centerViewZ, 1.0 / 9.0, 1.0, 1.0, 0, 1.0);

        float worldBlurRadius = PixelRadiusToWorld(gUnproject, gIsOrtho, blurRadius, centerViewZ);

        float2x3 TvBv = GetKernelBasis(centerWorldPos, centerNormal, worldBlurRadius);
        float normalWeightParams = GetNormalWeightParams(1.0 / 9.0, 0.0, 1.0, 1.0, 1.0);
        float2 hitDistanceWeightParams = GetHitDistanceWeightParams(diffuseIllumination.w, 1.0 / 9.0);
        float weightSum = 1.0;

        // Spatial blur
        [unroll]
        for (uint i = 0; i < POISSON_SAMPLE_NUM; i++)
        {
            float3 offset = POISSON_SAMPLES[i];

            // Sample coordinates
            float2 uv = GetKernelSampleCoordinates(gWorldToClip, offset, centerWorldPos, TvBv[0], TvBv[1], rotator);

            // Handle half res input in the checkerboard mode
            float2 checkerboardUv = uv;
            if (gDiffCheckerboard != 2)
            {
                checkerboardUv = ApplyCheckerboard(uv, gDiffCheckerboard, i, gResolution, gInvRectSize, gFrameIndex);
            }

            // Fetch data
            float2 uvScaled = uv * gResolutionScale;
            float3 sampleNormal = NRD_FrontEnd_UnpackNormalAndRoughness(gNormalRoughness.SampleLevel(gNearestMirror, uvScaled + gRectOffset, 0)).rgb;

            float2 checkerboardUvScaled = checkerboardUv * gResolutionScale + gRectOffset;
            float4 sampleDiffuseIllumination = gDiffuseIllumination.SampleLevel(gNearestMirror, checkerboardUvScaled, 0);
            float sampleViewZ = abs(gViewZ.SampleLevel(gNearestMirror, uvScaled + gRectOffset, 0));

            float3 sampleWorldPos = getCurrentWorldPos(uv, sampleViewZ);

            // Sample weight
            float sampleWeight = IsInScreen(uv);
            sampleWeight *= GetGaussianWeight(offset.z);

            float sampleNormalizedHitDist = GetNormHitDist(sampleDiffuseIllumination.w, sampleViewZ);

            float minHitDistanceWeight = 0.2;
            float hitDistanceWeight = GetHitDistanceWeight(hitDistanceWeightParams, sampleNormalizedHitDist);

            sampleWeight *= exp_approx(-GetGeometryWeight(centerWorldPos, centerNormal, centerViewZ, sampleWorldPos, 0.001));
            sampleWeight *= GetNormalWeight(normalWeightParams, centerNormal, sampleNormal);
            sampleWeight *= lerp(minHitDistanceWeight, 1.0, hitDistanceWeight);

            diffuseIllumination += sampleDiffuseIllumination * sampleWeight;
            weightSum += sampleWeight;
        }
        diffuseIllumination /= weightSum;
    }
    gOutDiffuseIllumination[ipos] = diffuseIllumination;
}
