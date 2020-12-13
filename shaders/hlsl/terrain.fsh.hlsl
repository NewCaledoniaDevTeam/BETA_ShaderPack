#include "ShaderConstants.fxh"
#include "util.fxh"
#include "snoise.fxh"

struct PS_Input
{
	float4 position : SV_Position;
	float3 cPos : chunkedPos;
	float3 wPos : worldPos;
	float wf : WaterFlag;

#ifndef BYPASS_PIXEL_SHADER
	lpfloat4 color : COLOR;
	snorm float2 uv0 : TEXCOORD_0_FB_MSAA;
	snorm float2 uv1 : TEXCOORD_1_FB_MSAA;
#endif

#ifdef FOG
	float fog : fog_a;
#endif
};

struct PS_Output
{
	float4 color : SV_Target;
};

float3 curve(float3 x){
	static const float A = 0.50;
	static const float B = 0.10;
	static const float C = 0.40;
	static const float D = 0.65;
	static const float E = 0.05;
	static const float F = 0.20;
	return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F))-E/F;
}

float3 tonemap(float3 col, float3 gamma){
	static const float saturation = 1.2;
	//static const float exposure = 1.0;
	col = pow(col,1./gamma);
	float luma = dot(col, float3(0.298912, 0.586611, 0.114478));
	col = curve((col-luma)*saturation+luma);
	return col/curve(float3(1./*1./exposure*/,0.,0.)).r;
}
float4 water(float4 col,float3 p,float3 wPos,float weather,float uw,float sun,float3 tex1){
	sun = smoothstep(.5,.9,sun);
	float3 T = normalize(abs(wPos)); float cosT = length(T.xz);
	p.xz = p.xz*float2(1.0,0.4)+smoothstep(0.,8.,abs(p.y-8.))*.5;
	float n = (snoise(p.xz-TOTAL_REAL_WORLD_TIME*.5)+snoise(float2(p.x-TOTAL_REAL_WORLD_TIME,(p.z+TOTAL_REAL_WORLD_TIME)*.5)))+2.;//[0.~4.]

	float4 diffuse = lerp(col,col*lerp(1.5,1.3,T.y*uw),pow(1.-abs(n-2.)*.5,bool(uw)?1.5:2.5));
	if(bool(uw)){//new C_REF
		float2 skp = (wPos.xz+n*4.*wPos.xz/max(length(wPos.xz),.5))*cosT*.1;
		skp.x -= TOTAL_REAL_WORLD_TIME*.05;
		float2 ssreff = lerp(float2(.7,.7),float2(.8,.6),clamp(FOG_COLOR.r-FOG_COLOR.g,0.,.4)*2.5);
		float4 skc = lerp(lerp(col,FOG_COLOR,cosT*ssreff.x),float4(lerp(tex1,FOG_COLOR.rgb,cosT*ssreff.y),1),smoothstep(0.,1.,snoise(skp)));
		float s_ref = sun*weather*smoothstep(.7,0.,T.y)*lerp(.3,1.,smoothstep(1.5,4.,n))*.9;
		skc = lerp(skc,1,smoothstep(3.+abs(wPos.y)*.3,0.,abs(wPos.z))*s_ref);
		diffuse = lerp(diffuse,skc,cosT*sun);
	}
	return lerp(diffuse,col,min(.7,T.y));
}


