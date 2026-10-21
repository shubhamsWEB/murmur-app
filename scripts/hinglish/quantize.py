#!/usr/bin/env python3
"""The int8 models sherpa-onnx runs, from the export's float32 ones, one at a time in a process of its own (the
encoder is 2.6 GB: quantised in the export's own process, beside the model, it needs more memory than a runner has).
What sherpa-onnx's export script does at its end: dynamic quantisation of the MatMuls, weights in QInt8. With
--per-channel each output channel of a weight gets its own scale: Apex's encoder needs that (quantised per tensor, as
the export script does, it repeated words: "Haan haan haan haan haan" for "Haan haan, dekhen.").

--uint8 makes the weights unsigned (QUInt8, an offset per channel), a second choice when signed ones aren't close enough.

    quantize.py [--per-channel] [--uint8] <model.onnx> <model.int8.onnx>
"""
import sys

from onnxruntime.quantization import QuantType, quantize_dynamic

args = sys.argv[1:]
per_channel = "--per-channel" in args
unsigned = "--uint8" in args
args = [arg for arg in args if arg not in ("--per-channel", "--uint8")]
if len(args) != 2:
    sys.exit(__doc__)
quantize_dynamic(model_input=args[0], model_output=args[1], op_types_to_quantize=["MatMul"],
                 weight_type=QuantType.QUInt8 if unsigned else QuantType.QInt8, per_channel=per_channel)
print(f"{args[1]}: done ({'uint8' if unsigned else 'int8'}{', per channel' if per_channel else ''})")
