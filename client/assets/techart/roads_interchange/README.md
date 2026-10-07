# roads_interchange — 中等写实立交包

> **状态：已落入 GameCity（M1）** · 样本用 Forward+ 打开 · 无 HUD · 工程默认仍是 GL Compatibility

磁盘路径：`client/assets/techart/roads_interchange/`  
`res://` 前缀：`res://client/assets/techart/roads_interchange/`

视觉目标：中等写实自研（独显下约 ceiling 35–50%），不以 CS2 静帧为验收。

---

## 要求

- Godot 4.3（与 GameCity `project.godot` 的 `4.3` feature 一致）
- 样本画面（SSR / SSAO / 玻璃）按 **Forward+** 看。工程默认保持 `gl_compatibility`，无头冒烟不要改 `project.godot`
- 1920×1080 视口推荐；阴影与后处理见下方清单

## 目录

| Path | Content |
|------|---------|
| `materials/` | 可共享 StandardMaterial3D（沥青 PBR、混凝土、玻璃、草地、车漆、overlay） |
| `textures/` | albedo / normal / roughness / 标线贴花 / 树冠 |
| `meshes/` | 代理规格说明；几何由 builders 生成 |
| `scripts/mid_realism_builders.gd` | 可复用道路/匝道/玻璃楼/树/车 builders |
| `scripts/sample_interchange.gd` | 样本场景驱动（可选截帧） |
| `scenes/sample_interchange.tscn` | **主样本** — 无 HUD。入口 `res://client/techart_sample.tscn`，不改 `client/main.tscn` |
| `preview/` | 生产截帧 |
| `docs/` | 光照预设与代理规格 |

## 如何打开样本

GameCity 只有仓库根这一份 `project.godot`。`res://client/main.tscn` 仍是默认主场景。看立交样本时单独覆盖渲染器，不要改工程默认值：

```bash
# 编辑器：用 Forward+ 运行（项目设置里只对这一次运行选 Forward+，或用下面的 CLI）
# 薄入口（实例化无 HUD 样本，不碰 listen-host）：
godot --path . --rendering-method forward_plus res://client/techart_sample.tscn

# 直接打开包内样本：
godot --path . --rendering-method forward_plus \
  res://client/assets/techart/roads_interchange/scenes/sample_interchange.tscn
```

等价脚本：`client/run_techart_sample.sh`（只给这一次进程加 `--rendering-method forward_plus`）。

截帧：`CITY_MVP_CAPTURE=1`（可选 `CITY_MVP_CAPTURE_S02=1`）。写出 `preview/prod-mid-s01-1920x1080.png` 与 `preview/prod-mid-s02-1920x1080.png`。

## Environment / 光照清单（样本已内置）

复制 `sample_interchange.tscn` 内 `WorldEnvironment` + `DirectionalLight3D`，或按此核对：

| 项 | 推荐值 |
|----|--------|
| Sky | ProceduralSky（顶 `#5989D9` 系蓝，地平线偏灰绿） |
| Tonemap | ACES，exposure 1.0 |
| **SSR** | on · max_steps 64 · fade_in 0.15 · fade_out 2.0 |
| **SSAO** | on · radius 1.35 · intensity 1.8 · power 1.5 |
| **Glow** | on · intensity 0.35 · bloom 0.08 · hdr_threshold 0.9 |
| Ambient | 来自天空 · sky_contribution 0.75 · energy 0.55 |
| DirectionalLight3D | energy 1.55 · color 暖白 · **shadow_enabled** |
| Shadow | mode Orthogonal · max_distance 160 · bias 0.02 · normal_bias 1.5 · blur 1.25 |
| Project（独显） | shadow map **8192** · MSAA **4×** · soft shadow quality High |
| Project（lavapipe） | shadow map **4096** · MSAA **2–4×** 即可 |

玻璃楼旁附带 `ReflectionProbe`（UPDATE_ALWAYS，intensity 0.85）。

## 如何实例化材质

1. **编辑器：** 拖 `materials/mat_*.tres` 到 MeshInstance3D → Material Override（共享，勿 duplicate 改色）。
2. **代码：** `preload("res://client/assets/techart/roads_interchange/materials/mat_road_asphalt.tres")`。
3. **Builders：** `MidRealismBuilders.ensure_materials()` 后用 `mat_asphalt` 等字段（CLI 无 `.import` 时走 ImageTexture 回退）。

### res:// 前缀（已按本仓库核对）

`project.godot` 在仓库根，现有脚本用 `res://client/...` 和 `res://server/...`。本包因此使用：

`res://client/assets/techart/roads_interchange/`

交接说明里的 `res://assets/techart/roads_interchange/` 少了 `client/`，在本仓库对不上磁盘目录，没有采用。`.tres` ExtResource、`.tscn`、`mid_realism_builders.gd` 的 `PACK`、`sample_interchange.gd` 的 `OUT_S01` / `OUT_S02` 都已换成上面的前缀。

## Overlay 层（重要）

| Overlay | Hex | Material |
|---------|-----|----------|
| Faction A | `#2EE6A8` | `mat_faction_a.tres` |
| Faction B | `#FF5C7A` | `mat_faction_b.tres` |
| Power | `#F5D76E` | `mat_service_power.tres` |
| Congestion | `#F0C93A` | `mat_road_congestion.tres` |

- Overlay 是 **独立薄网格 / 角标**，走 `faction_overlay` / `services` 层。
- **禁止**把势力色或拥堵色 bake 进沥青/混凝土/玻璃 albedo。
- 世界材质推 CS2-ish PBR；overlay 保持可读发光（emission ≤ 0.35）。

## 世界材质一览

| Material | Role |
|----------|------|
| `mat_road_asphalt` | 沥青 albedo+normal+rough |
| `mat_road_curb` | 路缘 |
| `mat_concrete_structure` | 墩柱/挡墙/楼板 |
| `mat_terrain_grass` | 草地 |
| `mat_building_glass` | 幕墙玻璃（金属高、粗糙极低） |
| `mat_building_frame` | 窗框金属 |
| `mat_tree_bark` / `mat_tree_canopy` | 树代理 |
| `mat_vehicle_*` / `mat_vehicle_glass` | 车漆 clearcoat + 舱玻璃 |
| `mat_lane_decal` | 标线贴花基底（运行时赋贴图） |

## 可交接检查

- [x] materials + textures 齐全
- [x] 无 HUD 样本场景
- [x] 光照 / SSR / SSAO / Glow / 阴影清单
- [x] Overlay 分层说明
- [x] Builders 可复用
- [x] 视觉目标文档指向本包

光照细节见 `docs/LIGHT_PRESETS.md`。样本场景没有 HUD。
