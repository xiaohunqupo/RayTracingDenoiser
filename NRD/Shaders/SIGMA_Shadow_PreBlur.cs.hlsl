/*
Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "BindingBridge.hlsl"

NRI_RESOURCE( cbuffer, globalConstants, b, 0, 0 )
{
    float4x4 gViewToClip;
    float4 gFrustum;
    float2 gInvScreenSize;
    float2 gScreenSize;
    uint gBools;
    float gIsOrtho;
    float gUnproject;
    float gDebug;
    float gInf;
    float gPlaneDistSensitivity;
    uint gFrameIndex;
    float gFramerateScale;

    float4x4 gWorldToView;
    float4 gRotator;
    float gBlurRadius;
};

#include "REBLUR_Common.hlsl"

// Inputs
NRI_RESOURCE( Texture2D<float4>, gIn_Normal_Roughness, t, 0, 0 );
NRI_RESOURCE( Texture2D<float2>, gIn_Hit_ViewZ, t, 1, 0 );
NRI_RESOURCE( Texture2D<SHADOW_TYPE>, gIn_History, t, 2, 0 );

#ifdef TRANSLUCENT_SHADOW
    NRI_RESOURCE( Texture2D<float3>, gIn_Translucency, t, 3, 0 );
#endif

// Outputs
NRI_RESOURCE( RWTexture2D<float2>, gOut_Hit_ViewZ, u, 0, 0 );
NRI_RESOURCE( RWTexture2D<SHADOW_TYPE>, gOut_Shadow_Translucency, u, 1, 0 );
NRI_RESOURCE( RWTexture2D<SHADOW_TYPE>, gOut_History, u, 2, 0 );

groupshared float2 s_Data[ BUFFER_Y ][ BUFFER_X ];

#ifdef TRANSLUCENT_SHADOW
    groupshared float4 s_Translucency[ BUFFER_Y ][ BUFFER_X ];
#endif

void Preload( int2 sharedId, int2 globalId )
{
    float2 data = gIn_Hit_ViewZ[ globalId ];
    data.x = ( data.x == NRD_FP16_MAX ) ? NRD_FP16_MAX : ( data.x / NRD_FP16_VIEWZ_SCALE );
    data.y = data.y / NRD_FP16_VIEWZ_SCALE;

    s_Data[ sharedId.y ][ sharedId.x ] = data;

    #ifdef TRANSLUCENT_SHADOW
        s_Translucency[ sharedId.y ][ sharedId.x ] = gIn_Translucency[ globalId ].xyzz;
    #endif
}

[numthreads( GROUP_X, GROUP_Y, 1 )]
void main( int2 threadId : SV_GroupThreadId, int2 pixelPos : SV_DispatchThreadId, uint threadIndex : SV_GroupIndex )
{
    float2 pixelUv = float2( pixelPos + 0.5 ) * gInvScreenSize;

    PRELOAD_INTO_SMEM;

    // Copy history
    gOut_History[ pixelPos ] = gIn_History[ pixelPos ];

    // Center data
    int2 smemPos = threadId + BORDER;
    float2 centerData = s_Data[ smemPos.y ][ smemPos.x ];
    float centerHitDist = centerData.x;
    float centerSignNoL = float( centerData.x != 0.0 );
    float centerZ = centerData.y;

    // Early out
    [branch]
    if( abs( centerZ ) > abs( gInf ) || centerHitDist == 0.0 )
    {
        gOut_Hit_ViewZ[ pixelPos ] = float2( 0.0, centerZ * NRD_FP16_VIEWZ_SCALE );

        SHADOW_TYPE s;
        s.x = float( centerData.x == NRD_FP16_MAX );
        #ifdef TRANSLUCENT_SHADOW
            s.yzw = s_Translucency[ smemPos.y ][ smemPos.x ].xyz;
        #endif
        gOut_Shadow_Translucency[ pixelPos ] = s;

        return;
    }

    // Position
    float3 Xv = STL::Geometry::ReconstructViewPosition( pixelUv, gFrustum, centerZ, gIsOrtho );

    // Normal
    float4 normalAndRoughness = _NRD_FrontEnd_UnpackNormalAndRoughness( gIn_Normal_Roughness[ pixelPos ] );
    float3 N = normalAndRoughness.xyz;
    float3 Nv = STL::Geometry::RotateVector( gWorldToView, N );

    // Estimate average distance to occluder
    float sum = 0;
    float hitDist = 0;
    SHADOW_TYPE result = 0;

    [unroll]
    for( int dy = 0; dy <= BORDER * 2; dy++ )
    {
        [unroll]
        for( int dx = 0; dx <= BORDER * 2; dx++ )
        {
            int2 pos = threadId + int2( dx, dy );
            float2 data = s_Data[ pos.y ][ pos.x ];
            float h = data.x;
            float signNoL = float( data.x != 0.0 );
            float z = data.y;

            SHADOW_TYPE s;
            s.x = float( data.x == NRD_FP16_MAX );
            #ifdef TRANSLUCENT_SHADOW
                s.yzw = s_Translucency[ pos.y ][ pos.x ].xyz;
            #endif

            float w = 1.0;
            if( !(dx == BORDER && dy == BORDER) )
            {
                w = GetBilateralWeight( z, centerZ );
                w *= saturate( 1.0 - abs( centerSignNoL - signNoL ) );
            }

            result += s * w;
            hitDist += ( h * float( s.x != 1.0 ) + SHADOW_PENUMBRA_FIX_HIT_DIST_ADDON ) * w;
            sum += w;
        }
    }

    float invSum = STL::Math::PositiveRcp( sum );
    result *= invSum;
    hitDist *= invSum;

    // Blur radius
    float innerShadowFix = lerp( 0.5, 1.0, result.x );
    float worldRadius = hitDist * gBlurRadius * innerShadowFix;

    float unprojectZ = PixelRadiusToWorld( 1.0, centerZ );
    float pixelRadius = worldRadius * STL::Math::PositiveRcp( unprojectZ );
    pixelRadius = min( pixelRadius, SHADOW_MAX_PIXEL_RADIUS );
    worldRadius = pixelRadius * unprojectZ;

    float centerWeight = STL::Math::LinearStep( 0.9, 1.0, result.x );
    worldRadius += SHADOW_PENUMBRA_FIX_BLUR_RADIUS_ADDON * lerp( saturate( pixelRadius / 1.5 ), 1.0, centerWeight ) * unprojectZ * result.x;

    // Tangent basis
    float3x3 mWorldToLocal = STL::Geometry::GetBasis( Nv );
    float3 Tv = mWorldToLocal[ 0 ] * worldRadius;
    float3 Bv = mWorldToLocal[ 1 ] * worldRadius;

    // Random rotation
    float4 rotator = GetBlurKernelRotation( SHADOW_PRE_BLUR_ROTATOR_MODE, pixelPos, gRotator );

    // Denoising
    sum = 1.0;

    float2 geometryWeightParams = GetGeometryWeightParams( Xv, Nv, centerZ, SHADOW_PLANE_DISTANCE_SCALE );

    SHADOW_UNROLL
    for( uint i = 0; i < SHADOW_POISSON_SAMPLE_NUM; i++ )
    {
        // Sample coordinates
        float3 offset = SHADOW_POISSON_SAMPLES[ i ];
        float2 uv = GetKernelSampleCoordinates( offset, Xv, Tv, Bv, rotator );

        // Fetch data
        float2 data = gIn_Hit_ViewZ.SampleLevel( gNearestMirror, uv, 0 );
        float h = data.x / NRD_FP16_VIEWZ_SCALE;
        float signNoL = float( data.x != 0.0 );
        float z = data.y / NRD_FP16_VIEWZ_SCALE;

        SHADOW_TYPE s;
        s.x = float( data.x == NRD_FP16_MAX );
        #ifdef TRANSLUCENT_SHADOW
            s.yzw = gIn_Translucency.SampleLevel( gNearestMirror, uv, 0.0 ).xyz;
        #endif

        // Sample weight
        float3 samplePos = STL::Geometry::ReconstructViewPosition( uv, gFrustum, z, gIsOrtho );
        float w = GetGeometryWeight( geometryWeightParams, Nv, samplePos );
        w *= saturate( 1.0 - abs( centerSignNoL - signNoL ) );

        // Weight for outer shadow (to avoid blurring of ~umbra)
        w *= lerp( 1.0, s.x, centerWeight );

        result += s * w;
        hitDist += ( h * float( s.x != 1.0 ) + SHADOW_PENUMBRA_FIX_HIT_DIST_ADDON ) * w;
        sum += w;
    }

    invSum = STL::Math::PositiveRcp( sum );
    result *= invSum;
    hitDist *= invSum;

    // Output
    gOut_Hit_ViewZ[ pixelPos ] = float2( hitDist * centerSignNoL, centerZ ) * NRD_FP16_VIEWZ_SCALE;
    gOut_Shadow_Translucency[ pixelPos ] = PackShadow( result );
}