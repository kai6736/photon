/*
--------------------------------------------------------------------------------

  Photon Shader by SixthSurge

  program/gbuffer/solid.fsh:
  Handle terrain, entities, the hand, beacon beams and spider eyes

--------------------------------------------------------------------------------
*/

#include "/include/global.glsl"

/* DRAWBUFFERS:1 */

#ifdef NORMAL_MAPPING
/* DRAWBUFFERS:12 */
#endif

#ifdef SPECULAR_MAPPING
/* DRAWBUFFERS:12 */
#endif

layout (location = 0) out vec4 gbuffer_data_0; // albedo, block ID, flat normal, light levels
layout (location = 1) out vec4 gbuffer_data_1; // detailed normal, specular map (optional)

in vec2 uv;
in vec2 light_access;

flat in uint object_id;
flat in vec4 tint;
flat in mat3 tbn;

#ifdef POM
flat in vec2 atlas_tile_offset;
flat in vec2 atlas_tile_scale;
#endif

#ifdef PROGRAM_TERRAIN
in float vertex_ao;
#endif

uniform sampler2D gtexture;

#ifdef NORMAL_MAPPING
uniform sampler2D normals;
#endif

#ifdef SPECULAR_MAPPING
uniform sampler2D specular;
#endif

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;

uniform vec3 cameraPosition;

uniform float near;
uniform float far;

uniform vec4 entityColor;

uniform int frameCounter;
uniform float frameTimeCounter;

uniform vec2 view_res;
uniform vec2 view_pixel_size;
uniform vec2 taa_offset;

#include "/include/utility/dithering.glsl"
#include "/include/utility/encoding.glsl"
#include "/include/utility/fast_math.glsl"
#include "/include/utility/random.glsl"
#include "/include/utility/space_conversion.glsl"

const float lod_bias = log2(taau_render_scale);

#if   TEXTURE_FORMAT == TEXTURE_FORMAT_LAB
void decode_normal_map(vec3 normal_map, out vec3 normal, out float ao) {
	normal.xy = normal_map.xy * 2.0 - 1.0;
	normal.z  = sqrt(clamp01(1.0 - dot(normal.xy, normal.xy)));
	ao        = normal_map.z;
}
#elif TEXTURE_FORMAT == TEXTURE_FORMAT_OLD
void decode_normal_map(vec3 normal_map, out vec3 normal, out float ao) {
	normal  = normal_map * 2.0 - 1.0;
	ao      = length(normal);
	normal *= rcp(ao);
}
#endif

uniform sampler2D noisetex;

#ifdef PROGRAM_BLOCK
vec3 draw_end_portal() {
	const int   layer_count = 8;       // Number of layers
	const float depth_scale = 0.33;    // Apparent distance between layers
	const float depth_fade = 0.5;      // How quickly the layers fade to black
	const float threshold = 0.99;      // Threshold for the "stars". Lower values mean more stars appear
	const float twinkle_speed = 0.4;   // How fast the stars appear to twinkle
	const float twinkle_amount = 0.04; // How many twinkling stars appear
	const vec3  color0 = pow(vec3(0.80, 0.90, 0.99), vec3(2.2));
	const vec3  color1 = pow(vec3(0.75, 0.40, 0.93), vec3(2.2));
	const vec3  color2 = pow(vec3(0.20, 0.70, 0.90), vec3(2.2));

	vec3 screen_pos = vec3(gl_FragCoord.xy * view_pixel_size * rcp(taau_render_scale), gl_FragCoord.z);
	vec3 view_pos = screen_to_view_space(screen_pos, true);
	vec3 scene_pos = view_to_scene_space(view_pos);

	vec3 world_pos = scene_pos + cameraPosition;
	vec3 world_dir = normalize(scene_pos - gbufferModelViewInverse[3].xyz);

	// Get tangent-space position/direction without tangent/bitangent

	vec2 tangent_pos, tangent_dir;
	if (abs(tbn[2].x) > 0.5) {
		tangent_pos = world_pos.yz;
		tangent_dir = world_dir.yz / abs(world_dir.x + eps);
	} else if (abs(tbn[2].y) > 0.5) {
		tangent_pos = world_pos.xz;
		tangent_dir = world_dir.xz / abs(world_dir.y + eps);
	} else {
		tangent_pos = world_pos.xy;
		tangent_dir = world_dir.xy / abs(world_dir.z + eps);
	}

	vec3 result = vec3(0.0);

	for (int i = 0; i < layer_count; ++i) {
		// Random layer offset
		vec2 layer_offset = r2(i) * 512.0;

		// Make layers drift over time
		float angle = i * golden_angle;
		vec2 drift = 0.033 * vec2(cos(angle), sin(angle)) * frameTimeCounter * r1(i);

		// Snap tangent_pos to a grid and calculate a seed for the RNG
		ivec2 grid_pos = ivec2((tangent_pos + drift) * 32.0 + layer_offset);
		uint seed = uint(80000 * grid_pos.y + grid_pos.x);

		// 4 random numbers for this grid cell
		vec4 random = rand_next_vec4(seed);

		// Twinkling animation
		float twinkle_offset = tau * random.w;
		random.x *= 1.0 - twinkle_amount * cos(frameTimeCounter * twinkle_speed + twinkle_offset);

		// Stomp all values below threshold to zero
		float intensity = pow8(linear_step(threshold, 1.0, random.x));

		// Blend between the 3 colors
		vec3 color = mix(color0, color1, random.y);
		     color = mix(color, color2, random.z);

		// Fade away with depth
		float fade = exp2(-depth_fade * float(i));

		result += color * intensity * exp2(-3.0 * (1.0 - fade) * (1.0 - color)) * fade;

		// Step along the view ray
		tangent_pos += tangent_dir * depth_scale * gbufferProjection[1][1] * rcp(1.37);

		if (random.x > threshold) break;
	}

	result *= 0.8;
	result  = sqrt(result);
	result *= sqrt(result);

	return result;
}
#endif

