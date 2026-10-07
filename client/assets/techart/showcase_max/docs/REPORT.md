# showcase_max REPORT

目标：用程序化几何加 CC0 贴图，把 GameCity 风格的街区在这台 M4 上用 Forward+ 推到能稳定渲染的最好画面。交付是截图和数据。

本文由 showcase worker 撰写、集成者存档（worker 的文件写入被工具策略拦下，正文原样保留，2026-10-08）。

## 0. 结论

- 截图档（MSAA 4× + TAA、VoxelGI 512、SSAO / SSIL / SSR、8192 阴影图、PSSM 4 级）1080p 游戏相机镜头 39–47 ms，电影镜头 55–57 ms，4K 131–175 ms。游戏相机镜头超出 ≤ 33 ms 的目标。
- 交互档（MetalFX Temporal 0.67×、SDFGI 3 级联、SSAO 中档、4096 阴影图、PSSM 2 级，关 SSIL / SSR / 体积雾）hero 镜头约 13–15 ms，满足目标，余量约 18 ms。
- 帧时大头不在几何：hero 镜头 891 次绘制、约 790 万图元（含阴影级联）。把 GI、屏幕空间特效、抗锯齿和阴影分辨率一起关掉后同一镜头从 40 降到 14 ms（单次未配对测量），也就是约 26 ms 花在后处理和光照质量档上。
- 单项成本从高到低（配对比值，见 §5）：MSAA 4× + TAA 约 +25%（相对不开抗锯齿），GI（VoxelGI 512 相对关闭）约 +18–28%，SSR 约 +15%，SSIL 约 +11%，体积雾约 +10%，SSAO 约 +8%，折射玻璃约 +3%。Glow、色调映射、自动曝光、天空类型在噪声内（±3%）。
- 机器会降频：同一配置 hero 镜头冷机 46 ms，长时间跑完基准后 63–72 ms。所以逐项对比一律用同进程交替测量的比值，不用绝对值。

## 1. 环境与方法

| 项 | 值 |
| --- | --- |
| 机器 | Apple M4，16 GB 统一内存，GPU 8 核（`system_profiler`），内建屏 2560×1664 |
| 引擎 | Godot 4.7.2.stable，Forward+，Metal 4.0（日志：`Metal 4.0 - Forward+ - Using Device #0: Apple - Apple M4 (Apple9)`） |
| 渲染入口 | `SubViewport` 固定尺寸（1920×1080 / 3840×2160），与窗口和 Retina 缩放无关 |
| 画质开关 | 全部由脚本在运行时设置，`project.godot` 未改 |

关于帧时的四条事实：

1. **GPU 计时在 Metal 上读不出来**。`RenderingServer.viewport_get_measured_render_time_gpu` 在每个镜头都返回 0。帧时因此用 `RenderingServer.force_draw` 连续渲染、每块结束读回图像（排空 GPU 队列）得到，记为 `draw_ms`。
2. **`TIME_PROCESS` 只在「一个进程只拍一个镜头」时可信**。它约每秒刷新一次；同一进程里先拍过别的镜头、做过 VoxelGI 烘焙之后，主循环以约 6.9 ms 空转，`TIME_PROCESS` 读到 0.2–0.4 ms，不代表渲染成本。§4 表里这种格子标「无效」。
3. **M4 在持续负载下降频**。同一配置冷机和热机相差 1.3–2×。逐项对比因此在同一进程内把基线和变体交替测 4 轮（R V V R R V V R 顺序），报告 4 轮比值的中位数；每个条目一个新进程，条目之间冷却 30 s。冷却足够时相同配置的比值落在 0.99–1.03。
4. **`sv.msaa_3d` 读回**：基准里记录了实际生效的 MSAA / TAA / 缩放。枚举值 `msaa=2` 是 4×，`0` 是关。

## 2. 内容规模

城市数据按游戏口径生成（`scripts/city_data.gd`，对齐 `docs/briefs/world-vertical-slice.md`）：

