// 极简 GLB 预览器：只用原生 WebGL，不引入第三方库。
//
// 为什么自己写：整个前端刻意保持零框架、零 npm 依赖（见 README「桌面界面」一节），
// 而模型预览只需要「画三角形 + 转一转让用户看清形状」。
// glTF 的完整规范很大，但 AssetRipper 导出的 GLB 只用到其中极小的子集：
//   一个或多个 node → mesh → primitive(POSITION + 可选 NORMAL/indices)
// 这里就按这个子集实现，解析不了的（例如带蒙皮/动画/压缩扩展的）会给出明确提示，
// 而不是白屏。
//
// 坐标系：glTF 是 Y 轴向上、右手系，Unity 是 Y 上、左手系。
// 这里只做展示，直接把 Z 轴取反即可让绕序正确（Unity 导出的 mesh 是 Z 反转的）。

const GLB_MAGIC = 0x46546C67; // 'glTF'
const CHUNK_JSON = 0x4E4F534A; // 'JSON'
const CHUNK_BIN = 0x004E4942; // 'BIN\0'

/**
 * 解析 GLB，返回 { positions: Float32Array, normals, indices, bounds }。
 * 不做完整的 glTF 支持：只抽第一个能渲染的 primitive。
 */
export function parseGlb(buffer) {
    const view = new DataView(buffer);
    if (buffer.byteLength < 20 || view.getUint32(0, true) !== GLB_MAGIC) {
        throw new Error('不是有效的 GLB 文件');
    }

    let offset = 12;
    let json = null;
    let bin = null;

    while (offset + 8 <= buffer.byteLength) {
        const length = view.getUint32(offset, true);
        const type = view.getUint32(offset + 4, true);
        const start = offset + 8;
        if (start + length > buffer.byteLength) {
            break;
        }
        if (type === CHUNK_JSON) {
            const text = new TextDecoder('utf-8').decode(new Uint8Array(buffer, start, length));
            json = JSON.parse(text);
        } else if (type === CHUNK_BIN) {
            bin = new Uint8Array(buffer, start, length);
        }
        offset = start + length + ((4 - (length % 4)) % 4);
    }

    if (!json) {
        throw new Error('GLB 里没有 JSON 块');
    }
    if (!bin) {
        throw new Error('GLB 里没有二进制块');
    }

    const meshes = json.meshes ?? [];
    for (const mesh of meshes) {
        for (const primitive of mesh.primitives ?? []) {
            const attributes = primitive.attributes ?? {};
            if (attributes.POSITION === undefined) {
                continue;
            }
            // 只支持三角形列表，其它模式（点/线）在模型预览里没有意义。
            if (primitive.mode !== undefined && primitive.mode !== 4) {
                continue;
            }

            const positions = readAccessor(json, bin, attributes.POSITION);
            if (!positions) {
                continue;
            }
            const normals = attributes.NORMAL !== undefined
                ? readAccessor(json, bin, attributes.NORMAL)
                : null;
            const indices = primitive.indices !== undefined
                ? readIndices(json, bin, primitive.indices)
                : null;

            return {
                positions,
                normals,
                indices,
                bounds: computeBounds(positions),
            };
        }
    }

    throw new Error('这个模型没有可渲染的三角形网格');
}

function componentTypeSize(componentType) {
    switch (componentType) {
        case 5120: case 5121: return 1; // BYTE / UNSIGNED_BYTE
        case 5122: case 5123: return 2; // SHORT / UNSIGNED_SHORT
        case 5125: case 5126: return 4; // UNSIGNED_INT / FLOAT
        default: return 4;
    }
}

function readBytes(json, bin, accessorIndex) {
    const accessor = json.accessors?.[accessorIndex];
    if (!accessor) {
        return null;
    }
    const bufferView = json.bufferViews?.[accessor.bufferView];
    if (!bufferView) {
        return null;
    }
    // 只支持「数据就在 GLB 自己的二进制块里」这一种（buffer 0）。
    if ((bufferView.buffer ?? 0) !== 0) {
        return null;
    }
    const base = (bufferView.byteOffset ?? 0) + (accessor.byteOffset ?? 0);
    const length = bufferView.byteLength;
    return { bytes: bin.subarray(base, base + length), accessor, bufferView };
}

