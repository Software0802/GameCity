# 生产中等写实交接 — 已落入 GameCity

## 位置

`client/assets/techart/roads_interchange/`  
`res://` 前缀：`res://client/assets/techart/roads_interchange/`

## 主场景

`scenes/sample_interchange.tscn` — **无 HUD**。对局入口仍是 `res://client/main.tscn`。薄预览入口是 `res://client/techart_sample.tscn`。

## 材质列表

见 `materials/`（沥青/混凝土/玻璃/草地/车/树 + overlay 四色，共 17 个 `.tres`）。

## 截帧复现

在 GameCity 仓库根、且本机有 Godot 4.3 时。`--rendering-method forward_plus` 只作用于这一次进程：

```bash
CITY_MVP_CAPTURE=1 \
  godot --path . \
  --rendering-method forward_plus \
  --audio-driver Dummy \
  res://client/assets/techart/roads_interchange/scenes/sample_interchange.tscn
```

输出：`client/assets/techart/roads_interchange/preview/prod-mid-s01-1920x1080.png`  
第二张：再加上 `CITY_MVP_CAPTURE_S02=1`。

## 视觉目标

中等写实自研（约 ceiling 35–50%），不以 CS2 静帧为验收。说明见包内 `README.md`。
