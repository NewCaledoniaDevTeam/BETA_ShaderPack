// __multiversion__
// This signals the loading code to prepend either #version 100 or #version 300 es as apropriate.

#include "fragmentVersionCentroid.h"

#if __VERSION__ >= 300
	#define USE_NORMAL
	#ifndef BYPASS_PIXEL_SHADER
		#if defined(TEXEL_AA) && defined(TEXEL_AA_FEATURE)
			_centroid in highp vec2 uv0;
			_centroid in highp vec2 uv1;
		#else
			_centroid in vec2 uv0;
			_centroid in vec2 uv1;
		#endif
	#endif
#else
	#ifndef BYPASS_PIXEL_SHADER
		varying vec2 uv0;
		varying vec2 uv1;
	#endif
#endif

varying vec4 color;
#ifdef FOG
	varying float fog;
#endif

#ifdef GL_FRAGMENT_PRECISION_HIGH
	#define HM highp
#else
	#define HM mediump
#endif
varying HM vec3 cPos;
varying HM vec3 wPos;
varying float wf;

#include "util.h"
#include "snoise.h"
uniform HM float TOTAL_REAL_WORLD_TIME;
uniform vec4 FOG_COLOR;
uniform vec2 FOG_CONTROL;

LAYOUT_BINDING(0) uniform sampler2D TEXTURE_0;
LAYOUT_BINDING(1) uniform sampler2D TEXTURE_1;
LAYOUT_BINDING(2) uniform sampler2D TEXTURE_2;

vec3 curve(vec3 x){
	const float A = 0.50;
	const float B = 0.10;
	const float C = 0.40;
	const float D = 0.65;
	const float E = 0.05;
	const float F = 0.20;
	return ((x*(A*x+C*B)+D*E)/(x*(A*x+B)+D*F))-E/F;
}

vec3 tonemap(vec3 col, vec3 gamma){
	const float saturation = 1.2;
	//const float exposure = 1.0;
	col = pow(col,1./gamma);
	float luma = dot(col, vec3(0.298912, 0.586611, 0.114478));
	col = curve((col-luma)*saturation+luma);
	return col/curve(vec3(1/*1./exposure*/));
}

vec4 water(vec4 col,float weather,float uw,vec3 tex1){
	HM float time = TOTAL_REAL_WORLD_TIME; vec3 p = cPos;
	float sun = smoothstep(.5,.9,uv1.y);
	vec3 T = normalize(abs(wPos)); float cosT = length(T.xz);
	p.xz = p.xz*vec2(1.0,0.4)/*Aspect ratio*/+smoothstep(0.,8.,abs(p.y-8.))*.5;
	float n = (snoise(p.xz-time*.5)+snoise(vec2(p.x-time,(p.z+time)*.5)))+2.;//[0.~4.]

	vec4 diffuse = mix(col,col*mix(1.5,1.3,T.y*uw),pow(1.-abs(n-2.)*.5,bool(uw)?1.5:2.5));
	if(bool(uw)){//new C_REF
		highp vec2 skp = (wPos.xz+n*4./*Wave height*/*wPos.xz/max(length(wPos.xz),.5))*cosT*.1;
		skp.x -= time*.05;
		vec2 ssreff = mix(vec2(.7,.7),vec2(.8,.6),clamp(FOG_COLOR.r-FOG_COLOR.g,0.,.4)*2.5);
		vec4 skc = mix(mix(col,FOG_COLOR,cosT*.8),vec4(mix(tex1,FOG_COLOR.rgb,cosT*.7),1),smoothstep(0.,1.,snoise(skp)));
		float s_ref = sun*weather*smoothstep(.7,0.,T.y)*mix(.3,1.,smoothstep(1.5,4.,n))*.9;
		skc = mix(skc,vec4(1),smoothstep(3.+abs(wPos.y)*.3,0.,abs(wPos.z))*s_ref);
		diffuse = mix(diffuse,skc,cosT*sun);
	}
	return mix(diffuse,col,min(.7,T.y));
}

