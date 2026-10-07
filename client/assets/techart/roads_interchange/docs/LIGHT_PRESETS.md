# 光照与后处理预设 — roads_interchange

来源：max probe `ceiling_max_quality` → 生产样本 `sample_interchange`。

## Day sunny（默认）

| 参数 | 值 |
|------|-----|
| DirectionalLight color | `(1, 0.97, 0.92)` |
| energy | `1.55` |
| specular | `0.85` |
| 方向 | 斜上方偏南（见场景 Transform） |
| shadow | Orthogonal · max_distance 160 · bias 0.02 · normal_bias 1.5 · blur 1.25 |

## Environment

| 特性 | 开/关 | 备注 |
|------|-------|------|
| ProceduralSky | on | 顶蓝 / 地平线灰绿 |
| Tonemap ACES | on | exposure 1.0 |
| SSR | on | 64 steps；玻璃可读关键 |
| SSAO | on | radius 1.35 · intensity 1.8 |
| Glow | on | 轻量；勿冲掉 RCI/overlay 色 |
| SSIL | off | 样本关闭以控预算 |
| Adjustment | contrast 1.06 · sat 1.08 | |

## GPU 档位

| 档 | shadow map | MSAA | 说明 |
|----|------------|------|------|
| lavapipe / CI | 4096 | 2–4× | 本箱验证档 |
| 独显演示 | 8192 | 4× | 软阴影过滤 High |
| 低端独显 | 4096 | 2× | 可关 SSR 保帧 |

勿为「更像 CS2」盲目开满；验收看自有中等写实语言（独显下约 ceiling 35–50%），见包 `README.md`。

这些预设写在 `scenes/sample_interchange.tscn` 的 `WorldEnvironment` 上。GameCity 默认渲染器仍是 GL Compatibility；SSR / SSAO 只在用 `--rendering-method forward_plus` 打开样本时生效。不要把这套环境抄进 `res://client/main.tscn`，也不要改 `project.godot` 的 `renderer/rendering_method`。
