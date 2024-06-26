/*
Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

void nrd::InstanceImpl::Add_SigmaShadow(DenoiserData& denoiserData)
{
    #define DENOISER_NAME SIGMA_Shadow

    denoiserData.settings.sigma = SigmaSettings();
    denoiserData.settingsSize = sizeof(denoiserData.settings.sigma);

    enum class Transient
    {
        DATA_1 = TRANSIENT_POOL_START,
        DATA_2,
        TEMP_1,
        TEMP_2,
        HISTORY,
        TILES,
        SMOOTHED_TILES,
    };

    AddTextureToTransientPool( {Format::R16_SFLOAT, 1} );
    AddTextureToTransientPool( {Format::R16_SFLOAT, 1} );
    AddTextureToTransientPool( {Format::R8_UNORM, 1} );
    AddTextureToTransientPool( {Format::R8_UNORM, 1} );
    AddTextureToTransientPool( {Format::R8_UNORM, 1} );
    AddTextureToTransientPool( {Format::RGBA8_UNORM, 16} );
    AddTextureToTransientPool( {Format::RG8_UNORM, 16} );

    PushPass("Classify tiles");
    {
        PushInput( AsUint(ResourceType::IN_VIEWZ) );
        PushInput( AsUint(ResourceType::IN_PENUMBRA) );

        PushOutput( AsUint(Transient::TILES) );

        AddDispatch( SIGMA_Shadow_ClassifyTiles, SIGMA_ClassifyTiles, 1 );
    }

    PushPass("Smooth tiles");
    {
        PushInput( AsUint(Transient::TILES) );

        PushOutput( AsUint(Transient::SMOOTHED_TILES) );

        AddDispatch( SIGMA_Shadow_SmoothTiles, SIGMA_SmoothTiles, 16 );
    }

    PushPass("Blur");
    {
        PushInput( AsUint(ResourceType::IN_VIEWZ) );
        PushInput( AsUint(ResourceType::IN_NORMAL_ROUGHNESS) );
        PushInput( AsUint(ResourceType::IN_PENUMBRA) );
        PushInput( AsUint(Transient::SMOOTHED_TILES) );
        PushInput( AsUint(ResourceType::OUT_SHADOW_TRANSLUCENCY) );

        PushOutput( AsUint(Transient::DATA_1) );
        PushOutput( AsUint(Transient::TEMP_1) );
        PushOutput( AsUint(Transient::HISTORY) );

        AddDispatch( SIGMA_Shadow_Blur, SIGMA_Blur, USE_MAX_DIMS );
    }

    for (int i = 0; i < SIGMA_POST_BLUR_PERMUTATION_NUM; i++)
    {
        bool isStabilizationEnabled = ( ( ( i >> 0 ) & 0x1 ) != 0 );

        PushPass("Post-blur");
        {
            PushInput( AsUint(ResourceType::IN_VIEWZ) );
            PushInput( AsUint(ResourceType::IN_NORMAL_ROUGHNESS) );
            PushInput( AsUint(Transient::DATA_1) );
            PushInput( AsUint(Transient::SMOOTHED_TILES) );
            PushInput( AsUint(Transient::TEMP_1) );

            PushOutput( AsUint(Transient::DATA_2) );
            PushOutput( isStabilizationEnabled ? AsUint(Transient::TEMP_2) : AsUint(ResourceType::OUT_SHADOW_TRANSLUCENCY) );

            AddDispatch( SIGMA_Shadow_PostBlur, SIGMA_Blur, 1 );
        }
    }

    PushPass("Temporal stabilization");
    {
        PushInput( AsUint(ResourceType::IN_VIEWZ) );
        PushInput( AsUint(ResourceType::IN_MV) );
        PushInput( AsUint(Transient::DATA_2) );
        PushInput( AsUint(Transient::TEMP_2) );
        PushInput( AsUint(Transient::HISTORY) );
        PushInput( AsUint(Transient::SMOOTHED_TILES) );

        PushOutput( AsUint(ResourceType::OUT_SHADOW_TRANSLUCENCY) );

        AddDispatch( SIGMA_Shadow_TemporalStabilization, SIGMA_TemporalStabilization, 1 );
    }

    PushPass("Split screen");
    {
        PushInput( AsUint(ResourceType::IN_VIEWZ) );
        PushInput( AsUint(ResourceType::IN_PENUMBRA) );

        PushOutput( AsUint(ResourceType::OUT_SHADOW_TRANSLUCENCY) );

        AddDispatch( SIGMA_Shadow_SplitScreen, SIGMA_SplitScreen, 1 );
    }

    #undef DENOISER_NAME
}