function readAccessor(json, bin, accessorIndex) {
    const raw = readBytes(json, bin, accessorIndex);
    if (!raw) {
        return null;
    }
    const { accessor, bytes } = raw;
    const width = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4 }[accessor.type] ?? 1;
    const size = componentTypeSize(accessor.componentType);
    const stride = raw.bufferView.byteStride ?? width * size;
    const count = accessor.count;

    const out = new Float32Array(count * width);
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    for (let i = 0; i < count; i += 1) {
        for (let c = 0; c < width; c += 1) {
            const at = i * stride + c * size;
            let value;
            switch (accessor.componentType) {
                case 5126: value = dv.getFloat32(at, true); break;
                case 5125: value = dv.getUint32(at, true); break;
                case 5123: value = dv.getUint16(at, true); break;
                case 5122: value = dv.getInt16(at, true); break;
                case 5121: value = dv.getUint8(at); break;
                case 5120: value = dv.getInt8(at); break;
                default: value = 0;
            }
            // 归一化的整型需要还原到 [0,1]
            if (accessor.normalized) {
                value = accessor.componentType === 5121 ? value / 255
                    : accessor.componentType === 5123 ? value / 65535
                        : value;
            }
            out[i * width + c] = value;
        }
    }
    return out;
}

function readIndices(json, bin, accessorIndex) {
    const raw = readBytes(json, bin, accessorIndex);
    if (!raw) {
        return null;
    }
    const { accessor, bytes } = raw;

    // 必须按 accessor 自己的分量类型选 TypedArray：
    // WebGL1 的 drawElements 类型参数要和缓冲区的实际元素大小一致，
    // 而 UNSIGNED_INT(5125) 还需要 OES_element_index_uint 扩展。
    // TODO 用 Uint32 缓冲去配 UNSIGNED_INT 在缺扩展时会报 GL_INVALID_ENUM(1280)，
    // 表现就是「画布完全空白但没有任何 JS 异常」。
    const glType = accessor.componentType === 5125 ? 'UNSIGNED_INT'
        : accessor.componentType === 5123 ? 'UNSIGNED_SHORT'
            : 'UNSIGNED_BYTE';

    const size = componentTypeSize(accessor.componentType);
    const stride = raw.bufferView.byteStride ?? size;
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const Ctor = accessor.componentType === 5125 ? Uint32Array
        : accessor.componentType === 5123 ? Uint16Array
            : Uint8Array;
    const out = new Ctor(accessor.count);
    for (let i = 0; i < accessor.count; i += 1) {
        const at = i * stride;
        out[i] = accessor.componentType === 5125 ? dv.getUint32(at, true)
            : accessor.componentType === 5123 ? dv.getUint16(at, true)
                : dv.getUint8(at);
    }
    return { data: out, glType };
}

function computeBounds(positions) {
    const min = [Infinity, Infinity, Infinity];
    const max = [-Infinity, -Infinity, -Infinity];
    for (let i = 0; i < positions.length; i += 3) {
        for (let c = 0; c < 3; c += 1) {
            const v = positions[i + c];
            if (v < min[c]) { min[c] = v; }
            if (v > max[c]) { max[c] = v; }
        }
    }
    const center = [(min[0] + max[0]) / 2, (min[1] + max[1]) / 2, (min[2] + max[2]) / 2];
    let radius = 0;
    for (let c = 0; c < 3; c += 1) {
        radius = Math.max(radius, (max[c] - min[c]) / 2);
    }
    return { min, max, center, radius: radius || 1 };
}

// ---- 极简矩阵（列主序，和 WebGL 一致）----

function perspective(fov, aspect, near, far) {
    const f = 1 / Math.tan(fov / 2);
    const nf = 1 / (near - far);
    return new Float32Array([
        f / aspect, 0, 0, 0,
        0, f, 0, 0,
        0, 0, (far + near) * nf, -1,
        0, 0, 2 * far * near * nf, 0,
    ]);
}

function lookAt(eye, center, up) {
    const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
    const norm = (v) => {
        const l = Math.hypot(v[0], v[1], v[2]) || 1;
        return [v[0] / l, v[1] / l, v[2] / l];
    };
    const cross = (a, b) => [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ];
    const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

    const z = norm(sub(eye, center));
    const x = norm(cross(up, z));
    const y = cross(z, x);
    return new Float32Array([
        x[0], y[0], z[0], 0,
        x[1], y[1], z[1], 0,
        x[2], y[2], z[2], 0,
        -dot(x, eye), -dot(y, eye), -dot(z, eye), 1,
    ]);
}

function multiply(a, b) {
    const out = new Float32Array(16);
    for (let c = 0; c < 4; c += 1) {
        for (let r = 0; r < 4; r += 1) {
            let sum = 0;
            for (let k = 0; k < 4; k += 1) {
                sum += a[k * 4 + r] * b[c * 4 + k];
            }
            out[c * 4 + r] = sum;
        }
    }
    return out;
}