- 18×18 格，是 64×64 地图的一角；每格 30 m，路权半宽 7.3 m（行车道 9 m，含两侧 2 m 停车带，加两侧 2.8 m 人行道）。
- 地块有 owner（A / B / neutral）、zone（R / C / I）、`buildingTier` 0–2、`powerCovered`；道路边只走正交四邻且两端同阵营；电站 4 座，覆盖半径取 `SliceConstants.POWER_RADIUS_SUGGESTED = 4`。
- 当前种子数据：324 格，A 117 / B 89 / 中立 118；R 84 / C 46 / I 57；有建筑 175 栋，tier 2 共 31 栋；被电力覆盖 139 格；路边 316 条；拥堵热点 3 条。
- 几何全部由代码生成：建筑壳体和道路按 4×4 格分块、按材质分表面合并成 `ArrayMesh`（合并后约 25.8 万三角形），树和车用 `MultiMesh`。无头构建约 0.37 s。
- 贴图：Poly Haven CC0 15 套 PBR（albedo / ARM / GL 法线，单张 ≤ 2K，JPG），2 张 2K HDRI。出处见 `../CREDITS.md`。

R / C / I 的立面语言：R 是外凸窗洞、砖或抹灰、层线、阳台和空调外机、tier 0 坡屋顶；C 是带雨棚和招牌的店面（tier 0）、带遮阳翅的带形窗办公楼（tier 1）、玻璃幕墙塔楼加裙楼（tier 2）；I 是波纹板、条形高窗、卷帘门、锯齿或山墙屋顶、烟囱和储罐。窗内是互动映射的房间，黄昏窗户自发光。

## 3. 开启的特性与参数

截图档（`scripts/quality.gd` 的 `shot`）与交互档（`interactive`）。「成本」列引用 §5 的配对比值。

| 特性 | 截图档 | 交互档 | 参数 | 成本（比值） |
| --- | --- | --- | --- | --- |
| 天空 | Poly Haven HDRI 2K，经自写 sky shader | 同左 | 白天 `kloofendal_48d_partly_cloudy_puresky`，黄昏 `kloppenheim_06_puresky`；radiance 钳 3.0 / 2.4，可见背景钳 40，radiance 乘 1.0 / 0.5 | 与库存 `PanoramaSkyMaterial`、`PhysicalSkyMaterial` 差 ≤ 3%（噪声内） |
| 全局光照 | VoxelGI 细分 512；体积 440 / 300 / 1100(256) / 480 m（按镜头） | SDFGI 3 级联，单元 0.5–2.0 m（按镜头） | VoxelGI 运行时烘焙 6–13 s；SDFGI `use_occlusion`、`read_sky_light`、`bounce_feedback 0.6` | 关 GI 约 −15%（hero）/ −22%（近景） |
| SSAO | 开，ULTRA | 开，MEDIUM | radius 2.2，intensity 2.0，power 1.6，detail 0.6，horizon 0.06，light_affect 0.25 | 约 +8% |
| SSIL | 开，ULTRA | 关 | radius 5，intensity 1.0 | 约 +11% |
| SSR | 开 | 关 | 96 步，fade_in 0.15，fade_out 2.0，depth_tolerance 0.4 | 约 +15% |
| 体积雾 | 仅电影镜头 | 关 | 密度 0.0009（白天）/ 0.0013（黄昏），anisotropy 0.62，长度 420 m，时间重投影 0.9 | 约 +10% |
| 距离雾 | 仅电影镜头 | 同左 | 指数雾，密度 0.00022 / 0.00042，aerial_perspective 0.35，黄昏 `fog_sky_affect 0.55` | 约 +1% |
| Glow | 开 | 开 | intensity 0.55 / 0.9，bloom 0.02 / 0.08，hdr_threshold 1.0 / 0.8 | 噪声内 |
| 色调映射 | ACES | ACES | white 6.0，exposure 1.0 / 0.95；Adjustments 对比度 1.1，饱和度 1.0 / 1.12 | ACES、AgX、Filmic 差 ≤ 3% |
| 自动曝光 | 关（试过） | 关 | `CameraAttributesPractical` scale 0.4，speed 2.0 | 噪声内 |
| 抗锯齿 | MSAA 4× + TAA | MetalFX Temporal，3D 缩放 0.67 | 各向异性 16×，debanding 开 | MSAA4 + TAA 相对不开约 +25% |
| 方向光阴影 | 图集 8192，PSSM 4 级（0.12 / 0.3 / 0.6），混合开，软阴影 ULTRA | 图集 4096，PSSM 2 级，软阴影 MEDIUM | 最大距离 = 镜头距离 + 150 m，pancake 40，太阳角直径 0.4°（白天）/ 0.9°（黄昏） | **未测** |
| OmniLight3D | 黄昏最多 24（池 32），无阴影 | 12 | 范围 16 m，能量 2.2 | **未测** |
| AreaLight3D | 黄昏最多 8，无阴影 | 关 | 沿街店面、办公大堂窗光；范围 11 m，能量 ×0.22 | **未测** |
| 景深 | 仅电影镜头 | — | 近 0.55×、远 1.12× 焦距，过渡 0.3× / 0.7× 焦距，amount 0.12 | 未单测 |
| 玻璃 | 窗内互动映射 + clearcoat；阳台 / 露台 / 大堂玻璃 clearcoat 1.0 + 屏幕空间折射 0.04 | 同左 | clearcoat_roughness 0.03 | 折射约 +3%，clearcoat ≈ 0 |
| 材质 | Poly Haven 15 套 PBR；shader 内去重复纹理、宏观明暗、湿润度 | 同左 | 见 CREDITS.md | — |
| 光照预设 | 白天 / 黄昏（窗户自发光、路面湿润、路灯、店面窗光） | 同左 | `scripts/lighting.gd` | — |

