# meshes / proxies

本包代理网格由 `scripts/mid_realism_builders.gd` 运行时生成（Box / Cylinder / Quad / Sphere），便于 CLI 与 GameCity 直接实例化。

| Proxy | Builder API | Spec |
|-------|-------------|------|
| Road arterial | `build_ground_road(parent)` | 沥青 PBR + curb + 标线贴花 |
| Ramp | `build_ramp(parent, segs=40)` | 重叠甲板匝道（样条占位） |
| Glass building | `build_glass_building(parent)` | 幕墙玻璃 + ReflectionProbe |
| Tree | `build_tree(parent, pos)` | 树干 + 交叉 billboard 树冠 + 体积球 |
| Vehicle | `build_vehicle(parent, pos, yaw, body_mat, van=false)` | 车身 clearcoat + 玻璃舱 + 轮 |
| Overlays | `build_overlay_accents(parent)` | 势力角标 / 电力 / 拥堵 — **独立层** |

MultiMesh：量产时按 (mesh, material) 批；样本保持离散 MeshInstance3D 便于手调。