const VERTEX_SHADER = `
attribute vec3 aPosition;
attribute vec3 aNormal;
uniform mat4 uMvp;
uniform mat4 uModel;
varying vec3 vNormal;
void main() {
    vNormal = mat3(uModel) * aNormal;
    gl_Position = uMvp * vec4(aPosition, 1.0);
}`;

// 双光源的简易朗伯着色：足够看清形状，不需要法线贴图/材质。
const FRAGMENT_SHADER = `
precision mediump float;
varying vec3 vNormal;
void main() {
    vec3 n = normalize(vNormal);
    vec3 key = normalize(vec3(0.4, 0.8, 0.6));
    vec3 fill = normalize(vec3(-0.6, -0.2, -0.5));
    float light = 0.28 + 0.62 * max(dot(n, key), 0.0) + 0.18 * max(dot(n, fill), 0.0);
    gl_FragColor = vec4(vec3(0.62, 0.74, 0.95) * light, 1.0);
}`;

function compile(gl, type, source) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        const log = gl.getShaderInfoLog(shader);
        gl.deleteShader(shader);
        throw new Error(`着色器编译失败：${log}`);
    }
    return shader;
}

/**
 * 在 container 里创建一个可拖拽旋转的 3D 预览。
 * @returns {Promise<{dispose(): void}>}
 */