ROOT_SIGNATURE
void main(in PS_Input PSInput, out PS_Output PSOutput)
{
#ifdef BYPASS_PIXEL_SHADER
		PSOutput.color = float4(0.0f, 0.0f, 0.0f, 0.0f);
		return;
#else

#if USE_TEXEL_AA
	float4 diffuse = texture2D_AA(TEXTURE_0, TextureSampler0, PSInput.uv0 );
#else
	float4 diffuse = TEXTURE_0.Sample(TextureSampler0, PSInput.uv0);
#endif

#ifdef SEASONS_FAR
	diffuse.a = 1.0f;
#endif

#if USE_ALPHA_TEST
	#ifdef ALPHA_TO_COVERAGE
		#define ALPHA_THRESHOLD 0.05
	#else
		#define ALPHA_THRESHOLD 0.52
	#endif
	if(diffuse.a < ALPHA_THRESHOLD)discard;
#endif

#ifdef BLEND
	diffuse.a *= PSInput.color.a;
#endif

float4 tex1 = TEXTURE_1.Sample(TextureSampler1, PSInput.uv1);
#ifndef ALWAYS_LIT
	diffuse *= tex1;
#endif

#ifndef SEASONS
	#if !USE_ALPHA_TEST && !defined(BLEND)
		diffuse.a = PSInput.color.a;
	#endif

	diffuse.rgb *= PSInput.color.rgb;
#else
	float2 uv = PSInput.color.xy;
	diffuse.rgb *= lerp(1.0f, TEXTURE_2.Sample(TextureSampler2, uv).rgb*2.0f, PSInput.color.b);
	diffuse.rgb *= PSInput.color.aaa;
	diffuse.a = 1.0f;
#endif

//datas
float time = TOTAL_REAL_WORLD_TIME;
float nv = step(TEXTURE_1.Sample(TextureSampler1,float2(0,0)).r,.5);
float dusk = min(smoothstep(.1,.4,daylight.y),smoothstep(1.,.8,daylight.y));
float uw = step(FOG_CONTROL.x,0.);
float nether = FOG_CONTROL.x/FOG_CONTROL.y;nether=step(.1,nether)-step(.12,nether);
float sat = satur(diffuse.rgb);
float4 ambient = lerp(//float4(gamma.rgb,saturation)
		float4(1.,.97,.9,1.15),//indoor
	lerp(
		float4(.54,.72,.9,.9),//rain
	lerp(lerp(
		float4(.45,.59,.9,1.),//night
		float4(1.15,1.17,1.1,1.2),//day
	daylight.y),
		float4(1.4,.9,.5,.8),//dusk
	dusk),weather),sun.y*nv);
	if(uw+nether>.5)ambient = float4(FOG_COLOR.rgb*.6+.4,.8);
#ifdef USE_NORMAL
	float3 N = normalize(cross(ddx(-PSInput.cPos),ddy(PSInput.cPos)));
	float dotN = dot(normalize(-PSInput.wPos),N);
#endif

//tonemap
diffuse.rgb = tone(diffuse.rgb,ambient);

//light_sorce
float lum = dot(diffuse.rgb,float3(.299,.587,.114));
diffuse.rgb += max(fuv1.x-.5,0.)*(1.-lum*lum)*lerp(1.,.3,daylight.x*sun.y)*float3(1.0,0.65,0.3);

//shadow
float ao = 1.;
if(PSInput.color.r==PSInput.color.g && PSInput.color.g==PSInput.color.b)ao = smoothstep(.48*daylight.y,.52*daylight.y,PSInput.color.g);
float Nl =
	#ifdef USE_NORMAL
		lerp(1.,smoothstep(-.7+dusk,1.,dot(normalize(float3(dusk*6.,4,3)),float3(abs(N.x),N.yz))),sun.y);
	#else
		1.;
	#endif
diffuse.rgb *= 1.-lerp(.5,0.,min(min(sun.x,ao),Nl))*(1.-max(0.,fuv1.x-sun.y*.7))*daylight.x;

//water
#ifdef FANCY
	float3 n = normalize(cross(ddx(-PSInput.cPos),ddy(PSInput.cPos)));
	if(PSInput.wf+uw>.5){
		diffuse = water(diffuse,PSInput.cPos,PSInput.wPos,weather,1.-uw,PSInput.uv1.y,tex1.rgb);
		float w_r = 1.-dot(normalize(-PSInput.wPos),n);
		diffuse.a = lerp(diffuse.a,1.,.02+.98*w_r*w_r*w_r*w_r*w_r);
	}
#endif

//gate
#if defined(BLEND) && defined(USE_NORMAL)
	float2 gate = float2(PSInput.cPos.x+PSInput.cPos.z,PSInput.cPos.y);
	if(1.5<PSInput.block && PSInput.block<2.5)diffuse=lerp(diffuse,lerp(float4(.2,0,1,.5),float4(1,.5,1,1),(snoise(gate+snoise(gate+time*.1)-time*.1)*.5+.5)*(dotN*-.5+1.)),.7);
	else if(2.5<PSInput.block && diffuse.a>.5 && sat<.2)diffuse.rgb=lerp((FOG_COLOR.rgb+tex1.rgb)*.5,diffuse.rgb,dotN*.9+.1);
#endif

#ifdef FOG
	diffuse.rgb = lerp( diffuse.rgb, PSInput.fogColor.rgb, PSInput.fogColor.a );
#endif

	PSOutput.color = diffuse;

#ifdef VR_MODE
	// On Rift, the transition from 0 brightness to the lowest 8 bit value is abrupt, so clamp to
	// the lowest 8 bit value.
	PSOutput.color = max(PSOutput.color, 1 / 255.0f);
#endif

#endif // BYPASS_PIXEL_SHADER
}