## 4. 每个镜头的帧时

`draw_ms` 是 `force_draw` 吞吐；`TIME_PROCESS` 是 60 帧均值。第一次完整拍摄（机器半热）的数据，冷机会低约 10–20%。

| 镜头 | 截图档 draw_ms | 截图档 TIME_PROCESS | 交互档 draw_ms | 绘制调用 | 备注 |
| --- | ---: | ---: | ---: | ---: | --- |
| s01_hero_day | 44.7 | 43.8 | 13.0（配对冷机测 14.7） | 891 | 游戏相机 |
| s01_hero_dusk | 47.3 | 46.5 | 未测 | 882 | 游戏相机，+24 OmniLight、+8 AreaLight |
| s02_far | 39.7 | 无效（0.24） | 10.9 | 1214 | 游戏相机，旧版取景 |
| s03_near_block | 44.8（旧取景）；39.0（最终取景，单进程，TIME_PROCESS 38.6） | 无效 / 38.6 | 11.4（旧取景） | 401 / 440 | 游戏相机 |
| s00_cinematic_day | 54.7 | 无效（0.21） | 未测 | 725 | 透视，景深，体积雾 |
| s00_cinematic_dusk | 57.2；55.2（最终雾参数，单进程，TIME_PROCESS 54.7） | 无效 / 54.7 | 未测 | 790 | 透视，景深，体积雾 |
| s01_hero_day_4k | 131.2 | 127.6 | 未测 | 891 | 3840×2160，未崩显存 |
| s00_cinematic_day_4k | 174.9 | 162.3 | 未测 | 725 | 3840×2160 |

显存（`RENDER_VIDEO_MEM_USED`）：截图档 1080p 约 3.1–3.6 GB（MSAA 4× + TAA + SSR + SSIL + VoxelGI 512）；VoxelGI 256 约 1.5 GB；交互档约 0.8 GB。4K 的显存没有记录。

## 5. 逐项对比（配对比值）

变体和基线在同一进程里交替测 4 轮；比值是 4 轮中位数，「各轮比值」给出离散程度。基线是该档位的默认配置。图在 `../preview/compare/`，裁切图 640×360 取自 1080p 原生像素，整图 480×270。**前三组（tier、gi、fx 的 ssao / ssil / ssr）是冷却间隔修好之前测的，第 4 轮出现过 1.24–1.43 的降频离群值，不确定度约 ±8%；其余在冷却 30 s 之后测，离散度 ≤ 3%。**

### 5.1 档位

