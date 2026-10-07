# Art visual source

归档说明：垂直切片的锁定调色板、风格和镜头表。仓库里没有美术资源。客户端场景里的地面色只是 `#2F3A34` 的占位，不是正式资产。

Palette, style, and shot list are locked. No art assets are in the repo. M01 is optional and is skipped.

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

## 风格 / Style

- 干净的俯视城市。投影用正交，或相对竖直偏 **15–30°** 的微斜（micro-oblique）。二者择一保持统一；骨架相机取正交并偏约 25°。
- 风格化 low-poly。
- 建筑高度 **2–3 档 LOD**，对应数据里的 `buildingTier` 0–2。
- MVP 不放：市民、密集植被、车辆网格。拥堵用边的颜色/脉冲表达，不用车流模型。

## 镜头表 / Shot list

| Id | 名称 | 要看见什么 |
| --- | --- | --- |
| S01 | hero | 主视觉：俯视或微斜下的城市，两阵营徽章可区分，RCI 色仍是用地色 |
| S02 | far | 远景：能读出 64×64 量级的地图范围、未占领地与道路网 |
| S03 | near block | 近景一个街区：正交道路、R/C/I、电力色，建筑不超过 2–3 个高度档 |
| S04 | HUD overlay | HUD 叠在城市上：底 `#12151A`，正文 `#E8ECF0`，次级 `#8B939C`，正向 A、负向 B、警告 `#F0C93A` |
| M01 | （可选） | **本切片跳过**，不拍、不实现 |

## 明确不做

- 不在本仓库提交模型、贴图、动画。
- 不用阵营色涂满建筑来代替 R / C / I。
- 不画水务设施来消耗 `#4EC8E8`。
- 不做市民、行道树海、车辆网格。