void main() {
#if defined TAA && defined TAAU
	vec2 uv = gl_FragCoord.xy * view_pixel_size * rcp(taau_render_scale);
	if (clamp01(uv) != uv) discard;
#endif

	vec4 base_color   = texture(gtexture, uv, lod_bias) * tint;
#ifdef NORMAL_MAPPING
	vec3 normal_map   = texture(normals, uv, lod_bias).xyz;
#endif
#ifdef SPECULAR_MAPPING
	vec4 specular_map = texture(specular, uv, lod_bias);
#endif

#if defined PROGRAM_ENTITIES
	if (base_color.a < 0.1 && object_id != 101) discard; // Save transparent quad in boats, which masks out water
#else
	if (base_color.a < 0.1) discard;
#endif

#ifdef WHITE_WORLD
	base_color.rgb = vec3(1.0);
#endif

#if defined PROGRAM_TERRAIN && defined VANILLA_AO
	const float vertex_ao_strength = 0.9;
	const float vertex_ao_lift     = 0.7;
	base_color.rgb *= lift(vertex_ao, vertex_ao_lift) * vertex_ao_strength + (1.0 - vertex_ao_strength);
#endif

#ifdef PROGRAM_ENTITIES
	base_color.rgb = mix(base_color.rgb, entityColor.rgb, entityColor.a);
#endif

#ifdef PROGRAM_BLOCK
	// Parallax end portal
	if (object_id == 250) base_color.rgb = draw_end_portal();
#endif

#ifdef NORMAL_MAPPING
	vec3 normal; float ao;
	decode_normal_map(normal_map, normal, ao);

	normal = tbn * normal;
#endif

	float dither = interleaved_gradient_noise(gl_FragCoord.xy, frameCounter);

	gbuffer_data_0.x  = pack_unorm_2x8(base_color.rg);
	gbuffer_data_0.y  = pack_unorm_2x8(base_color.b, clamp01(float(object_id) * rcp(255.0)));
	gbuffer_data_0.z  = pack_unorm_2x8(encode_unit_vector(tbn[2]));
	gbuffer_data_0.w  = pack_unorm_2x8(dither_8bit(light_access, dither));

#ifdef NORMAL_MAPPING
	gbuffer_data_1.xy = encode_unit_vector(normal);
#endif

#ifdef SPECULAR_MAPPING
	gbuffer_data_1.z  = pack_unorm_2x8(specular_map.xy);
	gbuffer_data_1.w  = pack_unorm_2x8(specular_map.zw);
#endif

#if defined PROGRAM_GBUFFERS_BEACONBEAM
	// Discard the translucent edge part of the beam
	if (base_color.a < 0.99) discard;
#endif
 }