| 项 | 镜头 | 变体 ms | 基线 ms | 比值 | 各轮比值 | 显存 MB | 图 |
| --- | --- | ---: | ---: | ---: | --- | ---: | --- |
| 截图档（基线自比） | s01_hero_day | 46.7 | 46.2 | 1.00 | 0.99, 1.00, 1.00, 1.03 | 3312 | [图](../preview/compare/tier_shot_tier.png) |
| 交互档 | s01_hero_day | 14.7 | 14.7 | 1.00（自比） | 0.99, 1.00, 1.00, 1.01 | 830 | [图](../preview/compare/tier_interactive_tier.png) |

交互档相对截图档约 0.32×（14.7 / 46.2）。

### 5.2 全局光照（基线：VoxelGI 512）

| 项 | 镜头 | 变体 ms | 基线 ms | 比值 | 各轮比值 | 显存 MB | 图 |
| --- | --- | ---: | ---: | ---: | --- | ---: | --- |
| 关 | s01_hero_day | 39.3 | 46.2 | 0.85 | 0.83, 0.84, 0.86, 0.87 | 3260 | [图](../preview/compare/gi_none.png) |
| SDFGI 3 级联 | s01_hero_day | 44.0 | 45.9 | 0.96 | 0.92, 0.96, 0.96, 0.96 | 3517 | [图](../preview/compare/gi_sdfgi_3cascade.png) |
| SDFGI 4 级联 | s01_hero_day | 47.7 | 46.0 | 1.04 | 1.03, 1.03, 1.04, 1.05 | 3569 | [图](../preview/compare/gi_sdfgi_4cascade.png) |
| VoxelGI 256 | s01_hero_day | 44.9 | 46.8 | 0.96 | 0.95, 0.95, 0.96, 1.00 | 1474 | [图](../preview/compare/gi_voxel_256.png) |
| VoxelGI 512（= 基线） | s01_hero_day | 48.5 | 49.7 | 0.97 | 0.96, 0.96, 0.99, 0.99 | 3312 | [图](../preview/compare/gi_voxel_512.png) |
| 关 | s03_near_block | 32.6 | 41.5 | 0.78 | 0.71, 0.78, 0.79, 0.79 | 3274 | [图](../preview/compare/gi_none_near.png) |
| SDFGI | s03_near_block | 46.1 | 46.9 | 0.98 | 0.94, 0.98, 0.98, 1.25 | 3583 | [图](../preview/compare/gi_sdfgi_near.png) |
| VoxelGI 512（= 基线） | s03_near_block | 53.1 | 51.5 | 1.01 | 0.96, 0.97, 1.05, 1.06 | 3327 | [图](../preview/compare/gi_voxel_512_near.png) |

读法：VoxelGI 512 与 SDFGI 3 / 4 级联在帧时上差 ≤ 5%（噪声量级）；关 GI 省 15–22%。SDFGI 多占约 250 MB 显存，VoxelGI 256 比 512 少约 1.8 GB。选 VoxelGI 512 做截图档的理由是不依赖相机位置（SDFGI 级联以相机为中心，正交相机离场景 400 m 时单元太粗，一度完全没有效果，见 ITERATIONS 第 4 轮），代价是 6–13 s 的运行时烘焙。

### 5.3 屏幕空间特效、体积雾、玻璃

