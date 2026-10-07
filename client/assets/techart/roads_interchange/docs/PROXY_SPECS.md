# 代理规格 — 道路 / 玻璃 / 树 / 车

## 道路 (road)

- **材质：** `mat_road_asphalt`（1024 噪点 albedo + normal + roughness，UV scale 6）
- **路缘：** `mat_road_curb`（混凝土 tint）
- **标线：** Quad 贴花 `decal_lane_*.png` / `decal_arrow.png` / `decal_turn_arrow.png`，略抬 Y 防 z-fight
- **匝道：** `build_ramp(segs=40)` 重叠 Box 甲板 + 混凝土底板 + 墩柱（样条网格占位，非连续曲面）

## 玻璃 (glass)

- **材质：** `mat_building_glass` — metallic 0.95 · roughness 0.045 · clearcoat · 轻 refraction · tint 贴图
- **配套：** `mat_building_frame` 窗框；楼旁 `ReflectionProbe` size≈28
- **后处理依赖：** SSR + Sky；独显上反射更干净

## 树 (tree)

- 树干：`CylinderMesh` + `mat_tree_bark`
- 树冠：两张交叉 `QuadMesh` billboard + `mat_tree_canopy`（alpha scissor）
- 体积：半透明 `SphereMesh` 软化剪影
- **非**照片级；量产可换真树资产 / impostor，API 保持 `build_tree`

## 车 (vehicle)

- 车身 Box + clearcoat 车漆（dark / white / blue）
- 舱：半透明 `mat_vehicle_glass`
- 轮：小圆柱 ×4
- `van=true` 加长加高
- MultiMesh：按车漆材质分批；样本离散便于手摆

## Overlay（非世界 albedo）

势力 L 角标、电力菱形、拥堵条带 — 独立 Mesh + emission 材质。详见包 README。
