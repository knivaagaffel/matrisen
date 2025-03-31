#version 450

#extension GL_GOOGLE_include_directive : require
#extension GL_EXT_buffer_reference : require

#include "input_structures.glsl"

layout(location = 0) out vec3 outNormal;
layout(location = 1) out vec3 outColor;
layout(location = 2) out vec2 outUV;

struct Vertex {
    vec3 position;
    float uv_x;
    vec3 normal;
    float uv_y;
    vec4 color;
};

layout(buffer_reference, std430) readonly buffer VertexBuffer {
    Vertex vertices[];
};

//push constants block
layout(push_constant) uniform constants
{
    mat4 model;
    VertexBuffer vertexBuffer;
} pc;

void main()
{
    Vertex v = pc.vertexBuffer.vertices[gl_VertexIndex];

    vec4 position = vec4(v.position, 1.0f);

    gl_Position = sceneData.viewproj * pc.model * position;

    outNormal = (pc.model * vec4(v.normal, 0.f)).xyz;
    outColor = v.color.xyz * materialData.colorFactors.xyz;
    outUV.x = v.uv_x;
    outUV.y = v.uv_y;
}