| 项 | 镜头 | 变体 ms | 基线 ms | 比值 | 各轮比值 | 图 |
| --- | --- | ---: | ---: | ---: | --- | --- |
| SSAO 关 | s03_near_block | 50.4 | 52.7 | 0.92 | 0.85, 0.92, 0.92, 0.99 | [图](../preview/compare/fx_ssao_off.png) |
| SSAO 开（= 基线） | s03_near_block | 53.2 | 49.4 | 1.05 | 0.98, 1.02, 1.09, 1.38 | [图](../preview/compare/fx_ssao_on.png) |
| SSIL 关 | s03_near_block | 58.3 | 65.2 | 0.89 | 0.87, 0.89, 0.90, 1.44 | [图](../preview/compare/fx_ssil_off.png) |
| SSR 关 | s03_near_block | 42.3 | 50.9 | 0.87 | 0.79, 0.85, 0.89, 0.96 | [图](../preview/compare/fx_ssr_off.png) |
| Glow 关 | s01_hero_dusk | 54.0 | 56.1 | 0.97 | 0.93, 0.97, 0.98, 1.00 | [图](../preview/compare/fx_glow_off.png) |
| Glow 开（= 基线） | s01_hero_dusk | 51.7 | 51.8 | 0.99 | 0.98, 0.98, 1.00, 1.01 | [图](../preview/compare/fx_glow_on.png) |
| ACES（= 基线） | s01_hero_day | 45.4 | 46.4 | 0.97 | 0.94, 0.96, 0.99, 1.01 | [图](../preview/compare/fx_tonemap_aces.png) |
| AgX | s01_hero_day | 44.8 | 44.8 | 1.00 | 0.99, 1.00, 1.00, 1.00 | [图](../preview/compare/fx_tonemap_agx.png) |
| Filmic | s01_hero_day | 45.8 | 45.4 | 1.01 | 1.00, 1.01, 1.01, 1.02 | [图](../preview/compare/fx_tonemap_filmic.png) |
| 自动曝光 开 | s01_hero_dusk | 50.7 | 49.9 | 1.02 | 1.01, 1.01, 1.02, 1.02 | [图](../preview/compare/fx_auto_exposure_on.png) |
| 自动曝光 关（= 基线） | s01_hero_dusk | 52.0 | 50.9 | 1.02 | 0.99, 1.02, 1.02, 1.03 | [图](../preview/compare/fx_auto_exposure_off.png) |
| 体积雾 开（= 基线） | s00_cinematic_day | 56.5 | 56.5 | 1.00 | 0.99, 1.00, 1.00, 1.01 | [图](../preview/compare/fx_vfog_on.png) |
| 体积雾 关 | s00_cinematic_day | 51.6 | 56.7 | 0.91 | 0.90, 0.91, 0.91, 0.91 | [图](../preview/compare/fx_vfog_off.png) |
| 体积雾和距离雾都关 | s00_cinematic_day | 49.4 | 54.9 | 0.90 | 0.89, 0.90, 0.90, 0.91 | [图](../preview/compare/fx_fog_off.png) |
| 折射 + clearcoat（= 基线） | dev_facade_c | 35.1 | 35.1 | 1.00 | 0.99, 1.00, 1.00, 1.01 | [图](../preview/compare/glass_clearcoat_refraction_on.png) |
| 只关 clearcoat | dev_facade_c | 35.0 | 34.9 | 1.00 | 1.00, 1.00, 1.00, 1.01 | [图](../preview/compare/glass_clearcoat_off.png) |
| 只关折射 | dev_facade_c | 34.6 | 35.5 | 0.97 | 0.97, 0.97, 0.97, 0.98 | [图](../preview/compare/glass_refraction_off.png) |
| 折射和 clearcoat 都关 | dev_facade_c | 33.9 | 35.1 | 0.96 | 0.95, 0.96, 0.97, 1.00 | [图](../preview/compare/glass_both_off.png) |

SSAO 在这个场景里几乎没有可见效果：开关两张近景裁切的逐像素平均差只有 0.002（0–1），主要因为 VoxelGI、立面 shader 自带的 AO 和 `ssao_light_affect 0.25` 已经盖住了接触阴影。帧时约 +8%，收益偏低。如果要省，SSAO 是最先该关的一项。

### 5.4 天空

| 项 | 镜头 | 变体 ms | 基线 ms | 比值 | 各轮比值 | 图 |
| --- | --- | ---: | ---: | ---: | --- | --- |
| HDRI 经钳制 shader（= 基线） | s00_cinematic_day | 55.3 | 55.3 | 1.00 | 0.97, 1.00, 1.00, 1.00 | [图](../preview/compare/sky_panorama_clamped.png) |
| 库存 `PanoramaSkyMaterial` | s00_cinematic_day | 57.7 | 56.6 | 1.02 | 1.00, 1.02, 1.02, 1.07 | [图](../preview/compare/sky_panorama_stock.png) |
| `PhysicalSkyMaterial` | s00_cinematic_day | 64.2 | 61.4 | 1.03 | 0.99, 1.02, 1.05, 1.07 | [图](../preview/compare/sky_physical.png) |
| 库存 `PanoramaSkyMaterial`（黄昏） | s00_cinematic_dusk | 59.9 | 60.0 | 1.00 | 1.00, 1.00, 1.00, 1.01 | [图](../preview/compare/sky_panorama_stock_dusk.png) |
| `PhysicalSkyMaterial`（黄昏） | s00_cinematic_dusk | 59.2 | 60.4 | 0.99 | 0.98, 0.98, 0.99, 1.01 | [图](../preview/compare/sky_physical_dusk.png) |

