#include "common_defs.hlsl"

//#define INCLUDE_SPLITTER
//#define INCLUDE_TEST_PATTERNS
//#define INCLUDE_VISUALIZATIONS
//#define INCLUDE_ACES
//#define INCLUDE_HDR10
//#define INCLUDE_NAN_MITIGATION
//#define DEBUG_NAN
//#define UTIL_STRIP_NAN

#pragma warning ( disable : 3570 )
#pragma warning ( disable : 3571 )
#pragma warning ( disable : 4000 )

struct PS_INPUT
{
  float4 pos      : SV_POSITION;
  float4 color    : COLOR0;
  float2 coverage : COLOR1;
  float2 uv       : TEXCOORD0;
};

sampler   sampler0      : register (s0);
Texture2D texMainScene  : register (t0);
Texture2D texLastFrame0 : register (t1);

#define VISUALIZE_NONE           0
#define VISUALIZE_AVG_LUMA       1
#define VISUALIZE_LOCAL_LUMA     2
//#define VISUALIZE_HDR400_LUMA   4
//#define VISUALIZE_HDR500_LUMA   5
//#define VISUALIZE_HDR600_LUMA   6
//#define VISUALIZE_HDR1000_LUMA  7
//#define VISUALIZE_HDR1400_LUMA  8
#define VISUALIZE_EXPOSURE       3
#define VISUALIZE_HIGHLIGHTS     4
#define VISUALIZE_8BIT_QUANTIZE  5
#define VISUALIZE_10BIT_QUANTIZE 6
#define VISUALIZE_12BIT_QUANTIZE 7
#define VISUALIZE_16BIT_QUANTIZE 8
#define VISUALIZE_REC709_GAMUT   9
#define VISUALIZE_DCIP3_GAMUT    10
#define VISUALIZE_GRAYSCALE      11
#define VISUALIZE_MAX_LOCAL_CLIP 12
#define VISUALIZE_MAX_AVG_CLIP   13
#define VISUALIZE_MIN_AVG_CLIP   14


#define TONEMAP_NONE                  0
#define TONEMAP_ACES_FILMIC           1
#define TONEMAP_HDR10_to_scRGB        2
#define TONEMAP_HDR10_to_scRGB_FILMIC 3
#define TONEMAP_COPYRESOURCE          255
#define TONEMAP_REMOVE_INVALID_COLORS 256


#define sRGB_to_Linear           0
#define xRGB_to_Linear           1
#define sRGB_to_scRGB_as_DCIP3   2
#define sRGB_to_scRGB_as_Rec2020 3
#define sRGB_to_scRGB_as_XYZ     4

float4
SK_ProcessColor4 ( float4 color,
                      int func,
                      int strip_eotf = 1 )
{

  // This looks weird because power-law EOTF does not work as intended on negative colors, and
  //   we may very well have negative colors on WCG SDR input.
  //
  float4 out_color =
    float4 (
      (strip_eotf && func != sRGB_to_Linear) ?
                     sdrContentEOTF != -2.2f ? sign (color.rgb) * pow             (abs (color.rgb),
                     sdrContentEOTF)         :                    RemoveSRGBCurve (     color.rgb) :
                                                                                        color.rgb,
                                                                                        color.a
    );

  // Straight Pass-Through
  if (func <= xRGB_to_Linear)
    return out_color;

  return
    float4 (0.0f, 0.0f, 0.0f, 0.0f);
}


float4
FinalOutput (float4 vColor)
{
  // HDR10 -Output-, transform scRGB to HDR10
  if (visualFunc.y == 1)
  {
    vColor.rgb =
      clamp (LinearToPQ (REC709toREC2020 (vColor.rgb), 125.0f), 0.0, 1.0);

    vColor.rgb *=
      smoothstep ( 0.006978,
                   0.016667, vColor.rgb);

    vColor.a = 1.0;
  }

  return vColor;
}



