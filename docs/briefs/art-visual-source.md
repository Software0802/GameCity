# Art visual source

归档说明：垂直切片的锁定调色板和镜头表。**2026-10-07 修订**：风格从 low-poly 改为程序化中等写实，渲染器改为 Forward+（负责人志坤决定，预算为零、以 CC0 贴图加程序化几何为路线）。调色板和镜头表不变。M1 中等写实包在 `client/assets/techart/roads_interchange/`，是这条路线的第一份样本。

Palette and shot list are locked. Revised 2026-10-07: procedural mid-realism on Forward+ replaces stylized low-poly. M01 is optional and is skipped.

## 调色板 / Palette

颜色只按表内用途使用。阵营色不能替换 RCI 色。

### 地形 Terrain

| 用途 | Hex |
| --- | --- |
| ground | `#2F3A34` |
| unclaimed | `#3D4A42` |
| grass | `#4A5C52` |
| water（可选，切片不用） | `#1E2420` |

水的颜色留在表里，避免以后对不上。切片不画水体、不做水务玩法。

### 道路 Roads

| 用途 | Hex |
| --- | --- |
| asphalt | `#3A3A3C` |
| curb | `#C8C4B8` |
| congestion / crisis pulse | `#F0C93A` |

`#F0C93A` 同时是拥堵、危机脉冲和 HUD 警告色。

### 分区 RCI

分区色表达用地，不表达阵营。

| 分区 | 主色 | 密集团顶 |
| --- | --- | --- |
| R | `#E8A05A` | `#C47A3A` |
| C | `#5B8FD9` | `#3D6FB0` |
| I | `#8B7A5C` | `#6B5A3E` |

### 阵营 Faction

只用于轮廓和屋顶徽章（outline / roof badge）。**禁止**用阵营色替换 RCI 主色或密集团顶。

| 阵营 | 亮色 | 压暗 |
| --- | --- | --- |
| A | `#2EE6A8` | `#1AAF7C` |
| B | `#FF5C7A` | `#C93A55` |

### 市政服务

| 用途 | Hex | 切片 |
| --- | --- | --- |
| power | `#F5D76E` | 使用 |
| water | `#4EC8E8` | 闲置，不使用 |

### 建筑 Building

| 用途 | Hex |
| --- | --- |
| wall light | `#D6D0C4` |
| wall mid | `#9A9488` |
| wall shade | `#5C574E` |
| window | `#E8E2D6` |

### HUD

| 用途 | Hex |
| --- | --- |
| background | `#12151A` |
| primary text | `#E8ECF0` |
| secondary text | `#8B939C` |
| positive | 阵营 A `#2EE6A8` |
| negative | 阵营 B `#FF5C7A` |
| warn | `#F0C93A` |

## 风格 / Style（2026-10-07 修订）

- 相机不变：正交，或相对竖直偏 **15–30°** 的微斜（micro-oblique）。骨架相机取正交并偏约 25°。
- **程序化中等写实**：建筑、道路、路缘、标线由代码按地块数据生成，材质用 PBR 贴图。资产预算为零，贴图和 HDRI 只用 CC0 来源（Poly Haven、Kenney 等），每个资源在所在包的 `CREDITS.md` 记录出处。
- 渲染器 **Forward+**，为工程默认。目标机 Apple M4；游戏相机镜头在 1080p 保持可交互帧率，电影镜头不受此限。
- 建筑高度 **2–3 档**，对应数据里的 `buildingTier` 0–2。立面细节由程序生成，不靠手工模型。
- 调色板用途不变：RCI 色和阵营色是 overlay、轮廓和徽章，不写进世界材质的 albedo。
- 街道道具（路灯、树、停放车辆）允许作为程序化点缀。拥堵仍用边的颜色/脉冲表达，不做车流模拟。

## 镜头表 / Shot list

| Id | 名称 | 要看见什么 |
| --- | --- | --- |
| S01 | hero | 主视觉：俯视或微斜下的城市，两阵营徽章可区分，RCI 色仍是用地色 |
| S02 | far | 远景：能读出 64×64 量级的地图范围、未占领地与道路网 |
| S03 | near block | 近景一个街区：正交道路、R/C/I、电力色，建筑不超过 2–3 个高度档 |
| S04 | HUD overlay | HUD 叠在城市上：底 `#12151A`，正文 `#E8ECF0`，次级 `#8B939C`，正向 A、负向 B、警告 `#F0C93A` |
| M01 | （可选） | **本切片跳过**，不拍、不实现 |

## 明确不做

- 贴图和 HDRI 只提交 CC0 来源，单张不超过 2K，并记录出处。手工建模的模型和动画仍不提交。
- 不用阵营色涂满建筑来代替 R / C / I。
- 不画水务设施来消耗 `#4EC8E8`。
- 不做市民，不做车流模拟。