天空类型对帧时没有影响。差别在光照：库存 `PanoramaSkyMaterial` 把 HDRI 里的太阳盘（亮度上万）原样写进 radiance 立方体，粗糙表面于是在 `DirectionalLight3D` 之外又反射了一个更强的太阳（双重光）。把方向光能量清零、只留天空，场景仍被打得很亮，才定位到这一点。解法是自写 sky shader，radiance 通道钳到 3.0（黄昏 2.4），可见背景钳到 40（太阳在电影镜头里仍然可见）。`PhysicalSkyMaterial` 没有这个问题，但没有 Poly Haven 的云层，天空平。

### 5.5 抗锯齿

近景（s03_near_block，基线 MSAA 4× + TAA）。

| 项 | 变体 ms | 基线 ms | 比值 | 各轮比值 | 图 |
| --- | ---: | ---: | ---: | --- | --- |
| 无 | 31.3 | 39.2 | 0.80 | 0.79, 0.80, 0.80, 0.81 | [图](../preview/compare/aa_none.png) |
| FXAA | 31.8 | 39.9 | 0.80 | 0.78, 0.79, 0.81, 0.82 | [图](../preview/compare/aa_fxaa.png) |
| SMAA | 38.8 | 47.5 | 0.82 | 0.80, 0.81, 0.82, 0.83 | [图](../preview/compare/aa_smaa.png) |

MSAA 4× + TAA 相对不开抗锯齿约 +25%。其余项（TAA 单开、MSAA 2× / 4× / 8×、FSR2、MetalFX）的配对测量**未做**（中途被叫停）。下面是早期一次**未配对**的单次测量，冷机，近景旧取景，仅供参考：

| 项 | draw_ms |
| --- | ---: |
| 无 | 33.2 |
| FXAA | 34.0 |
| SMAA | 36.8 |
| TAA | 38.0 |
| MSAA 2× | 38.1 |
| MSAA 4× | 37.1 |
| MSAA 4× + TAA | 39.6 |
| MSAA 8× | 25.5（不可信：当时没有读回实际生效的 MSAA，很可能被 Metal 降级） |
| FSR 1，0.67× | 20.1 |
| FSR 2，0.67× | 22.4 |
| MetalFX Spatial，0.67× | 18.9 |
| MetalFX Temporal，0.67× | 21.4 |
| FSR 2，0.5× | 17.3 |
| MetalFX Temporal，0.5× | 16.4 |

交互档用 MetalFX Temporal 0.67×：它在 Metal 驱动上可用，官方文档（https://docs.godotengine.org/en/latest/classes/class_viewport.html）说明它「Only supported when the Metal rendering driver is in use, which limits this scaling mode to macOS and iOS.」。交互档的 hero 和近景渲染里细线（车道线、领地边线）比截图档略软，但没有破碎或拖影；没有做 0.75× 的对照，所以没有验证 0.67× 是不是该档的最优点。

### 5.6 未测

阴影（图集 2048 / 4096 / 8192、PSSM 4 级 / 2 级 / 正交、软阴影档位、阴影开关）、黄昏灯光（OmniLight 0 / 12 / 24 / 32 盏、AreaLight 开关与阴影）、黄昏 HDRI 经钳制 shader 的天空项、AA 其余项。这些在 `scripts/bench_plan.gd` 里已有条目，`tools/run_bench.sh` 带 `RESUME=1` 可以接着跑（会开窗）。

一次早期的**未配对**单测可以粗略地界定瓶颈：hero 镜头 40.3 ms 的完整截图档，在同时关闭 GI、SSAO、SSIL、SSR、Glow、抗锯齿并把阴影图集降到 2048 后是 14.0 ms。

