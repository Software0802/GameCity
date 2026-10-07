extends RefCounted

## Quantization of continuous 0–1 fields to 1/SliceConstants.FIELD_QUANT steps.
## Satisfaction, pollution, and edge congestion all go through here so the wire,
## the save, and the "only send when the step changes" rule agree on one rounding:
## round half up, clamped to [0, 1]. snap_ratio() does the same on an exact
## integer ratio so an accumulated integer field never drifts.


static func snap(value: float) -> float:
	var steps := float(SliceConstants.FIELD_QUANT)
	return floorf(clampf(value, 0.0, 1.0) * steps + 0.5) / steps


## Quantized numerator / denominator, computed in integers: no float error at the
## step boundaries. Returns 0 for a non-positive denominator.
static func snap_ratio(numerator: int, denominator: int) -> float:
	if denominator <= 0:
		return 0.0
	var steps := SliceConstants.FIELD_QUANT
	var scaled := maxi(0, numerator) * steps
	var rounded := int((scaled * 2 + denominator) / (denominator * 2))
	return float(mini(rounded, steps)) / float(steps)