float4
main (PS_INPUT input) : SV_TARGET
{
  switch (uiToneMapper)
  {
    case TONEMAP_COPYRESOURCE:
    {
      float4 ret =
        texMainScene.Sample ( sampler0,
                                input.uv );

      return ret;
    } break;

    case TONEMAP_REMOVE_INVALID_COLORS:
    {
      float4 color =
        texMainScene.Sample ( sampler0,
                                input.uv );

      return
        float4 ( (! IsNan (color.r)) * (! IsInf (color.r)) * color.r,
                 (! IsNan (color.g)) * (! IsInf (color.g)) * color.g,
                 (! IsNan (color.b)) * (! IsInf (color.b)) * color.b,
                 (! IsNan (color.a)) * (! IsInf (color.a)) * color.a );
    } break;
  }

  float4 hdr_color =
    texMainScene.Sample ( sampler0,
                            input.uv );

  float3 orig_color =
    abs (hdr_color.rgb);


  float3 hdr_rgb2 =
    hdr_color.rgb * 2.0f;

  float4 over_range =
    float4 (   hdr_color.rgb,      1.0f ) *
    float4 ( ( hdr_color.rgb > hdr_rgb2 ) +
             (           2.0 < hdr_rgb2 ), 1.0f );

  over_range.a =
    any (over_range.rgb);


  hdr_color.rgb = SK_ProcessColor4 ( hdr_color.rgba, xRGB_to_Linear, sdrContentEOTF != 1.0f ).rgb;


  // Clamp scRGB source image to Rec 709, unless using passthrough mode
  if (input.color.x != 1.0)
  {
    hdr_color.rgb =
      Clamp_scRGB (hdr_color.rgb);
  }



  if ( input.color.x < 0.0125f - FLT_EPSILON ||
       input.color.x > 0.0125f + FLT_EPSILON )
  {
    hdr_color.rgb = LinearToLogC (hdr_color.rgb);
    hdr_color.rgb = Contrast     (hdr_color.rgb,
            0.18f * (0.1f * input.color.x / 0.0125f) / 100.0f,
                     (sdrLuminance_NonStd / 0.0125f) / 100.0f);
    hdr_color.rgb = LogCToLinear (hdr_color.rgb);
  }

  hdr_color =
    SK_ProcessColor4 (hdr_color, uiToneMapper);

  if (input.color.y != 1.0f)
  {
    hdr_color.rgb =
      PositivePow ( hdr_color.rgb,
                  input.color.yyy );
  }

  if (pqBoostParams.x > 0.1f)
  {
    float
      pb_params [4] = {
        pqBoostParams.x,
        pqBoostParams.y,
        pqBoostParams.z,
        pqBoostParams.w
      };

    float3 new_color =
      PQToLinear (
        LinearToPQ ( hdr_color.rgb, pb_params [0]) *
                     pb_params [2], pb_params [1]
                 ) / pb_params [3];

      hdr_color.rgb = new_color;
  }


  if ( hdrSaturation >= 1.0f + FLT_EPSILON ||
       hdrSaturation <= 1.0f - FLT_EPSILON || uiToneMapper == TONEMAP_ACES_FILMIC )
  {
    float saturation =
      hdrSaturation + 0.05 * ( uiToneMapper == TONEMAP_ACES_FILMIC );

    hdr_color.rgb =
      Saturation ( hdr_color.rgb,
                   saturation );
  }

  hdr_color.a = 1;

  hdr_color.rgb *=
    input.color.xxx;

  if ( visualFunc.x >= VISUALIZE_REC709_GAMUT &&
       visualFunc.x <  VISUALIZE_GRAYSCALE )
  {

    if (hdrGamutExpansion > 0.0f)
    {
      hdr_color.rgb =
        expandGamut(hdr_color.rgb, hdrGamutExpansion);
    }

    // Copied from real output, does this change anything?
    {
      //hdr_color = float4 (Clamp_scRGB_StripNaN (hdr_color.rgb),saturate (hdr_color.a));

      // 0 => i.e. true black seems to get mapped outside of Rec.709 / P3
      //hdr_color.rgb *=
      //  ( (orig_color.r > FP16_MIN) +
      //    (orig_color.g > FP16_MIN) +
      //    (orig_color.b > FP16_MIN) > 0.0f );

      if (visualFunc.y == 1)
      {
        hdr_color.rgb = REC709toREC2020(hdr_color.rgb);
      }
      //hdr_color.rgb = clamp (LinearToPQ (REC709toREC2020 (hdr_color.rgb), 125.0f), 0.0, 1.0);
      //hdr_color.rgb *= smoothstep (0.006978, 0.016667, hdr_color.rgb);
    }

    int cs = visualFunc.x - VISUALIZE_REC709_GAMUT;

    float3 r = float3(_ColorSpaces[cs].xr, _ColorSpaces[cs].yr, 0);
    float3 g = float3(_ColorSpaces[cs].xg, _ColorSpaces[cs].yg, 0);
    float3 b = float3(_ColorSpaces[cs].xb, _ColorSpaces[cs].yb, 0);


    float3 vColor_xyY;
    if (false)
    //if (visualFunc.y == 1)
    {
      vColor_xyY = SK_Color_xyY_from_RGB(_ColorSpaces[2], hdr_color.rgb);
      vColor_xyY.z = 0;
    }
    else
    {
      float3 vColor_XYZ = sRGBtoXYZ(hdr_color.rgb);
      vColor_xyY = float3(vColor_XYZ.x / (vColor_XYZ.x + vColor_XYZ.y + vColor_XYZ.z), vColor_XYZ.y / (vColor_XYZ.x + vColor_XYZ.y + vColor_XYZ.z), 0);
    }


    float3 vTriangle[] = {r, g, b};
    //float3 vTriangle[] = {float3(1,0,0), float3(0,1,0), float3(0,0,0)};

    float3 output_color;
    {
      bool bContained = SK_Triangle_ContainsPoint(vColor_xyY, vTriangle);
      if (bContained) // && vColor_xyY.x != vColor_xyY.y)
      {
        // grey = no overshoot
        output_color = (hdrLuminance_MaxAvg / 320.0) * Luminance(hdr_color.rgb);
      }
      else
      {
        // colored = overshoot
        float3 fDistField =
          float3(
            distance(r, vColor_xyY),
            distance(g, vColor_xyY),
            distance(b, vColor_xyY)
          );

        fDistField.x = IsNan(fDistField.x) ? 0 : fDistField.x;
        fDistField.y = IsNan(fDistField.y) ? 0 : fDistField.y;
        fDistField.z = IsNan(fDistField.z) ? 0 : fDistField.z;
        output_color = fDistField;

        output_color = (hdrLuminance_MaxAvg / 320.0) * Luminance(hdr_color.rgb);
        output_color.r = 1;
      }
    }

    return FinalOutput(float4 (output_color, 1.0f));
  }


  float4 color_out;

  // Extra clipping and gamut expansion logic for regular display output
  if (hdrGamutExpansion > 0.0f)
  {
    color_out.rgb =
      expandGamut (hdr_color.rgb, hdrGamutExpansion);
  }


  color_out =
    float4 (
      Clamp_scRGB_StripNaN (color_out.rgb),
                  saturate (hdr_color.a)
           );


  color_out.rgb *=
    ( (orig_color.r > FP16_MIN) +
      (orig_color.g > FP16_MIN) +
      (orig_color.b > FP16_MIN) > 0.0f );

  return
    FinalOutput (color_out);
}