## 6. 交互档与截图档的差别

| 项 | 截图档 | 交互档 |
| --- | --- | --- |
| 渲染分辨率 | 1080p 原生 | 1080p 输出，内部 0.67×（MetalFX Temporal） |
| 抗锯齿 | MSAA 4× + TAA | MetalFX Temporal |
| GI | VoxelGI 512，烘焙 6–13 s | SDFGI 3 级联 |
| SSAO | ULTRA | MEDIUM |
| SSIL / SSR | 开 | 关 |
| 体积雾 | 电影镜头开 | 关 |
| 阴影 | 8192 图集，PSSM 4 级，软阴影 ULTRA | 4096，PSSM 2 级，软阴影 MEDIUM |
| 灯 | 黄昏 24 OmniLight + 8 AreaLight | 12 OmniLight，无 AreaLight |
| hero 帧时 | 约 45 ms（冷机 46 ms） | 约 13–15 ms |
| 显存 | 约 3.3 GB | 约 0.8 GB |

画面上的取舍：交互档没有 SSR 和 SSIL，玻璃塔不再反射周围，黄昏的室内光对周围的间接光照消失；其余（材质、阴影形状、overlay、道具）一致。

## 7. 这台机器的瓶颈

1. **后处理和光照质量档，而不是几何**。hero 镜头约 890 次绘制、约 790 万图元，场景几何被批成按材质分的大网格，CPU 提交不是问题（`TIME_PROCESS` ≈ `draw_ms`，主线程在等 GPU）。
2. **屏幕空间特效叠加在 4× MSAA 的全分辨率目标上**。MSAA 4× + TAA 约 +25%，SSR + SSIL + SSAO 合计约 +30%，GI 约 +15–22%，加起来占截图档大头。
3. **持续负载降频**。冷机 hero 46 ms，长时间运行后 63–72 ms，gi/none 的基线在某次热机测量里到过 90–103 ms。内建屏 2560×1664 是 13 英寸 MacBook 的分辨率，未核实是否为无风扇机型；无论是否，截图档不适合用作持续运行的交互设置。
4. **统一内存 16 GB 下显存占用大**。截图档 3.3 GB（MSAA 目标、SSR / SSIL 缓冲、VoxelGI 512 的 3D 纹理）；4K 能跑完但帧时 131–175 ms。
5. **工具链限制**：Metal 上 GPU 计时器不可读（见 §1），所以无法给出每个通道的 GPU 时间，只能靠开关消融。

## 8. 再往上要什么

**硬件**。持续跑截图档需要有主动散热的机型（或更多 GPU 核），至少是 M4 Pro / Max 档；4K 截图档（131–175 ms）只适合离线出图。若要在游戏相机下既保持 ≤ 33 ms 又保留 SSR / SSIL，需要约 1.5–2 倍的 GPU 吞吐。统一内存 16 GB 在 4K + MSAA 4× + VoxelGI 512 下已经紧张（1080p 就 3.3 GB），更高精度的 GI 或更大体积需要 32 GB 以上。

**资产**。这一版的上限主要卡在资产，而不是引擎：树是位移球体加噪声镂空，车是拉伸的多边形加线，没有真实的细节（雨水管、窗扇、栏杆、招牌字、广告、路面磨损的细节贴花）。要继续往上需要：每种建筑一套 trim sheet 或图集化的立面（窗扇、阳台、檐口、卷帘门、玻璃幕墙的竖梃节点）；真实的植被网格或叶簇贴图；车辆和街道设施的建模；路面磨损、水渍、井盖的贴花；屋顶设备库。预算为零的路线下，CC0 来源（Poly Haven 模型、Kenney）能补一部分，但风格要统一，需要一轮筛选。