export async function renderModel(container, url) {
    const response = await fetch(url);
    if (!response.ok) {
        throw new Error(response.status === 404 ? '这个模型无法解码' : `加载失败 (${response.status})`);
    }
    const buffer = await response.arrayBuffer();
    const mesh = parseGlb(buffer);

    const canvas = document.createElement('canvas');
    canvas.className = 'model-canvas';
    // 保持正方形绘制区，避免透视被拉伸。
    //
    // 尺寸取容器「较短边」并夹在 [160, 420]：
    //   - 空容器宽度可能是 0（还没插进 DOM），用 FALLBACK_SIZE 兜底，
    //     否则 canvas 会是 0x0，viewport 变成 (0,0,0,0)，画什么都不显示；
    //   - 容器很宽很扁时（详情栏常见）必须按高度算，否则方形画布比容器还高，
    //     会被 CSS 裁掉，看起来就像「什么都没画」。
    const FALLBACK_SIZE = 320;
    const MIN_SIZE = 120;
    const MAX_SIZE = 420;
    const resize = () => {
        const rect = container.getBoundingClientRect();
        const candidates = [rect.width, rect.height].filter((v) => v > 0);
        const measured = candidates.length ? Math.min(...candidates) : FALLBACK_SIZE;
        const size = Math.max(MIN_SIZE, Math.min(measured, MAX_SIZE));
        const ratio = window.devicePixelRatio || 1;
        canvas.width = Math.round(size * ratio);
        canvas.height = Math.round(size * ratio);
        canvas.style.width = `${size}px`;
        canvas.style.height = `${size}px`;
    };

    const gl = canvas.getContext('webgl', { antialias: true, alpha: true });
    if (!gl) {
        throw new Error('当前环境不支持 WebGL');
    }

    resize();
    container.replaceChildren(canvas);

    const program = gl.createProgram();
    gl.attachShader(program, compile(gl, gl.VERTEX_SHADER, VERTEX_SHADER));
    gl.attachShader(program, compile(gl, gl.FRAGMENT_SHADER, FRAGMENT_SHADER));
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
        throw new Error(`着色器链接失败：${gl.getProgramInfoLog(program)}`);
    }
    gl.useProgram(program);

    const positionBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, mesh.positions, gl.STATIC_DRAW);
    const positionLoc = gl.getAttribLocation(program, 'aPosition');
    gl.enableVertexAttribArray(positionLoc);
    gl.vertexAttribPointer(positionLoc, 3, gl.FLOAT, false, 0, 0);

    // 没有法线就退化成平涂：对着色有影响，但不影响看清轮廓。
    let normalBuffer = null;
    const normalLoc = gl.getAttribLocation(program, 'aNormal');
    if (mesh.normals && normalLoc >= 0) {
        normalBuffer = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, normalBuffer);
        gl.bufferData(gl.ARRAY_BUFFER, mesh.normals, gl.STATIC_DRAW);
        gl.enableVertexAttribArray(normalLoc);
        gl.vertexAttribPointer(normalLoc, 3, gl.FLOAT, false, 0, 0);
    } else if (normalLoc >= 0) {
        gl.disableVertexAttribArray(normalLoc);
        gl.vertexAttrib3f(normalLoc, 0, 0, 1);
    }

    let indexBuffer = null;
    let indexGlType = null;
    let indexCount = 0;
    if (mesh.indices) {
        // UNSIGNED_INT 索引在 WebGL1 需要扩展；没有就放弃索引、退化成 drawArrays。
        const needsUint = mesh.indices.glType === 'UNSIGNED_INT';
        const uintOk = !needsUint || !!gl.getExtension('OES_element_index_uint');
        if (uintOk) {
            indexBuffer = gl.createBuffer();
            gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
            gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, mesh.indices.data, gl.STATIC_DRAW);
            indexGlType = needsUint ? gl.UNSIGNED_INT
                : mesh.indices.glType === 'UNSIGNED_SHORT' ? gl.UNSIGNED_SHORT
                    : gl.UNSIGNED_BYTE;
            indexCount = mesh.indices.data.length;
        }
    }

    const uMvp = gl.getUniformLocation(program, 'uMvp');
    const uModel = gl.getUniformLocation(program, 'uModel');

    // 相机绕模型转：拖拽改 yaw/pitch，滚轮缩放。
    let yaw = Math.PI * 0.25;
    let pitch = Math.PI * 0.18;
    let zoom = 1;
    let dragging = false;
    let lastX = 0;
    let lastY = 0;
    let frame = 0;

    const draw = () => {
        const { center, radius } = mesh.bounds;
        const distance = radius * 3.1 / zoom;
        const eye = [
            center[0] + distance * Math.cos(pitch) * Math.sin(yaw),
            center[1] + distance * Math.sin(pitch),
            center[2] + distance * Math.cos(pitch) * Math.cos(yaw),
        ];
        const projection = perspective(Math.PI / 4, 1, radius * 0.01, radius * 40);
        const viewM = lookAt(eye, center, [0, 1, 0]);
        const model = new Float32Array([
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, -1, 0, // Z 反转：Unity 与 glTF 的手性差异
            -center[0], -center[1], center[2], 1,
        ]);
        // 模型矩阵作用于「平移到原点」的几何，避免大坐标下的浮点抖动。
        const mvp = multiply(projection, multiply(viewM, model));

        gl.uniformMatrix4fv(uMvp, false, mvp);
        gl.uniformMatrix4fv(uModel, false, model);

        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gl.enable(gl.DEPTH_TEST);

        if (indexBuffer) {
            gl.drawElements(gl.TRIANGLES, indexCount, indexGlType, 0);
        } else {
            gl.drawArrays(gl.TRIANGLES, 0, mesh.positions.length / 3);
        }
    };

    const requestDraw = () => {
        if (frame) { return; }
        frame = requestAnimationFrame(() => {
            frame = 0;
            draw();
        });
    };

    const onPointerDown = (event) => {
        dragging = true;
        lastX = event.clientX;
        lastY = event.clientY;
        canvas.setPointerCapture?.(event.pointerId);
    };
    const onPointerMove = (event) => {
        if (!dragging) { return; }
        yaw -= (event.clientX - lastX) * 0.01;
        pitch = Math.max(-1.4, Math.min(1.4, pitch + (event.clientY - lastY) * 0.01));
        lastX = event.clientX;
        lastY = event.clientY;
        requestDraw();
    };
    const onPointerUp = () => { dragging = false; };
    const onWheel = (event) => {
        event.preventDefault();
        zoom = Math.max(0.35, Math.min(6, zoom * (event.deltaY > 0 ? 0.9 : 1.1)));
        requestDraw();
    };
    const onResize = () => { resize(); requestDraw(); };

    canvas.addEventListener('pointerdown', onPointerDown);
    canvas.addEventListener('pointermove', onPointerMove);
    canvas.addEventListener('pointerup', onPointerUp);
    canvas.addEventListener('pointercancel', onPointerUp);
    canvas.addEventListener('wheel', onWheel, { passive: false });
    window.addEventListener('resize', onResize);

    // 容器进入 DOM、或侧边面板宽度变化之后再量一次尺寸。
    // 首次绘制发生在 append 之前，那一刻容器尺寸还是 0。
    let observer = null;
    if (typeof ResizeObserver === 'function') {
        observer = new ResizeObserver(() => onResize());
        observer.observe(container);
    }
    requestAnimationFrame(onResize);

    draw();

    return {
        dispose() {
            window.removeEventListener('resize', onResize);
            observer?.disconnect();
            if (frame) { cancelAnimationFrame(frame); }
            gl.deleteBuffer(positionBuffer);
            if (normalBuffer) { gl.deleteBuffer(normalBuffer); }
            if (indexBuffer) { gl.deleteBuffer(indexBuffer); }
            gl.deleteProgram(program);
        },
    };
}
