// __multiversion__
// This signals the loading code to prepend either #version 100 or #version 300 es as apropriate.

#if __VERSION__ >= 300
	#define varying in
	#define texture2D texture
	out vec4 FragColor;
	#define gl_FragColor FragColor
#endif
varying vec4 color;
void main(){gl_FragColor = color;}