void main()
{
#ifdef BYPASS_PIXEL_SHADER
	gl_FragColor = vec4(0, 0, 0, 0);
	return;
#else

#if USE_TEXEL_AA
	HM vec4 diffuse = texture2D_AA(TEXTURE_0, uv0);
#else
	HM vec4 diffuse = texture2D(TEXTURE_0, uv0);
#endif

#ifdef SEASONS_FAR
	diffuse.a = 1.0;
#endif

#if USE_ALPHA_TEST
	#ifdef ALPHA_TO_COVERAGE
	#define ALPHA_THRESHOLD 0.05
	#else
	#define ALPHA_THRESHOLD 0.52
	#endif
	if(diffuse.a < ALPHA_THRESHOLD)discard;
#endif

vec4 inColor = color;
#ifdef BLEND
	diffuse.a *= inColor.a;
#endif

vec4 tex1 = texture2D(TEXTURE_1,uv1);
#ifndef ALWAYS_LIT
	diffuse *= tex1;
#endif

#ifndef SEASONS
	#if !USE_ALPHA_TEST && !defined(BLEND)
		diffuse.a = inColor.a;
	#endif

	diffuse.rgb *= inColor.rgb;
#else
	vec2 uv = inColor.xy;
	diffuse.rgb *= mix(vec3(1.0,1.0,1.0), texture2D( TEXTURE_2, uv).rgb*2.0, inColor.b);
	diffuse.rgb *= inColor.aaa;
	diffuse.a = 1.0;
#endif

//datas
HM float time = TOTAL_REAL_WORLD_TIME;
float nv = step(texture2D(TEXTURE_1,vec2(0)).r,.5);
float dusk = min(smoothstep(.1,.4,daylight.y),smoothstep(1.,.8,daylight.y));
float uw = step(FOG_CONTROL.x,0.);
float nether = FOG_CONTROL.x/FOG_CONTROL.y;nether=step(.1,nether)-step(.12,nether);
float sat = satur(diffuse.rgb);
vec4 ambient = mix(//vec4(gamma.rgb,saturation)
		vec4(1.,.97,.9,1.15),//indoor
	mix(
		vec4(.54,.72,.9,.9),//rain
	mix(mix(
		vec4(.45,.59,.9,1.),//night
		vec4(1.15,1.17,1.1,1.2),//day
	daylight.y),
		vec4(1.4,.9,.5,.8),//dusk
	dusk),weather),sun.y*nv);
	if(uw+nether>.5)ambient = vec4(FOG_COLOR.rgb*.6+.4,.8);
#ifdef USE_NORMAL
	HM vec3 N = normalize(cross(dFdx(cPos),dFdy(cPos)));
	float dotN = dot(normalize(-wPos),N);
#endif

//tonemap
diffuse.rgb = tone(diffuse.rgb,ambient);

//light_sorce
float lum = dot(diffuse.rgb,vec3(.299,.587,.114));
diffuse.rgb += max(fuv1.x-.5,0.)*(1.-lum*lum)*mix(1.,.3,daylight.x*sun.y)*vec3(1.0,0.65,0.3);

//ESBEwater
#ifdef FANCY
	#ifdef USE_NORMAL
		vec3 n = normalize(cross(dFdx(cPos),dFdy(cPos)));
	#endif
	if(wf+uw>.5){
		diffuse = water(diffuse,weather,1.-uw,tex1.rgb);
		#ifdef USE_NORMAL
			float w_r = 1.-dot(normalize(-wPos),n);
			diffuse.a = mix(diffuse.a,1.,.02+.98*w_r*w_r*w_r*w_r*w_r);
		#endif
	}
#endif

//shadow
float ao = 1.;
if(inColor.r==inColor.g && inColor.g==inColor.b)ao = smoothstep(.48*daylight.y,.52*daylight.y,inColor.g);
float Nl =
	#ifdef USE_NORMAL
		mix(1.,smoothstep(-.7+dusk,1.,dot(normalize(vec3(dusk*6.,4,3)),vec3(abs(N.x),N.yz))),sun.y);
	#else
		1.;
	#endif
diffuse.rgb *= 1.-mix(.5,0.,min(min(sun.x,ao),Nl))*(1.-max(0.,fuv1.x-sun.y*.7))*daylight.x;

//ESBE_sun_ref (unused)
//vec4 (1)… color, vec3 (1)… coordinates
/*#ifdef BLEND
if(diffuse.a!=0.){
	vec3 N = normalize(cross(dFdx(cPos),dFdy(cPos)));
	diffuse = mix(diffuse,vec4(1),.8*smoothstep(.9,1.,dot(normalize(vec3(1)),reflect(normalize(wPos),N))));
	diffuse = mix(diffuse,(FOG_COLOR+vec4(ambient,1))*.5,.7*clamp(1.-dot(normalize(-wPos),N),0.,1.));}
#endif*/

#ifdef FOG
	diffuse.rgb = mix( diffuse.rgb, FOG_COLOR.rgb, fog );
#endif

//#define DEBUG//Debug screen
#ifdef DEBUG
	HM vec2 subdisp = gl_FragCoord.xy/1024.;
	if(subdisp.x<1. && subdisp.y<1.){
		vec3 subback = vec3(1);
		#define sdif(X,W,Y,C) if(subdisp.x>X && subdisp.x<=X+W && subdisp.y<=Y)subback.rgb=C;
		sdif(0.,1.,.5,vec3(.5))
		sdif(0.,.2,daylight.y,vec3(1,.7,0))
		sdif(.2,.2,weather,vec3(.5,.5,1))
		sdif(.4,.1,dusk,vec3(1.,.5,.2))
		sdif(.5,.1,clamp(FOG_COLOR.r-FOG_COLOR.g,0.,.4)*2.5,vec3(1.,.5,.2))
		//fcol
		sdif(.6,.05,FOG_COLOR.r,vec3(1,.5,.5))sdif(.65,.05,FOG_COLOR.g,vec3(.5,1,.5))
		sdif(.7,.05,FOG_COLOR.b,vec3(.5,.5,1))sdif(.75,.05,FOG_COLOR.a,vec3(.7))
		//fctr
		sdif(.8,.1,FOG_CONTROL.x,vec3(1,.5,.5))sdif(.9,.1,FOG_CONTROL.y,vec3(.5,1,.5))
		diffuse = mix(diffuse,vec4(subback,1),.5);
		vec3 tone = tonemap(subdisp.xxx,ambient);
		if(subdisp.y<=tone.r+.005 && subdisp.y>=tone.r-.005)diffuse.rgb=vec3(1,0,0);
		if(subdisp.y<=tone.g+.005 && subdisp.y>=tone.g-.005)diffuse.rgb=vec3(0,1,0);
		if(subdisp.y<=tone.b+.005 && subdisp.y>=tone.b-.005)diffuse.rgb=vec3(0,0,1);
	}
#endif

	gl_FragColor = diffuse;

#endif // BYPASS_PIXEL_SHADER
}