**引擎功能**。（1）`AreaLight3D`（4.7 新增），官方文档（https://docs.godotengine.org/en/latest/classes/class_arealight3d.html）说明「An area light is a type of Light3D node that emits light over a two-dimensional area, in the shape of a rectangle.」，并且「Area lights can cast soft shadows using PCSS」。本版只用了无阴影版本（成本没测），带阴影的窗光、招牌光需要更多测量。（2）VoxelGI 需要运行时烘焙（6–13 s），且有体积边界；SDFGI 级联以相机为中心，正交远相机下效果不稳（官方 GI 总览页 https://docs.godotengine.org/en/latest/tutorials/3d/global_illumination/introduction_to_global_illumination.html 的摘要同样说它跟随相机；这是 WebFetch 摘要，非原文）。一个没有尝试的方向是静态街区的 `LightmapGI`（需要 UV2，可用 `ArrayMesh.lightmap_unwrap` 生成），官方页说它是「excellent indirect lighting」但要在编辑器里烘焙，未核实它在 4.7 的运行时烘焙能力。（3）文档里没有找到硬件光追 GI 的说明（GI 总览页没有提及），不能判断路线图，所以不下结论。（4）GPU 计时在 Metal 上读不出，需要引擎侧修复才能做逐通道剖析。（5）`RenderingServer.environment_set_ssr_roughness_quality` 在 4.7.2 里只打印「has been deprecated and no longer does anything」，SSR 粗糙度档位在代码里已无效。

## 9. 调色板还原

overlay（阵营 A / B、分区 R / C / I、电力、拥堵）不写进世界材质的 albedo，而是独立的薄几何，走 `overlay.gdshader`。ACES 会把明亮饱和的颜色推白（实测：线性输入 (0, 1, 0) 经 ACES 变成 sRGB (159, 243, 93)），阵营色因此发白。办法是在 GDScript 里复刻 ACES + Adjustments 公式（`scripts/tonemap_model.gd`），对每个预设数值反求，让最终画面落在调色板 hex 上。

复刻是否准确：在 exposure 1.0、white 6.0、对比度 1.1、饱和度 1.0 下渲染 11 个平涂色块，实测输出和模型预测逐像素一致（11 / 11）。反解的最坏残差是 0.125（0–1 sRGB 的欧氏距离），对应哪个槽位没有记录；其余槽位的残差没有逐个核对。

## 10. 没做到的和原因

- 阴影、黄昏灯光、AA 其余项的配对消融：被叫停。
- `s02_far.png`、`s00_cinematic_day.png`、`s00_cinematic_day_4k.png`、`s01_hero_day_4k.png` 是在最后几处修复之前渲染的（远景地形只铺 900 m，顶部露出一条天空；远景 VoxelGI 体积 580 m，左缘有一块淡色光斑；电影镜头地平线的地形边缘）。代码里已修（`road_builder.gd` 地形 6000 m，`shots.gd` 远景体积 1100 m / 细分 256，电影镜头远平面 7000 m），但没有重新渲染，因为被要求不再启动渲染进程。重渲命令：`CITY_SHOWCASE_CAPTURE=1 CITY_SHOWCASE_SHOTS=s02_far,s00_cinematic_day,s00_cinematic_day_4k,s01_hero_day_4k ./client/run_techart_showcase.sh`。`s03_near_block.png` 和 `s00_cinematic_dusk.png` 已是修复后的渲染。
- 交互档的电影镜头、黄昏 hero 帧时未测。
- 4K 显存未记录。
- 没有验证 MetalFX 0.67× 是不是交互档的最优缩放，也没有做 FSR2 / MetalFX 的画质对照图。
- MSAA 8× 的早期数据不可信，没有重测。
- 贴图和 HDRI 的 `.import` 是脚本生成的（BPTC 压缩、带 mipmap），首次 `--import` 本机实测 2:11。

## 11. 2026-10-08 补渲（集成者）

负责人批准后重渲了 `s02_far`、`s00_cinematic_day`、`s00_cinematic_day_4k`、`s01_hero_day_4k`（修复后的代码：地形 6000 m、远景 VoxelGI 体积 1100 m / 细分 256、电影镜头远平面 7000 m）。顶部露天和左缘光斑已消失。`s02_far` 的地形中部仍有一条横向的浅色带，疑似远景 VoxelGI 体积边界或地形分块接缝，留给 M4 处理。本次 draw_ms：s02_far 49.2、s00_cinematic_day 71.3、s00_cinematic_day_4k 229.7、s01_hero_day_4k 181.1（机器已热，仅供参考）。
